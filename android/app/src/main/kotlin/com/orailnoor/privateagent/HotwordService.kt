package com.orailnoor.privateagent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import androidx.core.app.NotificationCompat
import org.vosk.Model
import org.vosk.Recognizer

/**
 * Listens for a wake phrase without ever holding the microphone open the way
 * a naive "always recording" implementation would:
 *
 *  - Duty-cycled: listens for [HotwordConfig.listenMs] then fully closes the
 *    AudioRecord for [HotwordConfig.idleMs], repeat. The mic is genuinely
 *    free most of the time — nothing else has to fight it for access.
 *  - Auto-pauses (skips a cycle entirely, no AudioRecord opened at all)
 *    whenever the foreground app looks like it needs the mic/camera itself
 *    (camera, video calls, the dialer), via the accessibility service's
 *    existing foreground-app tracking.
 *
 * Uses Vosk (Apache-2.0, fully offline, no account/AccessKey) instead of a
 * proprietary keyword-spotting SDK — the trade-off is it's a small general
 * speech-recognition model rather than a purpose-built keyword spotter, so
 * each listen burst costs a bit more CPU than a dedicated KWS engine would,
 * but nothing is sent off the phone and there's no usage limit. It also
 * means the wake phrase can be literally anything you type, not limited to
 * a fixed built-in word list.
 */
class HotwordService : Service() {
    private var model: Model? = null
    private var recognizer: Recognizer? = null
    private var audioRecord: AudioRecord? = null
    private val handler = Handler(Looper.getMainLooper())
    private var bgThread: HandlerThread? = null
    private var running = false
    private var generation = 0 // bumps on every stop so stray callbacks/threads from a previous cycle are ignored

    private val sampleRate = 16000f

    private val pauseKeywords = listOf(
        "camera", "whatsapp", "instagram", "telegram", "messenger", "zoom",
        "meet", "duo", "snapchat", "skype", "discord", "signal", "viber",
        "dialer", "incallui", ".phone",
    )

    companion object {
        const val CHANNEL_ID = "hotword_service"
        const val NOTIF_ID = 5501
        @Volatile var isRunning = false
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
        bgThread = HandlerThread("HotwordSetup").apply { start() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val prefs = HotwordPrefs.read(applicationContext)
        startForeground(NOTIF_ID, buildNotification("Setting up wake word…"))
        if (!running) {
            running = true
            isRunning = true
            Handler(bgThread!!.looper).post {
                if (!VoskModelManager.isReady(applicationContext)) {
                    updateNotification("Downloading speech model (one-time, ~40MB)…")
                    val ok = VoskModelManager.ensureModel(applicationContext) { pct ->
                        if (pct >= 0) updateNotification("Downloading speech model… $pct%")
                    }
                    if (!ok) {
                        updateNotification("Could not download the speech model — check your connection and re-enable in Settings.")
                        stopSelf()
                        return@post
                    }
                }
                try {
                    model = Model(VoskModelManager.modelDir(applicationContext).absolutePath)
                    recognizer = Recognizer(model, sampleRate)
                } catch (e: Exception) {
                    updateNotification("Could not load the speech model.")
                    stopSelf()
                    return@post
                }
                handler.post { scheduleCycle(prefs.listenMs, prefs.idleMs, prefs.wakePhrase) }
            }
        }
        return START_STICKY
    }

    private fun scheduleCycle(listenMs: Long, idleMs: Long, phrase: String) {
        if (!running) return
        val myGen = generation
        val fg = AgentAccessibilityService.instance?.getCurrentPackage()?.lowercase() ?: ""
        val skip = fg.isNotEmpty() && pauseKeywords.any { fg.contains(it) }
        if (skip) {
            updateNotification("Paused — another app is using the mic/camera")
            handler.postDelayed({ if (generation == myGen) scheduleCycle(listenMs, idleMs, phrase) }, idleMs)
            return
        }
        updateNotification("Listening for \"$phrase\"…")
        listenOnce(myGen, phrase)
        handler.postDelayed({
            if (generation != myGen) return@postDelayed
            stopListening()
            handler.postDelayed({ if (generation == myGen) scheduleCycle(listenMs, idleMs, phrase) }, idleMs)
        }, listenMs)
    }

    private fun listenOnce(myGen: Int, phrase: String) {
        val rec = recognizer ?: return
        try {
            rec.reset()
            val minBuf = AudioRecord.getMinBufferSize(sampleRate.toInt(), AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            val frame = 2048
            val bufSize = maxOf(minBuf, frame * 4)
            val ar = AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION, sampleRate.toInt(),
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufSize,
            )
            audioRecord = ar
            ar.startRecording()
            val buffer = ShortArray(frame)
            val target = phrase.trim().lowercase()
            Thread {
                try {
                    while (generation == myGen && ar.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                        val read = ar.read(buffer, 0, buffer.size)
                        if (read > 0 && generation == myGen) {
                            rec.acceptWaveForm(buffer, read)
                            val partial = try {
                                org.json.JSONObject(rec.partialResult).optString("partial", "")
                            } catch (_: Exception) {
                                ""
                            }
                            if (target.isNotEmpty() && partial.contains(target)) {
                                handler.post { onWakeWordDetected(phrase) }
                                break
                            }
                        }
                    }
                } catch (_: Exception) {
                } finally {
                    try { if (ar.state == AudioRecord.STATE_INITIALIZED) ar.stop() } catch (_: Exception) {}
                    try { ar.release() } catch (_: Exception) {}
                }
            }.start()
        } catch (_: Exception) {}
    }

    private fun stopListening() {
        generation++
        try { audioRecord?.stop() } catch (_: Exception) {}
        try { audioRecord?.release() } catch (_: Exception) {}
        audioRecord = null
    }

    private fun onWakeWordDetected(phrase: String) {
        stopListening()
        HotwordPrefs.setPendingWake(applicationContext, true)
        val i = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
        }
        startActivity(i)
        val prefs = HotwordPrefs.read(applicationContext)
        // Brief pause so it doesn't immediately re-trigger on the same utterance's tail end.
        handler.postDelayed({ scheduleCycle(prefs.listenMs, prefs.idleMs, prefs.wakePhrase) }, 1800)
    }

    private fun buildNotification(text: String): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("PrivateAgent")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

    private fun updateNotification(text: String) {
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIF_ID, buildNotification(text))
        } catch (_: Exception) {}
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Wake word listening", NotificationManager.IMPORTANCE_LOW),
                )
            }
        }
    }

    override fun onDestroy() {
        running = false
        isRunning = false
        stopListening()
        handler.removeCallbacksAndMessages(null)
        try { recognizer?.close() } catch (_: Exception) {}
        try { model?.close() } catch (_: Exception) {}
        recognizer = null
        model = null
        bgThread?.quitSafely()
        bgThread = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?) = null
}

/** Small dedicated prefs file — not the Flutter one, so Dart and native code never fight over the format. */
data class HotwordConfig(val wakePhrase: String, val listenMs: Long, val idleMs: Long, val enabled: Boolean)

object HotwordPrefs {
    private const val FILE = "hotword_prefs"

    fun read(context: Context): HotwordConfig {
        val p = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        return HotwordConfig(
            wakePhrase = p.getString("wakePhrase", "hey agent") ?: "hey agent",
            listenMs = p.getLong("listenMs", 2000L),
            idleMs = p.getLong("idleMs", 2500L),
            enabled = p.getBoolean("enabled", false),
        )
    }

    fun write(context: Context, wakePhrase: String, listenMs: Long, idleMs: Long, enabled: Boolean) {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit()
            .putString("wakePhrase", wakePhrase)
            .putLong("listenMs", listenMs)
            .putLong("idleMs", idleMs)
            .putBoolean("enabled", enabled)
            .apply()
    }

    fun setPendingWake(context: Context, value: Boolean) {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit().putBoolean("pendingWake", value).apply()
    }

    fun consumePendingWake(context: Context): Boolean {
        val p = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        val v = p.getBoolean("pendingWake", false)
        if (v) p.edit().putBoolean("pendingWake", false).apply()
        return v
    }
}
