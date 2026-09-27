package com.orailnoor.privateagent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Keeps the app process alive while the Telegram remote-control integration
 * is enabled, so the polling loop in [TelegramService] (a plain Dart Timer)
 * keeps firing even with the app backgrounded or the screen off. Without
 * this, Android freezes the process after a short while and "remote"
 * control stops working exactly when it's needed.
 */
object TelegramBridge {
    private const val CHANNEL = "com.privateagent/telegram_service"
    private const val NOTIFICATION_CHANNEL_ID = "telegram_remote"
    private const val NOTIFICATION_ID = 4712

    fun register(engine: FlutterEngine, context: android.content.Context) {
        val appContext = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    try {
                        appContext.startForegroundService(Intent(appContext, TelegramPollService::class.java))
                    } catch (e: Exception) {
                        // Best effort: the Dart polling timer still runs while the
                        // app is in the foreground even if this fails.
                    }
                    result.success(true)
                }
                "stop" -> {
                    appContext.stopService(Intent(appContext, TelegramPollService::class.java))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun notification(context: android.content.Context): Notification {
        val manager = context.getSystemService(Service.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Remote control (Telegram)",
                NotificationManager.IMPORTANCE_MIN
            )
            channel.description = "Keeps PrivateAgent reachable from Telegram while the app is in the background"
            manager.createNotificationChannel(channel)
        }
        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, NOTIFICATION_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        return builder
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("PrivateAgent")
            .setContentText("Reachable from Telegram")
            .setOngoing(true)
            .setContentIntent(open)
            .build()
    }
}

class TelegramPollService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(4712, TelegramBridge.notification(this), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(4712, TelegramBridge.notification(this))
            }
        } catch (e: Exception) {
            stopSelf()
        }
        return START_STICKY
    }
}
