package com.orailnoor.privateagent

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Own alarm/timer scheduling, used when no Clock app accepts SET_ALARM / SET_TIMER. */
object ClockBridge {
    private const val CHANNEL = "com.privateagent/clock"

    fun register(engine: FlutterEngine, ctx: Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "schedule" -> {
                    try {
                        val at = (call.argument<Number>("at") ?: 0).toLong()
                        val label = call.argument<String>("label") ?: ""
                        val kind = call.argument<String>("kind") ?: "timer"
                        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                        val i = Intent(ctx, ClockReceiver::class.java).putExtra("label", label).putExtra("kind", kind)
                        val op = PendingIntent.getBroadcast(
                            ctx, (at % 1000000000L).toInt(), i,
                            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                        )
                        val show = PendingIntent.getActivity(ctx, 0, Intent(ctx, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
                        am.setAlarmClock(AlarmManager.AlarmClockInfo(at, show), op)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("CLOCK", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}

/** Fires at the scheduled time: starts the ringing alarm service directly (does not depend on
 * notification permission being granted, unlike a plain notification). */
class ClockReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val label = intent.getStringExtra("label") ?: ""
        val kind = intent.getStringExtra("kind") ?: "timer"
        val svc = Intent(context, RingingAlarmService::class.java)
        svc.putExtra("label", label)
        svc.putExtra("kind", kind)
        context.startForegroundService(svc)
    }
}
