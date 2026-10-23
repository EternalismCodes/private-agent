package com.orailnoor.privateagent

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges the fully local TTS voices ([LocalTtsEngine]) and the optional
 * natural-voice download ([NaturalVoiceModelManager]) to Dart. No server
 * process; synthesis is in-process. Every handler is wrapped so that no
 * Throwable (including native-library Errors) can reach the platform thread.
 */
object LocalTtsBridge {
    private const val CHANNEL = "com.privateagent/localtts"

    @Volatile private var downloadProgress = -2 // -2 idle, -1 unknown size, 0..100 percent, 101 failed
    private val worker = HandlerThread("LocalTtsBridge").apply { start() }
    private val bgHandler = Handler(worker.looper)
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(flutterEngine: FlutterEngine, context: Context) {
        val appContext = context.applicationContext
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    handle(call, result, appContext)
                } catch (e: Throwable) {
                    try { result.success(false) } catch (_: Throwable) {}
                }
            }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result, appContext: Context) {
        when (call.method) {
            "speak" -> {
                val text = call.argument<String>("text") ?: ""
                val voice = call.argument<String>("voice") ?: "hindi"
                val speed = (call.argument<Number>("speed") ?: 1.0).toFloat()
                bgHandler.post {
                    val ok = try { LocalTtsEngine.speak(appContext, text, voice, speed) } catch (e: Throwable) { false }
                    mainHandler.post { safeSuccess(result, ok) }
                }
            }
            "stop" -> {
                try { LocalTtsEngine.stop() } catch (_: Throwable) {}
                result.success(true)
            }
            "isHindiReady" -> result.success(try { LocalTtsEngine.isHindiReady(appContext) } catch (e: Throwable) { false })
            "isNaturalReady" -> result.success(try { LocalTtsEngine.isNaturalReady(appContext) } catch (e: Throwable) { false })
            "downloadNatural" -> {
                if (downloadProgress in 0..100) {
                    result.success(false)
                } else {
                    downloadProgress = -1
                    bgHandler.post {
                        val ok = try {
                            NaturalVoiceModelManager.ensureModel(appContext) { pct -> downloadProgress = pct }
                        } catch (e: Throwable) { false }
                        downloadProgress = if (ok) 100 else 101
                        mainHandler.post { safeSuccess(result, ok) }
                    }
                }
            }
            "naturalDownloadProgress" -> result.success(downloadProgress)
            "deleteNatural" -> {
                bgHandler.post {
                    try {
                        NaturalVoiceModelManager.deleteModel(appContext)
                        LocalTtsEngine.release()
                    } catch (_: Throwable) {}
                    downloadProgress = -2
                    mainHandler.post { safeSuccess(result, true) }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun safeSuccess(result: MethodChannel.Result, value: Any?) {
        try { result.success(value) } catch (_: Throwable) {}
    }
}
