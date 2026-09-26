package com.orailnoor.privateagent

import ai.picovoice.porcupine.Porcupine
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
import android.os.Looper
import androidx.core.app.NotificationCompat

/**
 * Listens for a wake word without ever holding the microphone open the way
 * a naive "always recording" implementation would:
 *
 *  - Duty-cycled: listens for [listenMs] then fully closes the AudioRecord
 *    for [idleMs], repeat. The mic is genuinely free most of the time, not
 *    just "not actively used" — nothing else has to fight it for access.
 *  - Auto-pauses (skips a cycle entirely, no AudioRecord opened at all)
 *    whenever the foreground app looks like it needs the mic/camera itself
 *    (camera, video calls, the dialer), checked via the accessibility
 *    service's existing foreground-app tracking.
 *
 * Porcupine itself is a tiny always-on-class keyword spotter (not full
 * speech recognition), so even the "listening" windows are cheap.
 */
class HotwordService : Service() {
    private var porcupine: Porcupine? = null
    private var audioRecord: AudioRecord? = null
    private val handler = Handler(Looper.getMainLooper())
    private var running = false
    private var generation = 0 // bumps on every stop so stray callbacks/threads from a previous cycle are ignored

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
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val prefs = HotwordPrefs.read(applicationContext)
        startForeground(NOTIF_ID, buildNotification("Listening for \"${prefs.keyword}\"…"))
        if (!running) {
            running = true
            isRunning = true
            try {
                porcupine = Porcupine.Builder()
                    .setAccessKey(prefs.accessKey)
                    .setKeyword(Porcupine.BuiltInKeyword.valueOf(prefs.keyword.uppercase()))
                    .build(applicationContext)
            } catch (e: Exception) {
                stopSelf()
                return START_NOT_STICKY
            }
            scheduleCycle(prefs.listenMs, prefs.idleMs, prefs.keyword)
        }
        return START_STICKY
    }

    private fun scheduleCycle(listenMs: Long, idleMs: Long, keyword: String) {
        if (!running) return
        val myGen = generation
        val fg = AgentAccessibilityService.instance?.getCurrentPackage()?.lowercase() ?: ""
        val skip = fg.isNotEmpty() && pauseKeywords.any { fg.contains(it) }
        if (skip) {
            updateNotification("Paused — another app is using the mic/camera")
            handler.postDelayed({ if (generation == myGen) scheduleCycle(listenMs, idleMs, keyword) }, idleMs)
            return
        }
        updateNotification("Listening for \"$keyword\"…")
        listenOnce(myGen)
        handler.postDelayed({
            if (generation != myGen) return@postDelayed
            stopListening()
            handler.postDelayed({ if (generation == myGen) scheduleCycle(listenMs, idleMs, keyword) }, idleMs)
        }, listenMs)
    }

    private fun listenOnce(myGen: Int) {
        val p = porcupine ?: return
        try {
            val bufSize = maxOf(
                AudioRecord.getMinBufferSize(p.sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT),
                p.frameLength * 4,
            )
            val rec = AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION, p.sampleRate,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufSize,
            )
            audioRecord = rec
            rec.startRecording()
            val buffer = ShortArray(p.frameLength)
            Thread {
                try {
                    while (generation == myGen && rec.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                        val read = rec.read(buffer, 0, buffer.size)
                        if (read == buffer.size) {
                            val idx = p.process(buffer)
                            if (idx >= 0 && generation == myGen) {
                                handler.post { onWakeWordDetected() }
                                break
                            }
                        }
                    }
                } catch (_: Exception) {
                } finally {
                    try { if (rec.state == AudioRecord.STATE_INITIALIZED) rec.stop() } catch (_: Exception) {}
                    try { rec.release() } catch (_: Exception) {}
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

    private fun onWakeWordDetected() {
        stopListening()
        HotwordPrefs.setPendingWake(applicationContext, true)
        val i = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
        }
        startActivity(i)
        val prefs = HotwordPrefs.read(applicationContext)
        handler.postDelayed({ scheduleCycle(prefs.listenMs, prefs.idleMs, prefs.keyword) }, 1500)
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
        try { porcupine?.delete() } catch (_: Exception) {}
        porcupine = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?) = null
}

/** Small dedicated prefs file — not the Flutter one, so Dart and native code never fight over the format. */
data class HotwordConfig(val accessKey: String, val keyword: String, val listenMs: Long, val idleMs: Long, val enabled: Boolean)

object HotwordPrefs {
    private const val FILE = "hotword_prefs"

    fun read(context: Context): HotwordConfig {
        val p = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        return HotwordConfig(
            accessKey = p.getString("accessKey", "") ?: "",
            keyword = p.getString("keyword", "PORCUPINE") ?: "PORCUPINE",
            listenMs = p.getLong("listenMs", 1500L),
            idleMs = p.getLong("idleMs", 2500L),
            enabled = p.getBoolean("enabled", false),
        )
    }

    fun write(context: Context, accessKey: String, keyword: String, listenMs: Long, idleMs: Long, enabled: Boolean) {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit()
            .putString("accessKey", accessKey)
            .putString("keyword", keyword)
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
