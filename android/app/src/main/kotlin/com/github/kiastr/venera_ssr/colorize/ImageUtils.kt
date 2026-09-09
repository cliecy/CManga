package com.github.kiastr.venera_ssr.colorize

import android.graphics.Bitmap
import org.opencv.android.Utils
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.imgproc.Imgproc
import java.nio.FloatBuffer
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * Bitmap ↔ OpenCV Mat ↔ ONNX FloatBuffer 的编解码工具。
 * 所有通道顺序、值域均对齐桌面版 cv2 行为。
 *
 * 移植自 AiColorize（com.kiastr.aicolorize.ImageUtils），经 Python 参考实现 + 真机模型端到端验证。
 */
object ImageUtils {

    /** Bitmap(ARGB_8888) -> OpenCV BGR Mat(uint8) */
    fun bitmapToBgrMat(bitmap: Bitmap): Mat {
        val rgba = Mat()
        Utils.bitmapToMat(bitmap, rgba, true) // Read straight RGBA, including translucent input.
        val bgr = Mat()
        Imgproc.cvtColor(rgba, bgr, Imgproc.COLOR_RGBA2BGR)
        rgba.release()
        return bgr
    }

    /** OpenCV BGR Mat -> Bitmap(ARGB_8888) */
    fun bgrMatToBitmap(bgr: Mat): Bitmap {
        val rgba = Mat()
        Imgproc.cvtColor(bgr, rgba, Imgproc.COLOR_BGR2RGBA)
        val bmp = Bitmap.createBitmap(bgr.width(), bgr.height(), Bitmap.Config.ARGB_8888)
        Utils.matToBitmap(rgba, bmp)
        rgba.release()
        return bmp
    }

    /**
     * HWC Mat(CV_32F) -> NCHW FloatBuffer [C,H,W]
     * 与 numpy.transpose((2,0,1)) 再 expand_dims(0) 等价。
     */
    fun hwcToNchwFloatBuffer(mat: Mat): FloatBuffer {
        val h = mat.height()
        val w = mat.width()
        val c = mat.channels()
        val data = FloatArray(h * w * c)
        mat.get(0, 0, data) // OpenCV Mat 按 HWC row-major 存储
        val buf = FloatBuffer.allocate(c * h * w)
        for (ch in 0 until c) {
            for (y in 0 until h) {
                for (x in 0 until w) {
                    buf.put(data[(y * w + x) * c + ch])
                }
            }
        }
        buf.rewind()
        return buf
    }

    /**
     * NCHW FloatBuffer [C,H,W] -> HWC Mat(CV_32F)
     * 与 numpy.transpose(1,2,0) 等价。
     *
     * 注意：OpenCV Mat.put 期望 HWC 交错顺序，而模型输出是 NCHW（通道分离），
     * 必须显式转置，否则空间与通道会被打乱（表现为原图线条完好但散布随机彩点）。
     * 这是 Venera 原纯 Dart 实现之外，本项目在 AiColorize 上踩过并修复的根因。
     */
    fun nchwToHwcMat(buf: FloatBuffer, c: Int, h: Int, w: Int): Mat {
        buf.rewind()
        val hwc = FloatArray(c * h * w)
        val plane = h * w
        // 直接从 FloatBuffer 按绝对索引读取（省去一份 NCHW 中间数组），
        // 与 numpy.transpose(1,2,0) 等价：hwc[(y*w+x)*c+ch] = nchw[ch*plane + y*w + x]
        for (ch in 0 until c) {
            val base = ch * plane
            for (y in 0 until h) {
                for (x in 0 until w) {
                    hwc[(y * w + x) * c + ch] = buf.get(base + y * w + x)
                }
            }
        }
        val mat = Mat(h, w, CvType.CV_32FC(c))
        mat.put(0, 0, hwc) // HWC 交错顺序
        return mat
    }

    /** Preserve source alpha without changing the color pipeline's historical luminance. */
    fun copyAlpha(source: Bitmap, target: Bitmap) {
        if (!source.hasAlpha()) return
        val original = IntArray(source.width)
        val rendered = IntArray(target.width)
        for (y in 0 until source.height) {
            source.getPixels(original, 0, source.width, 0, y, source.width, 1)
            target.getPixels(rendered, 0, target.width, 0, y, target.width, 1)
            for (x in rendered.indices) rendered[x] =
                (rendered[x] and 0x00ffffff) or (original[x] and -0x1000000)
            target.setPixels(rendered, 0, target.width, 0, y, target.width, 1)
        }
    }

    private fun linear(value: Float): Float {
        val v = value.coerceIn(0f, 1f)
        return if (v <= 0.04045f) v / 12.92f else ((v + 0.055f) / 1.055f).pow(2.4f)
    }

    private fun encoded(value: Float): Int {
        val v = value.coerceIn(0f, 1f)
        val srgb = if (v <= 0.0031308f) 12.92f * v else 1.055f * v.pow(1f / 2.4f) - 0.055f
        return (srgb * 255f).roundToInt().coerceIn(0, 255)
    }

    private val linearBytes = FloatArray(256) { linear(it / 255f) }

    private fun resize(source: Mat, target: Mat, width: Int, height: Int) {
        if (source.cols() == width && source.rows() == height) {
            source.copyTo(target)
        } else {
            val filter = if (width < source.cols() || height < source.rows())
                Imgproc.INTER_AREA else Imgproc.INTER_CUBIC
            Imgproc.resize(source, target, org.opencv.core.Size(width.toDouble(), height.toDouble()), 0.0, 0.0, filter)
        }
    }

    /**
     * Resize and mix both branches in linear-light premultiplied RGBA. Alpha comes
     * from the source, not the opaque ONNX output. No PNG is used as an inference cache.
     */
    fun renderSr(source: Bitmap, enhancedRgb: Mat?, width: Int, height: Int, strength: Float): Bitmap {
        if (strength == 0f && width == source.width && height == source.height) {
            return checkNotNull(source.copy(Bitmap.Config.ARGB_8888, false)) { "Cannot copy source bitmap" }
        }
        if (strength == 1f && enhancedRgb != null && !source.hasAlpha() &&
            enhancedRgb.cols() == width && enhancedRgb.rows() == height) {
            val rgb = Mat()
            val bgr = Mat()
            try {
                enhancedRgb.convertTo(rgb, CvType.CV_8U, 255.0)
                Imgproc.cvtColor(rgb, bgr, Imgproc.COLOR_RGB2BGR)
                return bgrMatToBitmap(bgr)
            } finally {
                rgb.release()
                bgr.release()
            }
        }
        val original = Mat(source.height, source.width, CvType.CV_32FC4)
        val baseline = Mat()
        val originalAlpha = Mat()
        val nativeAlpha = Mat()
        val enhancedLinear = Mat()
        val enhancedFinal = Mat()
        try {
            val sourceRow = IntArray(source.width)
            val linearRow = FloatArray(source.width * 4)
            for (y in 0 until source.height) {
                source.getPixels(sourceRow, 0, source.width, 0, y, source.width, 1)
                for (x in sourceRow.indices) {
                    val pixel = sourceRow[x]
                    val a = (pixel ushr 24) / 255f
                    val p = x * 4
                    linearRow[p] = linearBytes[(pixel ushr 16) and 255] * a
                    linearRow[p + 1] = linearBytes[(pixel ushr 8) and 255] * a
                    linearRow[p + 2] = linearBytes[pixel and 255] * a
                    linearRow[p + 3] = a
                }
                original.put(y, 0, linearRow)
            }
            resize(original, baseline, width, height)
            var finalEnhanced = enhancedFinal
            if (strength > 0f) {
                require(enhancedRgb != null) { "Missing SR inference output" }
                org.opencv.core.Core.extractChannel(original, originalAlpha, 3)
                resize(originalAlpha, nativeAlpha, enhancedRgb.cols(), enhancedRgb.rows())
                original.release()
                originalAlpha.release()
                enhancedLinear.create(enhancedRgb.rows(), enhancedRgb.cols(), CvType.CV_32FC4)
                val rgbRow = FloatArray(enhancedRgb.cols() * 3)
                val alphaRow = FloatArray(enhancedRgb.cols())
                val rgbaRow = FloatArray(enhancedRgb.cols() * 4)
                for (y in 0 until enhancedRgb.rows()) {
                    enhancedRgb.get(y, 0, rgbRow)
                    nativeAlpha.get(y, 0, alphaRow)
                    for (x in alphaRow.indices) {
                        val a = alphaRow[x].coerceIn(0f, 1f)
                        for (c in 0..2) rgbaRow[x * 4 + c] = linear(rgbRow[x * 3 + c]) * a
                        rgbaRow[x * 4 + 3] = a
                    }
                    enhancedLinear.put(y, 0, rgbaRow)
                }
                nativeAlpha.release()
                if (enhancedLinear.cols() == width && enhancedLinear.rows() == height) {
                    finalEnhanced = enhancedLinear
                } else {
                    resize(enhancedLinear, enhancedFinal, width, height)
                    enhancedLinear.release()
                }
            }
            original.release()
            val output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            // This bitmap is only PNG-encoded, not drawn on a Canvas. Keep straight RGB
            // so ARGB_8888 storage does not quantize it a second time through low alpha.
            output.setPremultiplied(false)
            try {
                val baseRow = FloatArray(width * 4)
                val aiRow = if (strength > 0f) FloatArray(width * 4) else null
                val pixels = IntArray(width)
                for (y in 0 until height) {
                    baseline.get(y, 0, baseRow)
                    if (aiRow != null) finalEnhanced.get(y, 0, aiRow)
                    for (x in 0 until width) {
                        val offset = x * 4
                        val baseAlpha = baseRow[offset + 3].coerceIn(0f, 1f)
                        val aiAlpha = aiRow?.get(offset + 3)?.coerceIn(0f, 1f) ?: baseAlpha
                        // Preserve the same resized source coverage at every strength.
                        var pixel = (baseAlpha * 255f).roundToInt().coerceIn(0, 255) shl 24
                        for (c in 0..2) {
                            // Cubic resize may overshoot. Legalize each branch before mixing so
                            // intermediate strengths interpolate the same colors as the endpoints.
                            val base = (if (baseAlpha > 1e-6f) baseRow[offset + c] / baseAlpha else 0f).coerceIn(0f, 1f)
                            val ai = (if (aiRow != null && aiAlpha > 1e-6f) aiRow[offset + c] / aiAlpha else 0f).coerceIn(0f, 1f)
                            val color = when (strength) {
                                0f -> base
                                1f -> ai
                                else -> base + strength * (ai - base)
                            }
                            pixel = pixel or (encoded(color) shl (16 - c * 8))
                        }
                        pixels[x] = pixel
                    }
                    output.setPixels(pixels, 0, width, 0, y, width, 1)
                }
                return output
            } catch (e: Throwable) {
                output.recycle()
                throw e
            }
        } finally {
            original.release()
            baseline.release()
            originalAlpha.release()
            nativeAlpha.release()
            enhancedLinear.release()
            enhancedFinal.release()
        }
    }
}
