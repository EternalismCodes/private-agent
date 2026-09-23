package com.orailnoor.privateagent

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Keeps a PrivateAgent voice call alive while another app is on screen.
 *
 * Android only lets an app use the microphone in the background while it runs a
 * foreground service of type "microphone", so a call starts [CallService] (with
 * an ongoing "Hang up" notification). The call UI itself is plain Dart; this
 * bridge only starts/stops the service, moves the app to the background and
 * forwards the notification's Hang up button back to Dart.
 */
object CallBridge {
    private const val CHANNEL = "com.privateagent/call"
    private var channel: MethodChannel? = null

    fun register(engine: FlutterEngine, activity: Activity) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "start", "update" -> {
                    try {
                        val intent = Intent(activity, CallService::class.java)
                        intent.action = CallService.ACTION_START
                        intent.putExtra(CallService.EXTRA_TEXT, call.argument<String>("text") ?: "Listening")
                        activity.startForegroundService(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("CALL_SERVICE", e.message, null)
                    }
                }
                "stop" -> {
                    activity.stopService(Intent(activity, CallService::class.java))
                    result.success(true)
                }
                "minimize" -> {
                    activity.moveTaskToBack(true)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun notifyHangup() {
        Handler(Looper.getMainLooper()).post {
            channel?.invokeMethod("hangup", null)
        }
    }
}

/** Foreground service (type: microphone) that keeps the call's mic access alive. */
class CallService : Service() {
    companion object {
        const val ACTION_START = "com.orailnoor.privateagent.CALL_START"
        const val ACTION_HANGUP = "com.orailnoor.privateagent.CALL_HANGUP"
        const val EXTRA_TEXT = "call_text"
        private const val CHANNEL_ID = "agent_call"
        private const val NOTIFICATION_ID = 4711
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_HANGUP) {
            CallBridge.notifyHangup()
            stopSelf()
            return START_NOT_STICKY
        }
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Listening"
        try {
            startInForeground(text)
        } catch (e: Exception) {
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startInForeground(text: String) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(CHANNEL_ID, "Voice call", NotificationManager.IMPORTANCE_LOW)
        channel.description = "Shown while you are on a call with PrivateAgent"
        manager.createNotificationChannel(channel)

        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val hangup = PendingIntent.getService(
            this,
            1,
            Intent(this, CallService::class.java).setAction(ACTION_HANGUP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val action = Notification.Action.Builder(
            Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
            "Hang up",
            hangup
        ).build()

        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("PrivateAgent call")
            .setContentText(text)
            .setOngoing(true)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setSubText("Listening…")
            .setContentIntent(open)
            .addAction(action)
            .setShowWhen(true)
            .setUsesChronometer(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }
}
