package com.orailnoor.privateagent

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * Wake-up alarms for PrivateAgent's scheduled tasks.
 *
 * This is completely separate from the accessibility engine. Dart keeps the
 * schedule; this bridge only asks Android's AlarmManager to post a
 * "scheduled task is due" notification at the right moment (surviving reboots)
 * so the app can be brought up to run the task.
 */
object SchedulerBridge {
    private const val CHANNEL = "com.privateagent/scheduler"
    private const val NOTIFICATION_CHANNEL_ID = "scheduled_tasks"
    private const val PREFS = "scheduler_alarms"
    const val EXTRA_ID = "scheduled_task_id"
    const val EXTRA_GOAL = "scheduled_task_goal"

    fun register(engine: FlutterEngine, context: Context) {
        val appContext = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "schedule" -> {
                        val id = call.argument<String>("id")
                        val goal = call.argument<String>("goal") ?: ""
                        val triggerAt = call.argument<Number>("triggerAt")?.toLong()
                        if (id == null || triggerAt == null) {
                            result.error("BAD_ARGS", "id and triggerAt are required", null)
                        } else {
                            schedule(appContext, id, goal, triggerAt)
                            result.success(true)
                        }
                    }
                    "cancel" -> {
                        val id = call.argument<String>("id")
                        if (id != null) cancel(appContext, id)
                        result.success(true)
                    }
                    "cancelAll" -> {
                        val prefs = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                        for (id in prefs.all.keys.toList()) cancel(appContext, id)
                        result.success(true)
                    }
                    "dismiss" -> {
                        val id = call.argument<String>("id")
                        if (id != null) {
                            val manager = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                            manager.cancel(id.hashCode())
                        }
                        result.success(true)
                    }
                    "wakeForRemote" -> {
                        val goal = call.argument<String>("goal") ?: ""
                        wakeAndLaunch(appContext, "telegram", goal)
                        result.success(true)
                    }
                    "releaseWake" -> {
                        releaseWake()
                        result.success(true)
                    }
                    "canDrawOverlays" -> result.success(Settings.canDrawOverlays(appContext))
                    "openOverlaySettings" -> {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:${appContext.packageName}")
                        )
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        appContext.startActivity(intent)
                        result.success(true)
                    }
                    "canScheduleExact" -> result.success(canScheduleExact(appContext))
                    "openExactAlarmSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            val intent = Intent(
                                Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                                Uri.parse("package:${appContext.packageName}")
                            )
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            appContext.startActivity(intent)
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun alarmManager(context: Context): AlarmManager =
        context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

    private fun canScheduleExact(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            alarmManager(context).canScheduleExactAlarms()
        } else {
            true
        }
    }

    private fun pendingIntent(context: Context, id: String, goal: String): PendingIntent {
        val intent = Intent(context, ScheduleReceiver::class.java)
        intent.putExtra(EXTRA_ID, id)
        intent.putExtra(EXTRA_GOAL, goal)
        return PendingIntent.getBroadcast(
            context,
            id.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    fun schedule(context: Context, id: String, goal: String, triggerAt: Long) {
        val pi = pendingIntent(context, id, goal)
        val am = alarmManager(context)
        try {
            if (canScheduleExact(context)) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi)
            } else {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi)
            }
        } catch (e: SecurityException) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi)
        }
        val record = JSONObject()
        record.put("goal", goal)
        record.put("triggerAt", triggerAt)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(id, record.toString()).apply()
    }

    fun cancel(context: Context, id: String) {
        alarmManager(context).cancel(pendingIntent(context, id, ""))
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(id).apply()
    }

    /** Re-registers every stored alarm (used after a reboot). */
    fun rescheduleAll(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        for ((id, value) in prefs.all) {
            try {
                val record = JSONObject(value as String)
                val triggerAt = record.getLong("triggerAt")
                val goal = record.optString("goal", "")
                if (triggerAt > now) {
                    schedule(context, id, goal, triggerAt)
                } else {
                    // Overdue while the phone was off: tell the user right away.
                    postNotification(context, id, goal)
                    prefs.edit().remove(id).apply()
                }
            } catch (e: Exception) {
                prefs.edit().remove(id).apply()
            }
        }
    }

    /**
     * Turns the screen on and, when PrivateAgent may draw over other apps,
     * opens it directly so the task starts without a tap. Otherwise the
     * notification below is the way in.
     */
    private var remoteWl: PowerManager.WakeLock? = null

    fun releaseWake() {
        try { remoteWl?.let { if (it.isHeld) it.release() } } catch (e: Exception) { }
        remoteWl = null
    }

    @Suppress("DEPRECATION")
    fun wakeAndLaunch(context: Context, id: String, goal: String) {
        try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            val wl = pm.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE,
                "PrivateAgent:scheduledTask"
            )
            try { remoteWl?.let { if (it.isHeld) it.release() } } catch (e: Exception) { }
            remoteWl = wl
            wl.acquire(600_000L)
        } catch (e: Exception) {
            // Wake lock is best-effort.
        }
        // Try a direct launch first (works when we already have SYSTEM_ALERT_WINDOW or are
        // otherwise exempt); if Android blocks it, fall back to a full-screen-intent
        // notification, which Android is required to honor regardless of that permission —
        // the same mechanism alarm and incoming-call apps use to appear unprompted.
        var launched = false
        try {
            if (Settings.canDrawOverlays(context)) {
                val launch = Intent(context, MainActivity::class.java)
                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                launch.putExtra(EXTRA_ID, id)
                launch.putExtra(EXTRA_GOAL, goal)
                context.startActivity(launch)
                launched = true
            }
        } catch (e: Exception) { }
        if (!launched) postFullScreenWake(context, id, goal)
    }

    @Suppress("DEPRECATION")
    private fun postFullScreenWake(context: Context, id: String, goal: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(NOTIFICATION_CHANNEL_ID, "Scheduled tasks", NotificationManager.IMPORTANCE_HIGH)
        channel.description = "Tasks PrivateAgent should run at a set time"
        manager.createNotificationChannel(channel)
        val launch = Intent(context, MainActivity::class.java)
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        launch.putExtra(EXTRA_ID, id)
        launch.putExtra(EXTRA_GOAL, goal)
        val full = PendingIntent.getActivity(context, id.hashCode(), launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val n = android.app.Notification.Builder(context, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("PrivateAgent is working on: ")
            .setContentText(if (goal.isBlank()) "A remote task is running." else goal)
            .setCategory(android.app.Notification.CATEGORY_CALL)
            .setFullScreenIntent(full, true)
            .setContentIntent(full)
            .setAutoCancel(true)
            .build()
        manager.notify(id.hashCode(), n)
    }

    @Suppress("DEPRECATION")
    fun postNotification(context: Context, id: String, goal: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Scheduled tasks",
                NotificationManager.IMPORTANCE_HIGH
            )
            channel.description = "Tasks PrivateAgent should run at a set time"
            manager.createNotificationChannel(channel)
        }

        val launch = Intent(context, MainActivity::class.java)
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        launch.putExtra(EXTRA_ID, id)
        launch.putExtra(EXTRA_GOAL, goal)
        val contentIntent = PendingIntent.getActivity(
            context,
            id.hashCode(),
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(context, NOTIFICATION_CHANNEL_ID)
        } else {
            android.app.Notification.Builder(context)
        }
        val text = if (goal.isBlank()) "A scheduled task is due." else goal
        val notification = builder
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("PrivateAgent: scheduled task")
            .setContentText(text)
            .setStyle(android.app.Notification.BigTextStyle().bigText("$text\n\nTap to run it now."))
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .build()
        manager.notify(id.hashCode(), notification)
    }
}

/** Fired by AlarmManager when a scheduled task is due. */
class ScheduleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(SchedulerBridge.EXTRA_ID) ?: return
        val goal = intent.getStringExtra(SchedulerBridge.EXTRA_GOAL) ?: ""
        SchedulerBridge.postNotification(context, id, goal)
        SchedulerBridge.wakeAndLaunch(context, id, goal)
        context.getSharedPreferences("scheduler_alarms", Context.MODE_PRIVATE)
            .edit().remove(id).apply()
    }
}

/** Restores the alarms after the phone restarts. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            SchedulerBridge.rescheduleAll(context)
            val hw = HotwordPrefs.read(context)
            if (hw.enabled && hw.accessKey.isNotBlank()) {
                val i = Intent(context, HotwordService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(i) else context.startService(i)
            }
        }
    }
}
