package com.orailnoor.privateagent

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The "app assistant" overlay: a card at the top of the screen, drawn over
 * whatever app the user is in. It shows
 *  - a status line (what the assistant is doing) with a close button,
 *  - quick-action chips for the current kind of app (shopping, video...),
 *  - BIG text cards for answers (a price, a rating, a subscriber count...),
 *  - a yes/no confirmation.
 * While the assistant is acting on the phone the card is made untouchable so it
 * can never intercept the taps the agent performs.
 */
class AssistOverlay(context: Context, private val emit: (String, Map<String, Any?>) -> Unit) {
    private val ctx = context.applicationContext
    private val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val main = Handler(Looper.getMainLooper())

    private var root: LinearLayout? = null
    private var params: WindowManager.LayoutParams? = null
    private var statusText: TextView? = null
    private var dot: View? = null
    private var chipsScroll: HorizontalScrollView? = null
    private var chipsRow: LinearLayout? = null
    private var bigBox: LinearLayout? = null
    private var bigLabel: TextView? = null
    private var bigValue: TextView? = null
    private var bigSub: TextView? = null
    private var confirmBox: LinearLayout? = null
    private var confirmText: TextView? = null
    private var hideBig: Runnable? = null

    private fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, ctx.resources.displayMetrics)
    private fun dpi(v: Float) = dp(v).toInt()

    private fun rounded(color: Int, radius: Float) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radius)
    }

    private fun text(size: Float, color: Int, bold: Boolean = false) = TextView(ctx).apply {
        setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
        setTextColor(color)
        if (bold) typeface = Typeface.DEFAULT_BOLD
    }

    fun canShow() = Settings.canDrawOverlays(ctx)

    fun show(): Boolean {
        if (root != null) return true
        if (!canShow()) return false
        return try {
            val card = LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                background = rounded(0xF2111418.toInt(), 24f)
                elevation = dp(10f)
                setPadding(dpi(14f), dpi(10f), dpi(14f), dpi(12f))
            }

            // Header: dot + status + close
            val d = View(ctx).apply { background = rounded(0xFF22C55E.toInt(), 8f) }
            val status = text(13.5f, Color.WHITE, true).apply {
                maxLines = 2
                ellipsize = TextUtils.TruncateAt.END
            }
            val close = text(18f, 0xFF94A3B8.toInt(), true).apply {
                this.text = "✕"
                setPadding(dpi(12f), 0, 0, 0)
                setOnClickListener { emit("close", emptyMap()) }
            }
            val header = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(d, LinearLayout.LayoutParams(dpi(10f), dpi(10f)).apply { rightMargin = dpi(10f) })
                addView(status, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
                addView(close)
            }
            card.addView(header)

            // Chips
            val row = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL }
            val scroll = HorizontalScrollView(ctx).apply {
                isHorizontalScrollBarEnabled = false
                visibility = View.GONE
                addView(row)
            }
            card.addView(scroll, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dpi(10f) })

            // Big answer card
            val bl = text(13f, 0xFF94A3B8.toInt(), true).apply { gravity = Gravity.CENTER }
            val bv = text(46f, Color.WHITE, true).apply {
                gravity = Gravity.CENTER
                maxLines = 2
                ellipsize = TextUtils.TruncateAt.END
            }
            val bs = text(14f, 0xFFCBD5E1.toInt()).apply {
                gravity = Gravity.CENTER
                maxLines = 4
                ellipsize = TextUtils.TruncateAt.END
            }
            val big = LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                background = rounded(0xFF1E293B.toInt(), 18f)
                setPadding(dpi(16f), dpi(12f), dpi(16f), dpi(14f))
                visibility = View.GONE
                addView(bl)
                addView(bv)
                addView(bs)
                setOnClickListener { hideBigNow() }
            }
            card.addView(big, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dpi(10f) })

            // Confirmation
            val ct = text(15f, Color.WHITE, true)
            fun action(label: String, color: Int, value: Boolean) = Button(ctx).apply {
                this.text = label
                setTextColor(Color.WHITE)
                isAllCaps = false
                background = rounded(color, 14f)
                setOnClickListener {
                    hideConfirm()
                    emit("confirm", mapOf("value" to value))
                }
            }
            val buttons = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(action("Yes, go ahead", 0xFF16A34A.toInt(), true), LinearLayout.LayoutParams(0, dpi(44f), 1f).apply { rightMargin = dpi(8f) })
                addView(action("No, cancel", 0xFFDC2626.toInt(), false), LinearLayout.LayoutParams(0, dpi(44f), 1f))
            }
            val conf = LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                background = rounded(0xFF3B1D1D.toInt(), 18f)
                setPadding(dpi(14f), dpi(12f), dpi(14f), dpi(12f))
                visibility = View.GONE
                addView(ct)
                addView(buttons, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dpi(10f) })
            }
            card.addView(conf, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dpi(10f) })

            val metrics = ctx.resources.displayMetrics
            val lp = WindowManager.LayoutParams(
                metrics.widthPixels - dpi(24f),
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                y = dpi(28f)
                if (Build.VERSION.SDK_INT >= 30) {
                    layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                }
            }
            wm.addView(card, lp)
            root = card
            params = lp
            statusText = status
            dot = d
            chipsScroll = scroll
            chipsRow = row
            bigBox = big
            bigLabel = bl
            bigValue = bv
            bigSub = bs
            confirmBox = conf
            confirmText = ct
            true
        } catch (e: Exception) {
            root = null
            false
        }
    }

    private fun setTouchable(touchable: Boolean) {
        val r = root ?: return
        val lp = params ?: return
        val flag = WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        lp.flags = if (touchable) lp.flags and flag.inv() else lp.flags or flag
        try { wm.updateViewLayout(r, lp) } catch (_: Exception) {}
    }

    /** mode: "pick" (choose an app), "panel" (chips), "acting" (working, untouchable), "idle". */
    fun setState(mode: String, text: String, chips: List<Pair<String, String>>) {
        main.post {
            if (root == null && !show()) return@post
            statusText?.text = text
            val color = when (mode) {
                "acting" -> 0xFF38BDF8.toInt()
                "pick" -> 0xFFF59E0B.toInt()
                "panel" -> 0xFF22C55E.toInt()
                else -> 0xFF94A3B8.toInt()
            }
            dot?.background = rounded(color, 8f)
            val row = chipsRow
            row?.removeAllViews()
            if (mode == "panel" && chips.isNotEmpty()) {
                for ((id, label) in chips) {
                    val chip = text(13.5f, Color.WHITE, true).apply {
                        this.text = label
                        background = rounded(0xFF2B3440.toInt(), 16f)
                        setPadding(dpi(14f), dpi(8f), dpi(14f), dpi(8f))
                        setOnClickListener { emit("chip", mapOf("id" to id)) }
                    }
                    row?.addView(chip, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { rightMargin = dpi(8f) })
                }
                chipsScroll?.visibility = View.VISIBLE
            } else {
                chipsScroll?.visibility = View.GONE
            }
            setTouchable(mode != "acting")
        }
    }

    /** A big answer: label (small), value (huge), sub (small). Tap to dismiss. */
    fun showBig(label: String, value: String, sub: String, ms: Long) {
        main.post {
            if (root == null && !show()) return@post
            bigLabel?.text = label
            bigValue?.text = value
            // Longer values get a smaller (but still big) size so they fit.
            bigValue?.setTextSize(TypedValue.COMPLEX_UNIT_SP, if (value.length <= 8) 52f else if (value.length <= 14) 38f else 26f)
            bigSub?.text = sub
            bigSub?.visibility = if (sub.isBlank()) View.GONE else View.VISIBLE
            bigBox?.visibility = View.VISIBLE
            setTouchable(true)
            hideBig?.let { main.removeCallbacks(it) }
            val r = Runnable { hideBigNow() }
            hideBig = r
            main.postDelayed(r, ms)
        }
    }

    private fun hideBigNow() {
        hideBig?.let { main.removeCallbacks(it) }
        hideBig = null
        bigBox?.visibility = View.GONE
    }

    fun showConfirm(text: String) {
        main.post {
            if (root == null && !show()) return@post
            confirmText?.text = text
            confirmBox?.visibility = View.VISIBLE
            setTouchable(true)
        }
    }

    private fun hideConfirm() {
        confirmBox?.visibility = View.GONE
    }

    fun clearConfirm() = main.post { hideConfirm() }

    fun hide() {
        main.post {
            val r = root ?: return@post
            root = null
            hideBig?.let { main.removeCallbacks(it) }
            try { wm.removeViewImmediate(r) } catch (_: Exception) {}
        }
    }
}

/** Flutter channel for [AssistOverlay]. */
object AssistBridge {
    private const val CHANNEL = "com.privateagent/assist"
    private var overlay: AssistOverlay? = null

    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        val o = AssistOverlay(app) { event, args ->
            Handler(Looper.getMainLooper()).post { ch.invokeMethod(event, args) }
        }
        overlay = o
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "canShow" -> result.success(o.canShow())
                "show" -> result.success(o.show())
                "state" -> {
                    val chips = (call.argument<List<Map<String, String>>>("chips") ?: emptyList())
                        .map { (it["id"] ?: "") to (it["label"] ?: "") }
                    o.setState(call.argument<String>("mode") ?: "idle", call.argument<String>("text") ?: "", chips)
                    result.success(true)
                }
                "big" -> {
                    o.showBig(
                        call.argument<String>("label") ?: "",
                        call.argument<String>("value") ?: "",
                        call.argument<String>("sub") ?: "",
                        (call.argument<Number>("ms") ?: 9000).toLong(),
                    )
                    result.success(true)
                }
                "confirm" -> {
                    o.showConfirm(call.argument<String>("text") ?: "")
                    result.success(true)
                }
                "clearConfirm" -> {
                    o.clearConfirm()
                    result.success(true)
                }
                "hide" -> {
                    o.hide()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
