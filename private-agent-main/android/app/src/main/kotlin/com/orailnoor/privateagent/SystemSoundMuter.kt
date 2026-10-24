package com.orailnoor.privateagent

import android.content.Context
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Android's speech recognizer plays a short system "beep" each time it starts
 * listening. In a hands-free call that restarts listening every few seconds,
 * that makes it feel like a walkie-talkie. There's no API to disable the
 * tone, so this mutes the system stream just long enough to cover it.
 */
object SystemSoundMuter {
    private const val CHANNEL = "com.privateagent/systemsound"
    private val handler = Handler(Looper.getMainLooper())
    private var pendingRestore: Runnable? = null

    fun register(flutterEngine: FlutterEngine, context: Context) {
        val appContext = context.applicationContext
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "muteBeepBriefly" -> {
                        val ms = (call.argument<Number>("ms") ?: 1200).toLong()
                        try { muteBriefly(appContext, ms) } catch (_: Throwable) {}
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun muteBriefly(context: Context, durationMs: Long) {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        pendingRestore?.let { handler.removeCallbacks(it) }
        try { am.adjustStreamVolume(AudioManager.STREAM_SYSTEM, AudioManager.ADJUST_MUTE, 0) } catch (_: Throwable) {}
        val restore = Runnable {
            try { am.adjustStreamVolume(AudioManager.STREAM_SYSTEM, AudioManager.ADJUST_UNMUTE, 0) } catch (_: Throwable) {}
            pendingRestore = null
        }
        pendingRestore = restore
        handler.postDelayed(restore, durationMs)
    }
}
