package com.orailnoor.privateagent

import android.app.Activity
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/** Full-screen "time's up" screen shown even over the lock screen; taps Dismiss to stop the alarm. */
class AlarmRingActivity : Activity() {
    companion object {
        var instance: AlarmRingActivity? = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        instance = this
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val title = TextView(this).apply {
            text = if (RingingAlarmService.kind == "timer") "Timer finished" else "Alarm"
            setTextColor(Color.WHITE)
            textSize = 26f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
        }
        val sub = TextView(this).apply {
            text = RingingAlarmService.label.ifEmpty { "Time's up" }
            setTextColor(0xFFBBBBBB.toInt())
            textSize = 16f
            gravity = Gravity.CENTER
            setPadding(0, 24, 0, 64)
        }
        val dismiss = Button(this).apply {
            text = "Dismiss"
            setOnClickListener {
                startService(
                    android.content.Intent(this@AlarmRingActivity, RingingAlarmService::class.java)
                        .setAction(RingingAlarmService.ACTION_DISMISS)
                )
            }
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.BLACK)
            setPadding(48, 48, 48, 48)
            addView(title)
            addView(sub)
            addView(dismiss)
        }
        setContentView(root)
    }

    override fun onDestroy() {
        if (instance == this) instance = null
        super.onDestroy()
    }

    override fun onBackPressed() {
        // Require the Dismiss button; back alone shouldn't silently stop the alarm.
    }
}
