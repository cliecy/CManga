package com.cmanga.reader.colorize

import ai.onnxruntime.OrtEnvironment
import android.app.Activity
import android.app.Application
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.opencv.android.OpenCVLoader
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Shared AI map protocol. All native work and session mutation share one bounded worker. */
class ColorizePlugin private constructor(context: Context, private val channel: MethodChannel) :
    MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "com.cmanga.reader/colorize"

        fun registerWith(context: Context, messenger: BinaryMessenger) {
            val channel = MethodChannel(messenger, CHANNEL)
            val plugin = ColorizePlugin(context, channel)
            channel.setMethodCallHandler(plugin)
            if (context is Activity) plugin.attachLifecycle(context)
        }
    }

    private val context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val executor = ThreadPoolExecutor(1, 1, 0L, TimeUnit.MILLISECONDS,
        ArrayBlockingQueue<Runnable>(8), ThreadPoolExecutor.AbortPolicy())
    private var engine: ColorizeEngine? = null
    @Volatile private var closed = false

    private fun getEngine(): ColorizeEngine {
        engine?.let { return it }
        check(OpenCVLoader.initDebug()) { "OpenCV native libraries failed to load" }
        return ColorizeEngine(File(context.cacheDir, "image_ai_profiles"), context).also { engine = it }
    }

    private fun attachLifecycle(activity: Activity) {
        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityDestroyed(destroyed: Activity) {
                if (destroyed !== activity) return
                closed = true
                channel.setMethodCallHandler(null)
                activity.application.unregisterActivityLifecycleCallbacks(this)
                // Queued requests belong to the detached Flutter surface. Never reply to it.
                executor.queue.clear()
                executor.execute { engine?.resetSession(); engine = null }
                executor.shutdown()
            }
            override fun onActivityCreated(activity: Activity, state: Bundle?) {}
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) {}
        }
        activity.application.registerActivityLifecycleCallbacks(callbacks)
    }

    private fun reply(action: () -> Unit) { main.post { if (!closed) action() } }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (closed) {
            result.error("AI_CLOSED", "AI engine is detached", null)
            return
        }
        if (call.method !in setOf("getCapabilities", "getModelInfo", "colorize", "resetSession", "copyUri")) {
            result.notImplemented()
            return
        }
        try {
            executor.execute {
                if (closed) return@execute
                try {
                    val value: Any? = when (call.method) {
                        "getCapabilities" -> capabilities()
                        "getModelInfo" -> getEngine().getModelInfo(required(call, "modelPath"), required(call, "type")).toMap()
                        "resetSession" -> { engine?.resetSession(call.argument<String>("modelPath")); null }
                        "copyUri" -> copyUri(required(call, "uri"), required(call, "destPath"))
                        else -> process(call)
                    }
                    reply { result.success(value) }
                } catch (e: Throwable) {
                    val code = when {
                        e is ImageResourceException -> e.code
                        e is OutOfMemoryError -> "memory_limit"
                        call.method == "copyUri" -> "COPY_FAILED"
                        call.method == "getModelInfo" -> "INCOMPATIBLE_MODEL"
                        e is IllegalArgumentException || e is ClassCastException -> "BAD_ARGS"
                        else -> "AI_FAILED"
                    }
                    reply { result.error(code, e.message ?: e.javaClass.simpleName,
                        mapOf("method" to call.method)) }
                }
            }
        } catch (_: RejectedExecutionException) {
            result.error("AI_BUSY", "AI request queue is full", null)
        }
    }

    private fun capabilities(): Map<String, Any?> = try {
        getEngine()
        val backends = mutableListOf("cpu")
        if (OrtEnvironment.getAvailableProviders().any { it.name == "NNAPI" }) backends.add("nnapi")
        mapOf("supported" to true, "types" to listOf("esrgan", "deoldify", "manga_v2", "manga_light", "ddcolor", "anime_deoldify"),
            "backends" to backends, "reason" to null)
    } catch (e: Throwable) {
        mapOf("supported" to false, "types" to emptyList<String>(), "backends" to emptyList<String>(),
            "reason" to (e.message ?: "Android AI native libraries are unavailable"))
    }

    private fun required(call: MethodCall, key: String): String {
        val value = call.argument<String>(key)
        require(!value.isNullOrBlank()) { "$key is required" }
        return value
    }

    private fun number(call: MethodCall, key: String, default: Double): Double =
        call.argument<Number>(key)?.toDouble() ?: default

    private fun process(call: MethodCall): Map<String, Any?> {
        val bytes = call.argument<ByteArray>("imageBytes")
            ?: throw IllegalArgumentException("imageBytes is required")
        val path = required(call, "modelPath")
        val modelId = required(call, "modelId")
        val inputId = required(call, "inputId")
        val type = required(call, "type")
        val backend = call.argument<String>("backend") ?: "auto"
        val intensity = number(call, "intensity", 1.0).toFloat()
        val strength = number(call, "strength", 1.0).toFloat()
        val outputScale = number(call, "outputScale", 0.0)
        val forceReprocess = call.argument<Boolean>("forceReprocess") ?: false
        // Decode bounds before allocating; compressed images can otherwise exhaust the heap.
        val bounds = BitmapFactory.Options().also { it.inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw ImageResourceException("invalid_image", "Cannot read input image dimensions")
        }
        val processor = getEngine()
        processor.validateImage(bounds.outWidth, bounds.outHeight, path, modelId, inputId,
            type, backend, intensity, strength, outputScale, forceReprocess)
        val options = BitmapFactory.Options().also { it.inPreferredConfig = Bitmap.Config.ARGB_8888 }
        val input = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
            ?: throw ImageResourceException("invalid_image", "Cannot decode input image")
        try {
            val output = processor.colorize(input, path, modelId, inputId, type, backend,
                intensity, strength, outputScale, forceReprocess)
            try {
                val encoded = ByteArrayOutputStream()
                check(output.bitmap.compress(Bitmap.CompressFormat.PNG, 100, encoded)) { "PNG encoding failed" }
                return mapOf("imageBytes" to encoded.toByteArray(), "backend" to output.backend,
                    "scale" to output.scale, "cacheHit" to output.cacheHit,
                    "fallbackReason" to output.fallbackReason)
            } finally {
                output.bitmap.recycle()
            }
        } finally {
            input.recycle()
        }
    }

    private fun copyUri(uri: String, destination: String): Long {
        val parsed = Uri.parse(uri)
        val input = if (parsed.scheme == null) FileInputStream(uri)
            else context.contentResolver.openInputStream(parsed)
                ?: throw IllegalArgumentException("Cannot open input stream: $uri")
        return input.use { source ->
            val file = File(destination)
            file.parentFile?.mkdirs()
            FileOutputStream(file).use { output ->
                val count = source.copyTo(output, 64 * 1024)
                output.flush()
                count
            }
        }
    }
}
