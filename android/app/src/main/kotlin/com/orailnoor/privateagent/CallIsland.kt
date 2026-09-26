package com.orailnoor.privateagent

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.transition.AutoTransition
import android.transition.TransitionManager
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.animation.LinearInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.abs
import kotlin.math.sin

/**
 * Dynamic-island style status pill drawn natively (no second Flutter engine) at
 * the top of the screen while a call is active. Never touchable, so it can't
 * get in the way of the taps the agent performs.
 */
class CallIsland(context: Context) {
    private val ctx = context.applicationContext
    private val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val main = Handler(Looper.getMainLooper())
    private var frame: FrameLayout? = null
    private var wave: WaveView? = null
    private var label: TextView? = null

    private fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, ctx.resources.displayMetrics)
    private fun dpi(v: Float) = dp(v).toInt()

    fun show(): Boolean {
        if (frame != null) return true
        if (!Settings.canDrawOverlays(ctx)) return false
        return try {
            val bg = GradientDrawable().apply { setColor(Color.BLACK); cornerRadius = dp(22f) }
            val w = WaveView(ctx)
            val t = TextView(ctx).apply {
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
                typeface = Typeface.DEFAULT_BOLD
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
                maxWidth = dpi(230f)
                setPadding(dpi(10f), 0, 0, 0)
                visibility = View.GONE
            }
            val pill = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                background = bg
                elevation = dp(6f)
                setPadding(dpi(14f), dpi(8f), dpi(14f), dpi(8f))
                addView(w, LinearLayout.LayoutParams(dpi(26f), dpi(18f)))
                addView(t, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT))
            }
            val f = FrameLayout(ctx).apply {
                addView(pill, FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
                    Gravity.CENTER_HORIZONTAL or Gravity.TOP))
            }
            val lp = WindowManager.LayoutParams(
                dpi(340f), WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT
            ).apply {
                gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                y = dpi(6f)
                if (Build.VERSION.SDK_INT >= 30) {
                    layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                } else if (Build.VERSION.SDK_INT >= 28) {
                    layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                }
            }
            wm.addView(f, lp)
            frame = f
            wave = w
            label = t
            true
        } catch (e: Exception) {
            frame = null
            false
        }
    }

    fun update(phase: String, detail: String) {
        main.post {
            val f = frame ?: return@post
            val text = when (phase) {
                "thinking" -> "Thinking"
                "speaking" -> "Speaking"
                "acting" -> if (detail.isBlank()) "Working on your phone" else detail
                else -> ""
            }
            val color = when (phase) {
                "thinking" -> 0xFFF59E0B.toInt()
                "acting" -> 0xFF38BDF8.toInt()
                "speaking" -> 0xFF818CF8.toInt()
                "listening" -> 0xFF22C55E.toInt()
                else -> 0xFF94A3B8.toInt()
            }
            val speed = when (phase) { "thinking" -> 0.5f; "acting" -> 0.8f; else -> 1.3f }
            TransitionManager.beginDelayedTransition(f, AutoTransition().setDuration(220))
            label?.text = if (text.length > 40) text.substring(0, 40) + "…" else text
            label?.visibility = if (text.isEmpty()) View.GONE else View.VISIBLE
            wave?.setStyle(color, speed)
        }
    }

    fun hide() {
        val f = frame ?: return
        frame = null
        wave = null
        label = null
        try { wm.removeViewImmediate(f) } catch (e: Exception) { }
    }

    private class WaveView(c: Context) : View(c) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFF22C55E.toInt(); style = Paint.Style.FILL }
        private val rect = RectF()
        private var speed = 1f
        private var t = 0f
        private val anim = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 900
            repeatCount = ValueAnimator.INFINITE
            interpolator = LinearInterpolator()
            addUpdateListener { t += 0.16f * speed; invalidate() }
        }

        fun setStyle(color: Int, s: Float) { paint.color = color; speed = s; invalidate() }
        override fun onAttachedToWindow() { super.onAttachedToWindow(); anim.start() }
        override fun onDetachedFromWindow() { anim.cancel(); super.onDetachedFromWindow() }

        override fun onDraw(canvas: Canvas) {
            val n = 4
            val gap = width * 0.12f
            val bw = (width - gap * (n - 1)) / n
            for (i in 0 until n) {
                val h = height * (0.35f + 0.65f * abs(sin(t + i * 0.9f)))
                val left = i * (bw + gap)
                rect.set(left, (height - h) / 2f, left + bw, (height + h) / 2f)
                canvas.drawRoundRect(rect, bw / 2f, bw / 2f, paint)
            }
        }
    }
}
