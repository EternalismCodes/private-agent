package com.orailnoor.privateagent

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.util.Base64
import android.view.Display
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import org.json.JSONArray
import org.json.JSONObject

/**
 * EXPERIMENTAL (vision screenshots + "Teach" recording/replay). Everything is
 * isolated and wrapped in try/catch so a failure here can never affect the
 * rest of the app.
 */
object LabBridge {
    private const val CHANNEL = "com.privateagent/lab"
    var channel: MethodChannel? = null

    fun register(engine: FlutterEngine, ctx: Context) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                val svc = AgentAccessibilityService.instance
                when (call.method) {
                    "screenshot" -> {
                        if (svc == null) {
                            result.success(null)
                        } else {
                            LabTools.screenshot(svc, call.argument<Int>("maxSide") ?: 1280, call.argument<Int>("quality") ?: 65) { r ->
                                result.success(r)
                            }
                        }
                    }
                    "recStart" -> result.success(if (svc == null) false else LabRecorder.start(svc, call.argument<String>("pkg") ?: ""))
                    "recStop" -> result.success(LabRecorder.stop())
                    "recActive" -> result.success(LabRecorder.active)
                    "replayClick" -> result.success(
                        if (svc == null) false else LabTools.replayClick(svc, call.argument<String>("step") ?: "{}", call.argument<String>("match"))
                    )
                    "replayType" -> result.success(
                        if (svc == null) false else LabTools.replayType(svc, call.argument<String>("step") ?: "{}", call.argument<String>("text") ?: "")
                    )
                    "replayEnter" -> result.success(if (svc == null) false else LabTools.replayEnter(svc))
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                try { result.error("LAB", t.message, null) } catch (e: Throwable) { }
            }
        }
    }
}

object LabTools {
    private const val OWN = "com.orailnoor.privateagent"

    fun roots(svc: AccessibilityService): List<AccessibilityNodeInfo> {
        val out = ArrayList<AccessibilityNodeInfo>()
        val ws = svc.windows
        if (ws != null) {
            for (w in ws) {
                val r = w.root ?: continue
                if (r.packageName?.toString() == OWN) continue
                out.add(r)
            }
        }
        if (out.isEmpty()) {
            val r = svc.rootInActiveWindow
            if (r != null && r.packageName?.toString() != OWN) out.add(r)
        }
        return out
    }

    fun walk(n: AccessibilityNodeInfo, depth: Int, f: (AccessibilityNodeInfo) -> Unit) {
        if (depth > 45) return
        f(n)
        for (i in 0 until n.childCount) {
            val c = n.getChild(i) ?: continue
            walk(c, depth + 1, f)
        }
    }

    fun screenshot(svc: AccessibilityService, maxSide: Int, quality: Int, cb: (Map<String, Any>?) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            cb(null)
            return
        }
        var done = false
        fun finish(v: Map<String, Any>?) {
            if (!done) {
                done = true
                cb(v)
            }
        }
        try {
            svc.takeScreenshot(
                Display.DEFAULT_DISPLAY,
                svc.mainExecutor,
                object : AccessibilityService.TakeScreenshotCallback {
                    override fun onSuccess(r: AccessibilityService.ScreenshotResult) {
                        try {
                            val hb = r.hardwareBuffer
                            val bmp = Bitmap.wrapHardwareBuffer(hb, r.colorSpace)?.copy(Bitmap.Config.ARGB_8888, false)
                            hb.close()
                            if (bmp == null) {
                                finish(null)
                                return
                            }
                            val sw = bmp.width
                            val sh = bmp.height
                            val scale = minOf(1f, maxSide.toFloat() / maxOf(sw, sh).toFloat())
                            val out = if (scale < 1f) Bitmap.createScaledBitmap(bmp, (sw * scale).toInt(), (sh * scale).toInt(), true) else bmp
                            val bos = ByteArrayOutputStream()
                            out.compress(Bitmap.CompressFormat.JPEG, quality, bos)
                            finish(
                                mapOf(
                                    "b64" to Base64.encodeToString(bos.toByteArray(), Base64.NO_WRAP),
                                    "w" to out.width, "h" to out.height, "sw" to sw, "sh" to sh
                                )
                            )
                        } catch (e: Throwable) {
                            finish(null)
                        }
                    }

                    override fun onFailure(errorCode: Int) {
                        finish(null)
                    }
                }
            )
        } catch (e: Throwable) {
            finish(null)
        }
    }

    private fun tap(svc: AccessibilityService, x: Float, y: Float): Boolean {
        val p = Path()
        p.moveTo(x, y)
        val g = GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(p, 0, 60)).build()
        return svc.dispatchGesture(g, null, null)
    }

    private fun clickNode(svc: AccessibilityService, n: AccessibilityNodeInfo): Boolean {
        var cur: AccessibilityNodeInfo? = n
        var depth = 0
        while (cur != null && depth < 7) {
            if (cur.isClickable && cur.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
            cur = cur.parent
            depth++
        }
        val r = Rect()
        n.getBoundsInScreen(r)
        return tap(svc, r.exactCenterX(), r.exactCenterY())
    }

    /** The window whose package matches [pkg] and whose area is largest (the actual app
     * content window) — same scoping [LabRecorder.describe] uses so a same-app dialog or
     * banner present only on one of the two runs cannot shift a positional index. Falls
     * back to every non-own window if nothing matches (app package changed, etc.). */
    private fun targetRoots(svc: AccessibilityService, pkg: String): List<AccessibilityNodeInfo> {
        val all = roots(svc)
        if (pkg.isEmpty()) return all
        val matching = all.filter { it.packageName?.toString() == pkg }
        return matching.ifEmpty { all }
    }

    fun replayClick(svc: AccessibilityService, stepJson: String, match: String?): Boolean {
        val s = JSONObject(stepJson)
        val id = s.optString("id", "")
        val text = s.optString("text", "")
        val desc = s.optString("desc", "")
        val cls = s.optString("cls", "")
        val idx = s.optInt("idx", -1)
        val pkg = s.optString("pkg", "")
        val m = (match ?: "").trim().lowercase()
        var best: AccessibilityNodeInfo? = null
        var bestScore = 0
        for (root in targetRoots(svc, pkg)) {
            var counter = 0
            walk(root, 0) { n ->
                val nid = n.viewIdResourceName ?: ""
                val ncls = n.className?.toString() ?: ""
                val sameKey = if (id.isNotEmpty()) nid == id else (cls.isNotEmpty() && ncls == cls)
                val nt = n.text?.toString() ?: ""
                val nd = n.contentDescription?.toString() ?: ""
                var score = 0
                if (n.isVisibleToUser && !(n.isEditable && !cls.contains("EditText"))) {
                    if (m.isNotEmpty()) {
                        val a = nt.lowercase()
                        val d = nd.lowercase()
                        score = if (a == m || d == m) 100 else if (a.contains(m) || d.contains(m)) 60 else 0
                    } else {
                        val tm = text.isNotEmpty() && nt == text
                        val dm = desc.isNotEmpty() && nd == desc
                        score = if (id.isNotEmpty() && sameKey && (tm || dm)) 100
                        else if (sameKey && idx >= 0 && counter == idx) 80
                        else if (tm) 50
                        else if (dm) 45
                        else if (sameKey && id.isNotEmpty()) 20
                        else 0
                    }
                }
                if (sameKey) counter++
                if (score > bestScore) {
                    bestScore = score
                    best = n
                }
            }
        }
        val b = best
        if (b != null && bestScore >= 45) return clickNode(svc, b)
        // Last resort either way: the recorded screen position. A wrong element beats
        // reporting "could not click" outright, and for the very first step of a replay
        // (before anything has moved) it is usually still exactly right.
        val l = s.optInt("l", -1)
        val r = s.optInt("r", -1)
        val tp = s.optInt("tp", -1)
        val bt = s.optInt("b", -1)
        if (l >= 0 && r > l && tp >= 0 && bt > tp) {
            val sw = s.optInt("sw", 0)
            val sh = s.optInt("sh", 0)
            val dm = svc.resources.displayMetrics
            val fx = if (sw > 0) dm.widthPixels.toFloat() / sw else 1f
            val fy = if (sh > 0) dm.heightPixels.toFloat() / sh else 1f
            if (tap(svc, (l + r) / 2f * fx, (tp + bt) / 2f * fy)) return true
        }
        if (b != null) return clickNode(svc, b)
        return false
    }

    fun replayType(svc: AccessibilityService, stepJson: String, text: String): Boolean {
        val s = JSONObject(stepJson)
        val id = s.optString("id", "")
        val cls = s.optString("cls", "")
        val pkg = s.optString("pkg", "")
        var best: AccessibilityNodeInfo? = null
        var bestScore = 0
        for (root in targetRoots(svc, pkg)) {
            walk(root, 0) { n ->
                if (n.isEditable && n.isVisibleToUser) {
                    var score = 1
                    if (n.isFocused) score += 50
                    if (id.isNotEmpty() && n.viewIdResourceName == id) score += 30
                    if (cls.isNotEmpty() && n.className?.toString() == cls) score += 5
                    if (score > bestScore) {
                        bestScore = score
                        best = n
                    }
                }
            }
        }
        val b = best ?: return false
        b.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
        val args = Bundle()
        args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        return b.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    fun replayEnter(svc: AccessibilityService): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        val f = svc.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        return f.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
    }
}

/** Records what the person does in another app (taps, typed text, scrolls) as replayable steps. */
object LabRecorder {
    private const val OWN = "com.orailnoor.privateagent"
    @Volatile var active = false
    private val steps = ArrayList<JSONObject>()
    private var lastAt = 0L
    private var lastJson = "[]"
    private var overlay: View? = null
    private var wm: WindowManager? = null

    fun start(svc: AccessibilityService, targetPkg: String): Boolean {
        hideOverlay()
        steps.clear()
        lastAt = 0L
        lastJson = "[]"
        active = true
        showOverlay(svc)
        return true
    }

    fun stop(): String {
        if (active) {
            active = false
            hideOverlay()
            lastJson = JSONArray(steps).toString()
        }
        return lastJson
    }

    fun onEvent(svc: AccessibilityService, e: AccessibilityEvent) {
        if (!active) return
        val p = e.packageName?.toString() ?: return
        if (p == OWN || p == "com.android.systemui" || p.contains("inputmethod") || p.contains("keyboard")) return
        val type = e.eventType
        if (type != AccessibilityEvent.TYPE_VIEW_CLICKED && type != AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED &&
            type != AccessibilityEvent.TYPE_VIEW_SCROLLED
        ) return
        val now = System.currentTimeMillis()
        val dt = if (lastAt == 0L) 0L else now - lastAt
        val n = e.source
        when (type) {
            AccessibilityEvent.TYPE_VIEW_CLICKED -> {
                if (n == null) return
                val d = describe(svc, n, p)
                val last = steps.lastOrNull()
                if (last != null && last.optString("t") == "click" && last.optString("key") == d.optString("key") && dt < 300) return
                d.put("t", "click")
                d.put("dt", dt)
                steps.add(d)
                lastAt = now
            }
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED -> {
                if (n == null || n.isPassword) return
                val v = e.text?.firstOrNull()?.toString() ?: ""
                val d = describe(svc, n, p)
                val last = steps.lastOrNull()
                if (last != null && last.optString("t") == "type" && last.optString("key") == d.optString("key")) {
                    last.put("val", v)
                } else {
                    d.put("t", "type")
                    d.put("val", v)
                    d.put("dt", dt)
                    steps.add(d)
                }
                lastAt = now
            }
            AccessibilityEvent.TYPE_VIEW_SCROLLED -> {
                val dy = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) e.scrollDeltaY else 0
                if (dy == 0) return
                val dir = if (dy > 0) "down" else "up"
                val last = steps.lastOrNull()
                if (last != null && last.optString("t") == "scroll" && last.optString("dir") == dir) return
                steps.add(JSONObject().put("t", "scroll").put("dir", dir).put("pkg", p).put("dt", dt))
                lastAt = now
            }
        }
    }

    private fun describe(svc: AccessibilityService, n: AccessibilityNodeInfo, p: String): JSONObject {
        val r = Rect()
        n.getBoundsInScreen(r)
        val id = n.viewIdResourceName ?: ""
        val cls = n.className?.toString() ?: ""
        var text = if (n.isEditable) "" else (n.text?.toString() ?: "")
        val desc = n.contentDescription?.toString() ?: ""
        if (text.isEmpty() && desc.isEmpty() && !n.isEditable) text = firstText(n, 0)
        val dm = svc.resources.displayMetrics
        return JSONObject()
            .put("pkg", p).put("id", id).put("cls", cls)
            .put("text", text.take(80)).put("desc", desc.take(80))
            .put("idx", indexOf(n, id, cls))
            .put("key", "$id|$cls|${r.left}|${r.top}")
            .put("l", r.left).put("tp", r.top).put("r", r.right).put("b", r.bottom)
            .put("sw", dm.widthPixels).put("sh", dm.heightPixels)
    }

    private fun firstText(n: AccessibilityNodeInfo, depth: Int): String {
        if (depth > 4) return ""
        for (i in 0 until n.childCount) {
            val c = n.getChild(i) ?: continue
            val t = c.text?.toString() ?: ""
            if (t.isNotEmpty()) return t
            val deeper = firstText(c, depth + 1)
            if (deeper.isNotEmpty()) return deeper
        }
        return ""
    }

    private fun indexOf(n: AccessibilityNodeInfo, id: String, cls: String): Int {
        val root = n.window?.root ?: return -1
        var counter = 0
        var found = -1
        LabTools.walk(root, 0) { x ->
            if (found < 0) {
                val same = if (id.isNotEmpty()) x.viewIdResourceName == id else (cls.isNotEmpty() && x.className?.toString() == cls)
                if (same) {
                    if (x == n) found = counter
                    counter++
                }
            }
        }
        return found
    }

    private fun showOverlay(svc: AccessibilityService) {
        try {
            val dm = svc.resources.displayMetrics
            fun dp(v: Int): Int = (v * dm.density).toInt()
            val bg = GradientDrawable()
            bg.setColor(0xEE111827.toInt())
            bg.cornerRadius = dp(22).toFloat()
            val dot = TextView(svc)
            dot.text = "● REC"
            dot.setTextColor(0xFFEF4444.toInt())
            dot.textSize = 12f
            dot.typeface = Typeface.DEFAULT_BOLD
            val stop = TextView(svc)
            stop.text = "   Stop"
            stop.setTextColor(Color.WHITE)
            stop.textSize = 13f
            stop.typeface = Typeface.DEFAULT_BOLD
            val row = LinearLayout(svc)
            row.orientation = LinearLayout.HORIZONTAL
            row.gravity = Gravity.CENTER_VERTICAL
            row.background = bg
            row.setPadding(dp(14), dp(8), dp(12), dp(8))
            row.addView(dot)
            row.addView(stop)
            row.setOnClickListener { finishFromOverlay(svc) }
            val w = svc.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val lp = WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT
            )
            lp.gravity = Gravity.TOP or Gravity.END
            lp.x = dp(12)
            lp.y = dp(96)
            w.addView(row, lp)
            overlay = row
            wm = w
        } catch (e: Throwable) {
            overlay = null
        }
    }

    private fun hideOverlay() {
        try {
            val v = overlay
            if (v != null) wm?.removeViewImmediate(v)
        } catch (e: Throwable) { }
        overlay = null
    }

    private fun finishFromOverlay(svc: AccessibilityService) {
        val json = stop()
        try { LabBridge.channel?.invokeMethod("recStopped", json) } catch (e: Throwable) { }
        try {
            svc.startActivity(
                Intent(svc, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            )
        } catch (e: Throwable) { }
    }
}
