package com.orailnoor.privateagent

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges the fully local, built-in TTS voices (see [LocalTtsEngine]) and
 * the optional natural-voice download (see [NaturalVoiceModelManager]) to
 * Dart. Nothing here requires a separately-run server process — synthesis
 * happens in-process via sherpa-onnx, and the only network traffic is the
 * one-time, user-initiated natural-voice download.
 */
object LocalTtsBridge {
    private const val CHANNEL = "com.privateagent/localtts"

    @Volatile private var downloadProgress = -2 // -2 = idle, -1 = unknown size, 0..100 = percent, 101 = failed
    private val worker = HandlerThread("LocalTtsBridge").apply { start() }
    private val bgHandler = Handler(worker.looper)
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(flutterEngine: FlutterEngine, context: Context) {
        val appContext = context.applicationContext
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "speak" -> {
                        val text = call.argument<String>("text") ?: ""
                        val voice = call.argument<String>("voice") ?: "hindi"
                        val speed = (call.argument<Number>("speed") ?: 1.0).toFloat()
                        bgHandler.post {
                            val ok = try {
                                LocalTtsEngine.speak(appContext, text, voice, speed)
                            } catch (e: Exception) {
                                false
                            }
                            mainHandler.post { result.success(ok) }
                        }
                    }
                    "stop" -> {
                        LocalTtsEngine.stop()
                        result.success(true)
                    }
                    "isHindiReady" -> result.success(LocalTtsEngine.isHindiReady(appContext))
                    "isNaturalReady" -> result.success(LocalTtsEngine.isNaturalReady(appContext))
                    "downloadNatural" -> {
                        if (downloadProgress in 0..100) {
                            result.success(false) // already downloading
                        } else {
                            downloadProgress = -1
                            bgHandler.post {
                                val ok = NaturalVoiceModelManager.ensureModel(appContext) { pct ->
                                    downloadProgress = pct
                                }
                                downloadProgress = if (ok) 100 else 101
                                mainHandler.post { result.success(ok) }
                            }
                        }
                    }
                    "naturalDownloadProgress" -> result.success(downloadProgress)
                    "deleteNatural" -> {
                        bgHandler.post {
                            NaturalVoiceModelManager.deleteModel(appContext)
                            LocalTtsEngine.release()
                            downloadProgress = -2
                            mainHandler.post { result.success(true) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
