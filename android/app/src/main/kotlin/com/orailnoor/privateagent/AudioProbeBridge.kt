package com.orailnoor.privateagent

import android.content.Context
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.accessibility.AccessibilityNodeInfo
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.sqrt

/**
 * Diagnostics for "can the agent hear a WhatsApp/Telegram call?". It only
 * measures and reports — it never keeps audio. Used by the Call audio test
 * screen:
 *  - probeMic: records ~1s from a given audio source and reports loudness and
 *    whether Android silenced the recording (what happens when another app
 *    owns the microphone during a call).
 *  - dumpWindows: reads the text of every on-screen window through the
 *    accessibility service, which is how Live Caption text would be read.
 */
object AudioProbeBridge {
    private const val CHANNEL = "com.privateagent/audioprobe"
    private val worker = HandlerThread("AudioProbe").apply { start() }
    private val bg = Handler(worker.looper)
    private val main = Handler(Looper.getMainLooper())

    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                handle(call, result, app)
            } catch (t: Throwable) {
                try { result.success(mapOf("error" to t.toString())) } catch (_: Throwable) {}
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result, app: Context) {
        when (call.method) {
            "probeMic" -> {
                val source = call.argument<Int>("source") ?: 1
                val ms = call.argument<Int>("ms") ?: 1200
                bg.post {
                    val out = try { probe(app, source, ms) } catch (t: Throwable) { mapOf("error" to t.toString()) }
                    main.post { try { result.success(out) } catch (_: Throwable) {} }
                }
            }
            "audioState" -> {
                val am = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                result.success(
                    mapOf(
                        "mode" to am.mode, // 0 normal, 1 ringtone, 2 in call, 3 in communication
                        "speakerphone" to am.isSpeakerphoneOn,
                        "micMuted" to am.isMicrophoneMute,
                    ),
                )
            }
            "dumpWindows" -> result.success(dumpWindows())
            else -> result.notImplemented()
        }
    }

    private fun probe(app: Context, source: Int, ms: Int): Map<String, Any?> {
        val rate = 16000
        val min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) return mapOf("error" to "format not supported")
        val rec = try {
            AudioRecord(source, rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, min * 2)
        } catch (t: Throwable) {
            return mapOf("error" to t.toString())
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            return mapOf("error" to "could not open this source")
        }
        val am = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        var silenced: Boolean? = null
        var cb: AudioManager.AudioRecordingCallback? = null
        if (Build.VERSION.SDK_INT >= 29) {
            cb = object : AudioManager.AudioRecordingCallback() {
                override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) {
                    for (c in configs) {
                        if (c.clientAudioSessionId == rec.audioSessionId) silenced = c.isClientSilenced
                    }
                }
            }
            am.registerAudioRecordingCallback(cb, main)
        }
        var sumSq = 0.0
        var count = 0L
        var peak = 0
        var nonZero = 0L
        try {
            rec.startRecording()
            val buf = ShortArray(min)
            val end = System.currentTimeMillis() + ms
            while (System.currentTimeMillis() < end) {
                val n = rec.read(buf, 0, buf.size)
                if (n <= 0) break
                for (i in 0 until n) {
                    val v = buf[i].toInt()
                    val a = if (v < 0) -v else v
                    if (a > peak) peak = a
                    if (a != 0) nonZero++
                    sumSq += v.toDouble() * v
                }
                count += n
            }
            Thread.sleep(150) // let the silenced callback arrive
        } finally {
            try { rec.stop() } catch (_: Throwable) {}
            rec.release()
            if (cb != null) try { am.unregisterAudioRecordingCallback(cb) } catch (_: Throwable) {}
        }
        val rms = if (count > 0) sqrt(sumSq / count) else 0.0
        return mapOf(
            "rms" to rms,
            "peak" to peak,
            "nonZeroRatio" to if (count > 0) nonZero.toDouble() / count else 0.0,
            "silenced" to silenced,
            "samples" to count,
        )
    }

    private fun dumpWindows(): List<Map<String, Any?>>? {
        val svc = AgentAccessibilityService.instance ?: return null
        val out = ArrayList<Map<String, Any?>>()
        for (w in svc.windows) {
            val root = try { w.root } catch (_: Throwable) { null }
            val sb = StringBuilder()
            var budget = 400
            fun walk(n: AccessibilityNodeInfo?, depth: Int) {
                if (n == null || depth > 9 || budget <= 0) return
                budget--
                val t = n.text?.toString()?.trim().orEmpty()
                val d = n.contentDescription?.toString()?.trim().orEmpty()
                if (t.isNotEmpty()) sb.append(t).append(' ') else if (d.isNotEmpty()) sb.append(d).append(' ')
                for (i in 0 until n.childCount) walk(n.getChild(i), depth + 1)
            }
            walk(root, 0)
            out.add(
                mapOf(
                    "pkg" to (root?.packageName?.toString() ?: ""),
                    "type" to w.type,
                    "title" to (w.title?.toString() ?: ""),
                    "text" to sb.toString().take(300),
                ),
            )
        }
        return out
    }
}
