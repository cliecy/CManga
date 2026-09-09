package com.github.kiastr.venera_ssr.colorize

import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import ai.onnxruntime.providers.NNAPIFlags
import org.json.JSONArray
import java.io.File
import java.util.EnumSet

/** Used only by the bridge's serial worker; CPU and NNAPI are never mislabeled. */
class ModelManager(private val env: OrtEnvironment, private val profileDirectory: File) {
    class Session(val ort: OrtSession, val requestedNnapi: Boolean) {
        var backend = "cpu"
            private set
        var fallbackReason: String? = null
            private set
        private var profiling = requestedNnapi

        /** Inspect executed nodes, not just the list of registered providers. */
        fun recordExecution() {
            if (!profiling) return
            profiling = false
            var file: File? = null
            try {
                file = File(ort.endProfiling())
                val events = JSONArray(file.readText())
                var nnapi = false
                var cpu = false
                for (i in 0 until events.length()) {
                    val provider = events.optJSONObject(i)?.optJSONObject("args")
                        ?.optString("provider") ?: continue
                    if (provider.contains("Nnapi", ignoreCase = true)) nnapi = true
                    if (provider == "CPUExecutionProvider") cpu = true
                }
                backend = if (nnapi) "nnapi" else "cpu"
                fallbackReason = when {
                    !nnapi -> "NNAPI did not execute any nodes; ONNX Runtime used CPU."
                    cpu -> "NNAPI with CPU execution for unsupported operators."
                    else -> null
                }
            } catch (e: Exception) {
                // The caller must rerun on an explicit CPU session rather than guess.
                throw IllegalStateException("Cannot verify NNAPI execution: ${e.message}", e)
            } finally {
                file?.delete()
            }
        }

        fun close() {
            try {
                if (profiling) File(ort.endProfiling()).delete()
            } finally {
                ort.close()
            }
        }
    }

    private data class Key(val path: String, val identity: String, val nnapi: Boolean)
    private val sessions = LinkedHashMap<Key, Session>(4, 0.75f, true)

    fun getSession(path: String, identity: String, nnapi: Boolean): Session {
        val obsolete = sessions.keys.filter { it.path == path && it.identity != identity }
        obsolete.forEach { sessions.remove(it)?.close() }
        val key = Key(path, identity, nnapi)
        sessions[key]?.let { return it }
        // At most two models plus the SR CPU reference session may remain resident.
        while (sessions.size >= 3) {
            val eldest = sessions.entries.iterator()
            eldest.next().value.close()
            eldest.remove()
        }
        val session = OrtSession.SessionOptions().use { options ->
            options.setExecutionMode(OrtSession.SessionOptions.ExecutionMode.SEQUENTIAL)
            if (nnapi) {
                check(profileDirectory.isDirectory || profileDirectory.mkdirs()) {
                    "Cannot create ONNX profiling directory"
                }
                options.addNnapi(EnumSet.of(NNAPIFlags.CPU_DISABLED))
                options.enableProfiling(File(profileDirectory, "nnapi-${System.nanoTime()}").path)
            } else {
                options.addCPU(true)
            }
            Session(env.createSession(path, options), nnapi)
        }
        sessions[key] = session
        return session
    }

    fun discard(path: String, identity: String, nnapi: Boolean) {
        sessions.remove(Key(path, identity, nnapi))?.close()
    }

    fun reset(path: String? = null) {
        val iterator = sessions.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            if (path == null || entry.key.path == path) {
                try { entry.value.close() } finally { iterator.remove() }
            }
        }
    }
}
