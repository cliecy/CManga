package com.github.kiastr.venera_ssr.colorize

import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.TensorInfo
import android.graphics.Bitmap
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.Rect
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import java.io.Closeable
import java.io.File
import java.nio.FloatBuffer
import java.security.MessageDigest
import kotlin.math.roundToInt

/** Serial native inference, bounded unrendered results, and independent render controls. */
class ColorizeEngine(profileDirectory: File) {
    private val env = OrtEnvironment.getEnvironment()
    private val models = ModelManager(env, profileDirectory)

    data class ModelInfo(val channels: Int, val scale: Int, val inputWidth: Int, val inputHeight: Int) {
        fun toMap(): Map<String, Int> = mapOf(
            "channels" to channels, "scale" to scale,
            "inputWidth" to inputWidth, "inputHeight" to inputHeight
        )
    }

    data class Output(val bitmap: Bitmap, val backend: String, val scale: Int,
                      val cacheHit: Boolean, val fallbackReason: String?)
    private data class ModelKey(val path: String, val identity: String, val type: String)
    private data class CacheKey(val model: ModelKey, val input: String, val backend: String)
    private data class Base(val pixels: Mat, val backend: String, val reason: String?) {
        val bytes: Long get() = pixels.total() * pixels.elemSize()
    }
    private val metadata = LinkedHashMap<ModelKey, ModelInfo>()
    private val cache = LinkedHashMap<CacheKey, Base>(8, 0.75f, true)
    private var cacheBytes = 0L

    private class Mats : Closeable {
        private val values = ArrayList<Mat>()
        fun own(value: Mat): Mat { values.add(value); return value }
        fun create(): Mat = own(Mat())
        fun keep(value: Mat): Mat { values.remove(value); return value }
        override fun close() { values.asReversed().forEach { it.release() } }
    }

    fun getModelInfo(path: String, type: String): ModelInfo {
        val file = File(path)
        require(file.isFile) { "Model file does not exist: $path" }
        // Match Dart's content identity, so a validated dynamic model is not probed
        // again on the first render (including zero-strength/zero-intensity renders).
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        val digits = "0123456789abcdef"
        val identity = buildString(64) {
            for (byte in digest.digest()) {
                val value = byte.toInt() and 255
                append(digits[value ushr 4]); append(digits[value and 15])
            }
        }
        return inspect(ModelKey(path, identity, type))
    }

    private fun inspect(key: ModelKey): ModelInfo {
        require(key.type == "esrgan" || key.type == "deoldify") { "Unsupported model type: ${key.type}" }
        metadata[key]?.let { return it }
        val session = models.getSession(key.path, key.identity, false).ort
        require(session.numInputs == 1L && session.numOutputs == 1L) {
            "Expected one image input and one image output"
        }
        val input = session.inputInfo.values.first().info as? TensorInfo
            ?: throw IllegalArgumentException("Model input must be a tensor")
        val output = session.outputInfo.values.first().info as? TensorInfo
            ?: throw IllegalArgumentException("Model output must be a tensor")
        val shape = input.shape
        val outShape = output.shape
        require(input.type == OnnxJavaType.FLOAT && output.type == OnnxJavaType.FLOAT &&
            shape.size == 4 && outShape.size == 4 && (shape[0] == 1L || shape[0] < 0) &&
            (outShape[0] == 1L || outShape[0] < 0)) { "Expected float32 NCHW image tensors" }
        val channels = shape[1].toInt()
        require(channels == 1 || channels == 3) { "Only 1-channel ACNet or 3-channel RGB models are supported" }
        require(outShape[1] == channels.toLong() || (key.type == "deoldify" && outShape[1] < 0)) {
            "Input/output channel counts must match"
        }
        val width = if (shape[3] > 0) shape[3].toInt() else 0
        val height = if (shape[2] > 0) shape[2].toInt() else 0
        require(width in 0..2048 && height in 0..2048) { "Model input dimensions exceed the supported memory limit" }
        val scale: Int
        if (key.type == "deoldify") {
            require(channels == 3 && (width == 0 || width == 256) && (height == 0 || height == 256) &&
                (outShape[2] < 0 || outShape[2] == 256L) && (outShape[3] < 0 || outShape[3] == 256L)) {
                "DeOldify requires float32 NCHW RGB with 256x256 or dynamic spatial dimensions"
            }
            if (shape.any { it < 0 } || outShape.any { it < 0 }) {
                // Dynamic artistic/int8 exports retain the established 256-pixel preprocessing contract.
                OnnxTensor.createTensor(env, FloatBuffer.allocate(3 * 256 * 256),
                    longArrayOf(1, 3, 256, 256)).use { tensor ->
                    session.run(mapOf(session.inputNames.first() to tensor)).use { results ->
                        val actual = (results[0] as? OnnxTensor)?.info
                        require(actual?.type == OnnxJavaType.FLOAT &&
                            actual.shape.contentEquals(longArrayOf(1, 3, 256, 256))) {
                            "DeOldify must produce float32 [1,3,256,256] for its normalized input"
                        }
                    }
                }
            }
            scale = 1
        } else {
            require((width == 0 || width > 2) && (height == 0 || height > 2)) {
                "SR fixed input dimensions are too small for overlapping tiles"
            }
            if (width > 0 && height > 0 && outShape[2] > 0 && outShape[3] > 0) {
                require(outShape[2] % height == 0L && outShape[3] % width == 0L &&
                    outShape[2] / height == outShape[3] / width) { "SR model must use an integer isotropic scale" }
                scale = (outShape[3] / width).toInt()
            } else {
                val probeW = if (width > 0) width else 32
                val probeH = if (height > 0) height else 32
                OnnxTensor.createTensor(env, FloatBuffer.allocate(channels * probeW * probeH),
                    longArrayOf(1, channels.toLong(), probeH.toLong(), probeW.toLong())).use { tensor ->
                    session.run(mapOf(session.inputNames.first() to tensor)).use { results ->
                        val value = results[0] as? OnnxTensor
                            ?: throw IllegalArgumentException("SR output is not a tensor")
                        val actual = value.info.shape
                        require(actual.size == 4 && actual[0] == 1L && actual[1] == channels.toLong() &&
                            actual[2] % probeH == 0L && actual[3] % probeW == 0L &&
                            actual[2] / probeH == actual[3] / probeW) { "SR output has an incompatible shape" }
                        scale = (actual[3] / probeW).toInt()
                    }
                }
            }
            require(scale in 1..8) { "Unsupported SR scale: $scale" }
            val tileW = if (width > 0) width else 384
            val tileH = if (height > 0) height else 384
            require(tileW.toLong() * tileH * scale * scale * channels * 8 <= WORK_LIMIT) {
                "Fixed model tiles exceed the Android inference memory limit"
            }
        }
        val info = ModelInfo(channels, scale, width, height)
        metadata.keys.filter { it.path == key.path && it != key }.forEach { metadata.remove(it) }
        if (metadata.size >= 8) metadata.remove(metadata.keys.first())
        metadata[key] = info
        return info
    }

    fun colorize(input: Bitmap, modelPath: String, modelId: String, inputId: String,
                 type: String, backend: String, intensity: Float, strength: Float,
                 outputScale: Double): Output {
        require(backend == "auto" || backend == "cpu") { "Unsupported backend: $backend" }
        require(type == "esrgan" || type == "deoldify") { "Unsupported type: $type" }
        require(intensity.isFinite() && intensity in (if (type == "esrgan") 0.3f else 0f)..1.2f) {
            "Intensity is outside the supported range"
        }
        require(strength.isFinite() && strength in 0f..1f) { "Strength must be in [0,1]" }
        val key = ModelKey(modelPath, modelId, type)
        val info = inspect(key)
        val scale = if (outputScale == 0.0) info.scale.toDouble() else outputScale
        require(scale.isFinite() && scale >= 1.0 && scale <= info.scale) {
            "Output scale must be between 1 and native scale ${info.scale}"
        }
        val targetW = (input.width * scale).roundToInt()
        val targetH = (input.height * scale).roundToInt()
        val nativePixels = input.width.toLong() * input.height * info.scale * info.scale
        val targetPixels = targetW.toLong() * targetH
        val noInference = (type == "esrgan" && strength == 0f) || (type == "deoldify" && intensity == 0f)
        // Bound phase peaks, not the sum of buffers whose lifetimes do not overlap.
        val inputPixels = input.width.toLong() * input.height
        val workingBytes = if (type == "deoldify") inputPixels * (if (noInference) 48 else 72)
            else inputPixels * 20 + targetPixels * 32 + (if (noInference) 0L else nativePixels * 44)
        require(workingBytes <= WORK_LIMIT) {
            "Requested output exceeds the 768 MiB Android AI working-image limit; use a smaller input/model scale"
        }
        if ((type == "esrgan" && strength == 0f) || (type == "deoldify" && intensity == 0f)) {
            val bitmap = if (type == "esrgan") ImageUtils.renderSr(input, null, targetW, targetH, 0f)
                else renderColor(input, null, 0f)
            return Output(bitmap, "none", info.scale, false, null)
        }
        val cacheKey = CacheKey(key, inputId, backend)
        cache[cacheKey]?.let { base ->
            return Output(render(input, base, info, type, targetW, targetH, intensity, strength),
                base.backend, info.scale, true, base.reason)
        }
        // A changed identity cannot keep the old model's image results alive indefinitely.
        val stale = cache.keys.filter { it.model.path == modelPath && it.model.identity != modelId }
        stale.forEach { removeCached(it) }
        val base = infer(input, key, info, backend)
        try {
            val rendered = render(input, base, info, type, targetW, targetH, intensity, strength)
            if (base.bytes <= CACHE_LIMIT) {
                while (cacheBytes + base.bytes > CACHE_LIMIT) removeCached(cache.keys.first())
                cache[cacheKey] = base
                cacheBytes += base.bytes
            }
            return Output(rendered, base.backend, info.scale, false, base.reason)
        } finally {
            if (cache[cacheKey] !== base) base.pixels.release()
        }
    }

    private fun infer(input: Bitmap, key: ModelKey, info: ModelInfo, backend: String): Base {
        val cpu = models.getSession(key.path, key.identity, false)
        if (key.type == "deoldify") return Base(inferColor(input, cpu.ort), "cpu", null)
        if (backend == "cpu") return Base(inferSr(input, cpu.ort, info, null), "cpu", null)
        try {
            val accelerated = models.getSession(key.path, key.identity, true)
            val pixels = inferSr(input, accelerated.ort, info, cpu.ort, accelerated::recordExecution)
            return Base(pixels, accelerated.backend, accelerated.fallbackReason)
        } catch (e: Exception) {
            models.discard(key.path, key.identity, true)
            return Base(inferSr(input, cpu.ort, info, null), "cpu", "NNAPI fallback: ${e.message}")
        }
    }

    /** Preserve the original Android DeOldify channel and luminance conventions, in float. */
    private fun inferColor(input: Bitmap, session: OrtSession): Mat = Mats().use { m ->
        val bgr = m.own(ImageUtils.bitmapToBgrMat(input))
        val gray = m.create()
        Imgproc.cvtColor(bgr, gray, Imgproc.COLOR_BGR2GRAY)
        val grayRgb = m.create()
        Imgproc.cvtColor(gray, grayRgb, Imgproc.COLOR_GRAY2RGB)
        val resized = m.create()
        Imgproc.resize(grayRgb, resized, Size(256.0, 256.0))
        val tensorInput = m.create()
        resized.convertTo(tensorInput, CvType.CV_32F) // DeOldify expects 0..255, not 0..1.
        val predicted = m.own(run(session, tensorInput, 3, 256, 256))
        val swapped = m.create()
        Imgproc.cvtColor(predicted, swapped, Imgproc.COLOR_BGR2RGB)
        swapped.convertTo(swapped, CvType.CV_32F, 1.0 / 255.0)
        val full = m.create()
        Imgproc.resize(swapped, full, Size(input.width.toDouble(), input.height.toDouble()))
        Imgproc.GaussianBlur(full, full, Size(13.0, 13.0), 0.0)
        val lab = m.create()
        // Historical Android behavior deliberately treats swapped RGB as BGR here.
        Imgproc.cvtColor(full, lab, Imgproc.COLOR_BGR2Lab)
        val a = m.create(); val b = m.create()
        Core.extractChannel(lab, a, 1); Core.extractChannel(lab, b, 2)
        val ab = m.create()
        Core.merge(listOf(a, b), ab)
        m.keep(ab) // Unquantized signed chroma; render intensity never enters inference.
    }

    private fun renderColor(input: Bitmap, chroma: Mat?, intensity: Float): Bitmap = Mats().use { m ->
        val bgr = m.own(ImageUtils.bitmapToBgrMat(input))
        val luminance = m.create()
        Core.extractChannel(bgr, luminance, 0)
        luminance.convertTo(luminance, CvType.CV_32F, 100.0 / 255.0)
        val ab = if (chroma == null) m.own(Mat.zeros(input.height, input.width, CvType.CV_32FC2))
            else m.create().also { chroma.convertTo(it, CvType.CV_32F, intensity.toDouble()) }
        val lab = m.create()
        Core.merge(listOf(luminance, ab), lab)
        val result = m.create()
        Imgproc.cvtColor(lab, result, Imgproc.COLOR_Lab2BGR)
        result.convertTo(result, CvType.CV_8U, 255.0)
        val bitmap = ImageUtils.bgrMatToBitmap(result)
        ImageUtils.copyAlpha(input, bitmap)
        bitmap
    }

    private fun inferSr(input: Bitmap, session: OrtSession, info: ModelInfo, cpu: OrtSession?,
                        onExecution: (() -> Unit)? = null): Mat =
        Mats().use { m ->
            val bgr = m.own(ImageUtils.bitmapToBgrMat(input))
            val source = m.create()
            Imgproc.cvtColor(bgr, source, if (info.channels == 1) Imgproc.COLOR_BGR2YCrCb else Imgproc.COLOR_BGR2RGB)
            source.convertTo(source, CvType.CV_32F, 1.0 / 255.0)
            val modelInput = if (info.channels == 3) source else m.create().also { Core.extractChannel(source, it, 0) }
            val inferred = m.own(tiles(modelInput, session, info, cpu, onExecution))
            if (info.channels == 3) return@use m.keep(inferred)
            val cr = m.create(); val cb = m.create()
            Core.extractChannel(source, cr, 1); Core.extractChannel(source, cb, 2)
            Imgproc.resize(cr, cr, inferred.size(), 0.0, 0.0, Imgproc.INTER_LINEAR)
            Imgproc.resize(cb, cb, inferred.size(), 0.0, 0.0, Imgproc.INTER_LINEAR)
            val ycrcb = m.create()
            Core.merge(listOf(inferred, cr, cb), ycrcb)
            m.keep(ycrcb)
        }

    private fun tiles(input: Mat, session: OrtSession, info: ModelInfo, cpu: OrtSession?,
                      onExecution: (() -> Unit)?): Mat = Mats().use { m ->
        val scale = info.scale
        val tileW = if (info.inputWidth > 0) info.inputWidth else 384
        val tileH = if (info.inputHeight > 0) info.inputHeight else 384
        val padX = minOf(16, (tileW - 1) / 3)
        val padY = minOf(16, (tileH - 1) / 3)
        val coreW = tileW - 2 * padX
        val coreH = tileH - 2 * padY
        val output = m.own(Mat(input.rows() * scale, input.cols() * scale, CvType.CV_32FC(info.channels)))
        var checkedContent = false
        var y = 0
        while (y < input.rows()) {
            val h = minOf(coreH, input.rows() - y)
            var x = 0
            while (x < input.cols()) {
                val w = minOf(coreW, input.cols() - x)
                Mats().use { tileMats ->
                    val x0 = maxOf(0, x - padX); val y0 = maxOf(0, y - padY)
                    val x1 = minOf(input.cols(), x + w + padX); val y1 = minOf(input.rows(), y + h + padY)
                    val left = maxOf(0, padX - x); val top = maxOf(0, padY - y)
                    val source = tileMats.own(Mat(input, Rect(x0, y0, x1 - x0, y1 - y0)))
                    val tile = tileMats.create()
                    Core.copyMakeBorder(source, tile, top, tileH - top - source.rows(),
                        left, tileW - left - source.cols(), Core.BORDER_REPLICATE)
                    val prediction = tileMats.own(run(session, tile, info.channels, tileH * scale, tileW * scale))
                    // Stop profiling after the first fixed-shape tile; never accumulate a page-sized trace.
                    onExecution?.invoke()
                    // Compare the first non-flat tile against the actual CPU model, not a color heuristic.
                    if (cpu != null && !checkedContent && hasContent(tile)) {
                        val reference = tileMats.own(run(cpu, tile, info.channels, tileH * scale, tileW * scale))
                        require(contentError(prediction, reference) <= 0.04) {
                            "NNAPI output differs from the CPU reference"
                        }
                        checkedContent = true
                    }
                    val crop = tileMats.own(Mat(prediction, Rect(padX * scale, padY * scale, w * scale, h * scale)))
                    val destination = tileMats.own(Mat(output, Rect(x * scale, y * scale, w * scale, h * scale)))
                    crop.copyTo(destination)
                }
                x += w
            }
            y += h
        }
        m.keep(output)
    }

    private fun hasContent(input: Mat): Boolean {
        val row = FloatArray(input.cols() * input.channels())
        var low = Float.POSITIVE_INFINITY; var high = Float.NEGATIVE_INFINITY
        for (y in 0 until input.rows()) {
            input.get(y, 0, row)
            for (v in row) { low = minOf(low, v); high = maxOf(high, v) }
            if (high - low > 0.02f) return true
        }
        return false
    }

    private fun contentError(prediction: Mat, reference: Mat): Double {
        val channels = prediction.channels()
        val a = FloatArray(prediction.cols() * channels)
        val b = FloatArray(a.size)
        val errors = DoubleArray(channels)
        var count = 0L
        for (y in 0 until prediction.rows()) {
            prediction.get(y, 0, a); reference.get(y, 0, b)
            for (x in 0 until prediction.cols()) {
                val offset = x * channels
                var nearWhite = false
                for (c in 0 until channels) if (b[offset + c] >= 0.9f) { nearWhite = true; break }
                if (nearWhite) continue
                count++
                for (c in 0 until channels) errors[c] += kotlin.math.abs(a[offset + c] - b[offset + c])
            }
        }
        return if (count == 0L) 0.0 else errors.maxOrNull()!! / count
    }

    private fun run(session: OrtSession, input: Mat, channels: Int, height: Int, width: Int): Mat {
        OnnxTensor.createTensor(env, ImageUtils.hwcToNchwFloatBuffer(input),
            longArrayOf(1, channels.toLong(), input.rows().toLong(), input.cols().toLong())).use { tensor ->
            session.run(mapOf(session.inputNames.first() to tensor)).use { results ->
                val output = results[0] as? OnnxTensor ?: throw IllegalArgumentException("Expected tensor output")
                require(output.info.shape.contentEquals(longArrayOf(1, channels.toLong(), height.toLong(), width.toLong()))) {
                    "Unexpected model output dimensions"
                }
                val values = output.floatBuffer
                for (i in 0 until values.remaining()) require(values.get(i).isFinite()) { "Model returned non-finite pixels" }
                return ImageUtils.nchwToHwcMat(values, channels, height, width)
            }
        }
    }

    private fun render(input: Bitmap, base: Base, info: ModelInfo, type: String, width: Int,
                       height: Int, intensity: Float, strength: Float): Bitmap {
        if (type == "deoldify") return renderColor(input, base.pixels, intensity)
        return Mats().use { m ->
            val enhanced = if (info.channels == 3 && intensity == 1f) base.pixels
                else m.own(base.pixels.clone())
            if (intensity != 1f) {
                if (info.channels == 1) {
                    val y = m.create()
                    Core.extractChannel(enhanced, y, 0)
                    y.convertTo(y, CvType.CV_32F, intensity.toDouble(), 0.5 * (1 - intensity))
                    Core.insertChannel(y, enhanced, 0)
                    m.keep(y).release()
                } else {
                    enhanced.convertTo(enhanced, CvType.CV_32F, intensity.toDouble(), 0.5 * (1 - intensity))
                }
            }
            if (info.channels == 1) {
                // The legacy ACNet pipeline used uint8 YCrCb, whose neutral chroma is 128/255.
                val u8 = m.create()
                enhanced.convertTo(u8, CvType.CV_8U, 255.0)
                Imgproc.cvtColor(u8, u8, Imgproc.COLOR_YCrCb2RGB)
                u8.convertTo(enhanced, CvType.CV_32F, 1.0 / 255.0)
                m.keep(u8).release()
            }
            ImageUtils.renderSr(input, enhanced, width, height, strength)
        }
    }

    private fun removeCached(key: CacheKey) {
        cache.remove(key)?.let { cacheBytes -= it.bytes; it.pixels.release() }
    }

    fun resetSession(path: String? = null) {
        cache.keys.filter { path == null || it.model.path == path }.forEach { removeCached(it) }
        metadata.keys.filter { path == null || it.path == path }.forEach { metadata.remove(it) }
        models.reset(path)
    }

    companion object {
        private const val CACHE_LIMIT = 128L * 1024 * 1024
        private const val WORK_LIMIT = 768L * 1024 * 1024
    }
}
