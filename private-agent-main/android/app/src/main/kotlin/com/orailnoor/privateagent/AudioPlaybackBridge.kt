package com.orailnoor.privateagent

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

/**
 * Plays a short WAV clip and reports back when it finishes. Used to play
 * audio synthesized by an external TTS server (Piper or similar) during a
 * voice call — flutter_tts only speaks through the OS voice engine, it can't
 * play arbitrary audio bytes, so calls need this instead.
 */
object AudioPlaybackBridge {
    private const val CHANNEL = "com.privateagent/audio_playback"
    private var player: MediaPlayer? = null

    fun register(engine: FlutterEngine, context: Context) {
        val appContext = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "playAndWait" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null || bytes.isEmpty()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    playAndWait(appContext, bytes, result)
                }
                "stop" -> {
                    stopInternal()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun playAndWait(context: Context, bytes: ByteArray, result: MethodChannel.Result) {
        val main = Handler(Looper.getMainLooper())
        var file: File? = null
        try {
            stopInternal()
            file = File.createTempFile("call_tts_", ".wav", context.cacheDir)
            FileOutputStream(file).use { it.write(bytes) }

            val mp = MediaPlayer()
            mp.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            mp.setDataSource(file.absolutePath)
            val cleanupFile = file
            mp.setOnCompletionListener { mpDone ->
                cleanupFile.delete()
                mpDone.release()
                if (player === mpDone) player = null
                main.post { result.success(true) }
            }
            mp.setOnErrorListener { mpErr, _, _ ->
                cleanupFile.delete()
                mpErr.release()
                if (player === mpErr) player = null
                main.post { result.success(false) }
                true
            }
            player = mp
            mp.prepare()
            mp.start()
        } catch (e: Exception) {
            file?.delete()
            result.success(false)
        }
    }

    private fun stopInternal() {
        try {
            player?.let {
                if (it.isPlaying) it.stop()
                it.release()
            }
        } catch (e: Exception) {
            // best effort
        }
        player = null
    }
}
