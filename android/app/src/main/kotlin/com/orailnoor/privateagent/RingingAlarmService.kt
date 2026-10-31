package com.orailnoor.privateagent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.RingtoneManager
import android.os.Build
import android.os.IBinder
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * A real ringing alarm/timer, independent of notification permission and of which
 * clock app is installed: loops the system alarm sound on the ALARM stream, vibrates,
 * and shows a full-screen "time's up" screen even over the lock screen. "Dismiss"
 * (from the notification action or the full-screen screen) stops it.
 */
class RingingAlarmService : Service() {
    companion object {
        const val CHANNEL_ID = "agent_alarms"
        const val NOTIF_ID = 4712
        const val ACTION_DISMISS = "com.orailnoor.privateagent.ALARM_DISMISS"
        @Volatile var isRinging = false
            private set
        var label: String = ""
            private set
        var kind: String = "timer"
            private set
    }

    private var player: android.media.MediaPlayer? = null
    private var vibrator: Vibrator? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_DISMISS) {
            stopRinging()
            return START_NOT_STICKY
        }
        label = intent?.getStringExtra("label") ?: ""
        kind = intent?.getStringExtra("kind") ?: "timer"
        isRinging = true
        startForeground(NOTIF_ID, buildNotification())
        startSoundAndVibration()
        try {
            startActivity(
                Intent(this, AlarmRingActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            )
        } catch (e: Exception) { }
        return START_STICKY
    }

    private fun buildNotification(): Notification {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val ch = NotificationChannel(CHANNEL_ID, "Alarms & timers", NotificationManager.IMPORTANCE_HIGH)
        ch.setSound(null, null) // the service itself plays the sound, on the ALARM stream
        ch.enableVibration(false)
        nm.createNotificationChannel(ch)

        val full = PendingIntent.getActivity(
            this, 0,
            Intent(this, AlarmRingActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val dismiss = PendingIntent.getService(
            this, 1,
            Intent(this, RingingAlarmService::class.java).setAction(ACTION_DISMISS),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val title = if (kind == "timer") "Timer finished" else "Alarm"
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(title)
            .setContentText(if (label.isNotEmpty()) label else "Time's up")
            .setCategory(Notification.CATEGORY_ALARM)
            .setOngoing(true)
            .setFullScreenIntent(full, true)
            .setContentIntent(full)
            .addAction(Notification.Action.Builder(android.R.drawable.ic_menu_close_clear_cancel, "Dismiss", dismiss).build())
            .build()
    }

    private fun startSoundAndVibration() {
        try {
            val uri = RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getValidRingtoneUri(this)
            val p = android.media.MediaPlayer()
            p.setAudioAttributes(
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
            )
            p.setDataSource(this, uri)
            p.isLooping = true
            p.setVolume(1f, 1f)
            p.prepare()
            p.start()
            player = p
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.setStreamVolume(AudioManager.STREAM_ALARM, (am.getStreamMaxVolume(AudioManager.STREAM_ALARM) * 0.85).toInt(), 0)
        } catch (e: Exception) { }
        try {
            val v = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
            } else {
                @Suppress("DEPRECATION") getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
            vibrator = v
            val pattern = longArrayOf(0, 700, 500)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION") v.vibrate(pattern, 0)
            }
        } catch (e: Exception) { }
    }

    private fun stopRinging() {
        isRinging = false
        try { player?.stop(); player?.release() } catch (e: Exception) { }
        player = null
        try { vibrator?.cancel() } catch (e: Exception) { }
        try { AlarmRingActivity.instance?.finish() } catch (e: Exception) { }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        try { player?.stop(); player?.release() } catch (e: Exception) { }
        try { vibrator?.cancel() } catch (e: Exception) { }
        isRinging = false
        super.onDestroy()
    }
}
