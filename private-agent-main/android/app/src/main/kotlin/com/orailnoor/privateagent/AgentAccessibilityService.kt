package com.orailnoor.privateagent

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Bitmap
import android.hardware.HardwareBuffer
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.util.Base64
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import androidx.annotation.RequiresApi
import java.io.ByteArrayOutputStream

class AgentAccessibilityService : AccessibilityService() {

    private val ownPackageName = "com.orailnoor.privateagent"

    companion object {
        var instance: AgentAccessibilityService? = null
            private set
            
        var eventListener: ((Map<String, Any>) -> Unit)? = null

        fun isRunning(): Boolean = instance != null
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val listener = eventListener ?: return
        
        // Filter out events from our own app so we don't record the Stop Overlay button clicks
        if (event.packageName?.toString() == "com.orailnoor.privateagent") return
        
        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_CLICKED -> {
                val node = event.source
                var text = node?.text?.toString() ?: node?.contentDescription?.toString() ?: ""
                if (text.isEmpty() && event.text.isNotEmpty()) {
                    text = event.text.joinToString(" ")
                }
                
                val rect = Rect()
                node?.getBoundsInScreen(rect)
                val cx = rect.centerX()
                val cy = rect.centerY()
                
                // Only record if we have valid text or valid coordinates
                if (text.isNotEmpty() || (cx != 0 || cy != 0)) {
                    val map = mapOf(
                        "type" to "click",
                        "text" to text,
                        "x" to cx,
                        "y" to cy
                    )
                    listener(map)
                }
                node?.recycle()
            }
            AccessibilityEvent.TYPE_VIEW_SCROLLED -> {
                val map = mapOf("type" to "scroll")
                listener(map)
            }
        }
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        super.onDestroy()
        instance = null
    }

    // ─── Screen Reading ──────────────────────────────────────────

    /** Dump the current screen as a flat list of UI elements */
    fun dumpScreen(): List<Map<String, Any?>> {
        val nodes = mutableListOf<Map<String, Any?>>()
        val allWindows = windows
        if (allWindows == null || allWindows.isEmpty()) {
            val root = rootInActiveWindow ?: return emptyList()
            if (root.packageName?.toString() != ownPackageName) {
                traverseNode(root, nodes, 0)
            }
            root.recycle()
            return nodes
        }
        
        for (window in allWindows) {
            val root = window.root ?: continue
            if (root.packageName?.toString() == ownPackageName) {
                root.recycle()
                continue
            }
            traverseNode(root, nodes, 0)
            root.recycle()
        }
        return nodes
    }

    private fun traverseNode(
        node: AccessibilityNodeInfo,
        nodes: MutableList<Map<String, Any?>>,
        depth: Int
    ) {
        val rect = Rect()
        node.getBoundsInScreen(rect)

        val text = node.text?.toString() ?: ""
        val contentDesc = node.contentDescription?.toString() ?: ""
        val className = node.className?.toString() ?: ""
        val viewId = node.viewIdResourceName ?: ""

        // Filter out completely hidden or zero-size nodes (like scrolled-out WebView elements)
        val isZeroSize = rect.width() <= 0 || rect.height() <= 0
        if (!node.isVisibleToUser || isZeroSize) {
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                traverseNode(child, nodes, depth + 1)
                child.recycle()
            }
            return
        }

        // Only include nodes that have text/description or are interactive
        if (text.isNotEmpty() || contentDesc.isNotEmpty() ||
            node.isClickable || node.isEditable || node.isScrollable
        ) {
            nodes.add(
                mapOf(
                    "index" to nodes.size,
                    "text" to text,
                    "contentDescription" to contentDesc,
                    "className" to className.substringAfterLast('.'),
                    "viewId" to viewId,
                    "isClickable" to node.isClickable,
                    "isEditable" to node.isEditable,
                    "isScrollable" to node.isScrollable,
                    "isCheckable" to node.isCheckable,
                    "isChecked" to node.isChecked,
                    "isFocused" to node.isFocused,
                    "bounds" to mapOf(
                        "left" to rect.left,
                        "top" to rect.top,
                        "right" to rect.right,
                        "bottom" to rect.bottom
                    ),
                    "depth" to depth
                )
            )
        }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            traverseNode(child, nodes, depth + 1)
            child.recycle()
        }
    }

    /** Capture screenshot as Base64 string */
    @RequiresApi(Build.VERSION_CODES.R)
    fun takeScreenshot(callback: (String?) -> Unit) {
        takeScreenshot(
            Display.DEFAULT_DISPLAY,
            mainExecutor,
            object : TakeScreenshotCallback {
                override fun onSuccess(screenshotResult: ScreenshotResult) {
                    val hardwareBuffer = screenshotResult.hardwareBuffer
                    val bitmap = Bitmap.wrapHardwareBuffer(hardwareBuffer, screenshotResult.colorSpace)
                        ?.copy(Bitmap.Config.ARGB_8888, false)
                    
                    hardwareBuffer.close()

                    if (bitmap != null) {
                        // Compress to lower quality JPEG to save bytes for the API
                        val byteArrayOutputStream = ByteArrayOutputStream()
                        bitmap.compress(Bitmap.CompressFormat.JPEG, 60, byteArrayOutputStream)
                        val byteArray = byteArrayOutputStream.toByteArray()
                        val base64String = Base64.encodeToString(byteArray, Base64.NO_WRAP)
                        callback(base64String)
                    } else {
                        callback(null)
                    }
                }

                override fun onFailure(errorCode: Int) {
                    callback(null)
                }
            }
        )
    }

    // ─── Actions ─────────────────────────────────────────────────

    /** Find and click a node by its text content */
    fun clickByText(targetText: String): Boolean {
        for (window in windows) {
            val root = window.root ?: continue
            if (root.packageName?.toString() == ownPackageName) {
                root.recycle()
                continue
            }
            // Prefer an actual suggestion/button over an editable search field
            // that contains the same query. Editables remain the final fallback
            // so the agent can still focus a search box by its label.
            val result = findAndClickNode(root, targetText, true, true)
                || findAndClickNode(root, targetText, false, true)
                || findAndClickNode(root, targetText, true, false)
                || findAndClickNode(root, targetText, false, false)
            root.recycle()
            if (result) return true
        }
        return false
    }

    private fun findAndClickNode(
        node: AccessibilityNodeInfo,
        targetText: String,
        exactOnly: Boolean,
        skipEditable: Boolean
    ): Boolean {
        val text = node.text?.toString() ?: ""
        val desc = node.contentDescription?.toString() ?: ""

        val exactMatch = text.equals(targetText, ignoreCase = true)
            || desc.equals(targetText, ignoreCase = true)
        val containsMatch = text.contains(targetText, ignoreCase = true)
            || desc.contains(targetText, ignoreCase = true)
        val matches = if (exactOnly) exactMatch else containsMatch

        if (matches && (!skipEditable || !node.isEditable) && clickNodeOrParent(node)) {
            return true
        }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            if (findAndClickNode(child, targetText, exactOnly, skipEditable)) {
                child.recycle()
                return true
            }
            child.recycle()
        }
        return false
    }

    private fun clickNodeOrParent(node: AccessibilityNodeInfo): Boolean {
        var clickTarget: AccessibilityNodeInfo? = node
        while (clickTarget != null && !clickTarget.isClickable) {
            clickTarget = clickTarget.parent
        }
        if (clickTarget?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true) {
            return true
        }

        val rect = Rect()
        node.getBoundsInScreen(rect)
        return !rect.isEmpty && clickAtCoordinates(
            rect.centerX().toFloat(),
            rect.centerY().toFloat()
        )
    }

    /** Click at specific coordinates using gesture */
    fun clickAtCoordinates(x: Float, y: Float): Boolean {
        val path = Path()
        path.moveTo(x, y)
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 100))
            .build()
        return dispatchGesture(gesture, null, null)
    }

    fun typeText(text: String, fieldHint: String? = null): Boolean {
        for (window in windows) {
            val root = window.root ?: continue
            if (root.packageName?.toString() == ownPackageName) {
                root.recycle()
                continue
            }

            var editNode = findEditableNode(root, fieldHint)
            if (editNode == null && !fieldHint.isNullOrEmpty()) {
                editNode = findEditableNode(root, null)
            }

            if (editNode != null) {
                editNode.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
                val args = Bundle()
                args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
                val success = editNode.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                root.recycle()
                return success
            }
            root.recycle()
        }
        return false
    }

    /** Submit the focused field through the IME, with keyboard-aware fallbacks. */
    fun pressEnter(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            for (window in windows) {
                val root = window.root ?: continue
                if (root.packageName?.toString() == ownPackageName) {
                    root.recycle()
                    continue
                }
                val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                val submitted = focused?.performAction(
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id
                ) == true
                focused?.recycle()
                root.recycle()
                if (submitted) return true
            }
        }

        for (window in windows) {
            val root = window.root ?: continue
            val actionNode = findKeyboardActionNode(root)
            val submitted = actionNode != null && clickNodeOrParent(actionNode)
            actionNode?.recycle()
            root.recycle()
            if (submitted) return true
        }

        // Tap inside the actual IME window, avoiding the navigation bar.
        for (window in windows) {
            if (window.type != AccessibilityWindowInfo.TYPE_INPUT_METHOD) continue
            val bounds = Rect()
            window.getBoundsInScreen(bounds)
            if (!bounds.isEmpty) {
                val x = bounds.right - (bounds.width() * 0.10f)
                val y = bounds.bottom - (bounds.height() * 0.14f)
                return clickAtCoordinates(x, y)
            }
        }
        return false
    }

    private fun findKeyboardActionNode(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        val label = (node.text?.toString().orEmpty().ifEmpty {
            node.contentDescription?.toString().orEmpty()
        }).trim().lowercase()
        val actionLabels = setOf("search", "enter", "go", "done", "send", "next")
        if (node.isClickable && (label in actionLabels || label.endsWith(" search"))) {
            return AccessibilityNodeInfo.obtain(node)
        }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findKeyboardActionNode(child)
            child.recycle()
            if (found != null) return found
        }
        return null
    }

    private fun findEditableNode(
        node: AccessibilityNodeInfo,
        hint: String?
    ): AccessibilityNodeInfo? {
        if (node.isEditable) {
            if (hint == null) return node
            val text = node.text?.toString() ?: ""
            val desc = node.contentDescription?.toString() ?: ""
            val hintText = node.hintText?.toString() ?: ""
            if (text.contains(hint, ignoreCase = true) ||
                desc.contains(hint, ignoreCase = true) ||
                hintText.contains(hint, ignoreCase = true)
            ) {
                return node
            }
            // If no hint match but this is the first editable, return it
            if (hint.isNullOrEmpty()) return node
        }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findEditableNode(child, hint)
            if (found != null) return found
            child.recycle()
        }
        return null
    }

    /** Scroll forward on the first scrollable element, or a specific one by text */
    fun scroll(direction: String, targetText: String? = null): Boolean {
        for (window in windows) {
            val root = window.root ?: continue
            if (root.packageName?.toString() == ownPackageName) {
                root.recycle()
                continue
            }
            val scrollNode = findScrollableNode(root, targetText)
            if (scrollNode != null) {
                val action = when (direction.lowercase()) {
                    "down", "forward" -> AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                    "up", "backward" -> AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                    else -> AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                }
                val success = scrollNode.performAction(action)
                root.recycle()
                return success
            }
            root.recycle()
        }
        return false
    }

    private fun findScrollableNode(
        node: AccessibilityNodeInfo,
        targetText: String?
    ): AccessibilityNodeInfo? {
        if (node.isScrollable) {
            if (targetText == null) return node
            val text = node.text?.toString() ?: ""
            val desc = node.contentDescription?.toString() ?: ""
            if (text.contains(targetText, ignoreCase = true) ||
                desc.contains(targetText, ignoreCase = true)
            ) {
                return node
            }
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findScrollableNode(child, targetText)
            if (found != null) return found
            child.recycle()
        }
        return null
    }

    /** Press the global back button */
    fun pressBack(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_BACK)
    }

    /** Press the global home button */
    fun pressHome(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_HOME)
    }

    /** Open recent apps */
    fun openRecents(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_RECENTS)
    }

    /** Open notifications */
    fun openNotifications(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
    }

    /** Swipe gesture */
    fun swipe(startX: Float, startY: Float, endX: Float, endY: Float, durationMs: Long = 300): Boolean {
        val path = Path()
        path.moveTo(startX, startY)
        path.lineTo(endX, endY)
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs))
            .build()
        return dispatchGesture(gesture, null, null)
    }

    /** Long press at coordinates */
    fun longPressAt(x: Float, y: Float): Boolean {
        val path = Path()
        path.moveTo(x, y)
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 1000))
            .build()
        return dispatchGesture(gesture, null, null)
    }

    /** Get the currently focused app's package name */
    fun getCurrentPackage(): String? {
        var ownApplicationSeen = false
        var fallbackApplication: String? = null

        for (window in windows) {
            val root = window.root ?: continue
            val pkg = root.packageName?.toString()
            root.recycle()

            if (pkg == null || window.type != AccessibilityWindowInfo.TYPE_APPLICATION) {
                continue
            }

            // An active PrivateAgent application window is the main Flutter app.
            // Return it so TaskExecutor can press Home before taking its first dump.
            // The floating overlay is a system overlay, not an application window.
            if (window.isActive || window.isFocused) {
                return pkg
            }

            if (pkg == ownPackageName) {
                ownApplicationSeen = true
            } else if (fallbackApplication == null) {
                fallbackApplication = pkg
            }
        }

        return fallbackApplication ?: if (ownApplicationSeen) ownPackageName else null
    }
}
