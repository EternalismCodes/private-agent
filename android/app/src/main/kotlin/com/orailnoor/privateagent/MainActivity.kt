package com.orailnoor.privateagent

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import android.graphics.PixelFormat
import android.graphics.Color
import android.view.Gravity
import android.view.WindowManager
import android.view.View
import android.widget.Button
import android.net.Uri

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.privateagent/accessibility"
    private val EVENT_CHANNEL = "com.privateagent/accessibility_events"
    private val CAMERA_CHANNEL = "com.privateagent/camera"
    private var eventSink: EventChannel.EventSink? = null
    private var overlayView: View? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyScheduleFlags(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        applyScheduleFlags(intent)
    }

    /** A scheduled task may start while the phone is locked or the screen is off. */
    private fun applyScheduleFlags(intent: Intent?) {
        if (intent != null && intent.hasExtra(SchedulerBridge.EXTRA_ID) &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1
        ) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    AgentAccessibilityService.eventListener = { eventMap ->
                        runOnUiThread {
                            eventSink?.success(eventMap)
                        }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    AgentAccessibilityService.eventListener = null
                }
            }
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.privateagent/hotword")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val accessKey = call.argument<String>("accessKey") ?: ""
                        val keyword = call.argument<String>("keyword") ?: "PORCUPINE"
                        val listenMs = (call.argument<Number>("listenMs") ?: 1500).toLong()
                        val idleMs = (call.argument<Number>("idleMs") ?: 2500).toLong()
                        if (accessKey.isBlank()) {
                            result.error("NO_ACCESS_KEY", "A Picovoice AccessKey is required.", null)
                        } else {
                            HotwordPrefs.write(applicationContext, accessKey, keyword, listenMs, idleMs, true)
                            val i = Intent(this, HotwordService::class.java)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i) else startService(i)
                            result.success(true)
                        }
                    }
                    "stop" -> {
                        val prefs = HotwordPrefs.read(applicationContext)
                        HotwordPrefs.write(applicationContext, prefs.accessKey, prefs.keyword, prefs.listenMs, prefs.idleMs, false)
                        stopService(Intent(this, HotwordService::class.java))
                        result.success(true)
                    }
                    "isRunning" -> result.success(HotwordService.isRunning)
                    "consumePendingWake" -> result.success(HotwordPrefs.consumePendingWake(applicationContext))
                    else -> result.notImplemented()
                }
            }
        registerAccessibilityChannel(flutterEngine, this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CAMERA_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "takePhoto" -> startPhotoCapture(result)
                    else -> result.notImplemented()
                }
            }
        SchedulerBridge.register(flutterEngine, applicationContext)
        CallBridge.register(flutterEngine, this)
        TelegramBridge.register(flutterEngine, this)
        ClockBridge.register(flutterEngine, applicationContext)
        IrBridge.register(flutterEngine, applicationContext)
        try { LabBridge.register(flutterEngine, applicationContext) } catch (t: Throwable) { }
    }

    /**
     * Silent capture (see SilentCameraCapture) — no camera-app UI, so
     * nothing for the user (or the agent) to tap to confirm a shutter.
     */
    private fun startPhotoCapture(result: MethodChannel.Result) {
        SilentCameraCapture.capture(applicationContext) { path -> result.success(path) }
    }

    companion object {
        fun registerAccessibilityChannel(flutterEngine: FlutterEngine, context: android.content.Context) {
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.privateagent/accessibility")
                .setMethodCallHandler { call, result ->
                    android.util.Log.d("PrivateAgentKotlin", "Received method call: ${call.method}")
                    when (call.method) {
                        "ping" -> result.success(true)

                        "logToNative" -> {
                            val msg = call.argument<String>("message") ?: ""
                            android.util.Log.d("PrivateAgentDart", msg)
                            result.success(true)
                        }

                        "isServiceRunning" -> {
                            result.success(AgentAccessibilityService.isRunning())
                        }

                        "resolveWhatsappChatUri" -> {
                            val name = call.argument<String>("name") ?: ""
                            result.success(resolveWhatsappChatUri(context, name))
                        }

                        "checkOverlayPermission" -> {
                            result.success(Settings.canDrawOverlays(context))
                        }

                        "requestOverlayPermission" -> {
                            val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${context.packageName}"))
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            context.startActivity(intent)
                            result.success(true)
                        }

                        "showMacroOverlay" -> {
                            // Macro overlay requires an Activity context, so we just ignore or return error if called from background
                            result.error("NOT_SUPPORTED", "Macro overlay not supported from background", null)
                        }

                        "hideMacroOverlay" -> {
                            result.success(true)
                        }

                        "openAccessibilitySettings" -> {
                            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            context.startActivity(intent)
                            result.success(true)
                        }

                        "dumpScreen" -> {
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                val nodes = service.dumpScreen()
                                result.success(nodes)
                            }
                        }

                        "takeScreenshot" -> {
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                                    service.takeScreenshot { base64 ->
                                        if (base64 != null) {
                                            result.success(base64)
                                        } else {
                                            result.error("SCREENSHOT_FAILED", "Failed to capture screenshot", null)
                                        }
                                    }
                                } else {
                                    result.error("UNSUPPORTED_VERSION", "Screenshot requires Android 11 (API 30) or higher", null)
                                }
                            }
                        }

                        "clickByText" -> {
                            val text = call.argument<String>("text") ?: ""
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.clickByText(text))
                            }
                        }

                        "clickAt" -> {
                            val x = call.argument<Double>("x")?.toFloat() ?: 0f
                            val y = call.argument<Double>("y")?.toFloat() ?: 0f
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.clickAtCoordinates(x, y))
                            }
                        }

                        "typeText" -> {
                            val text = call.argument<String>("text") ?: ""
                            val hint = call.argument<String>("fieldHint")
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.typeText(text, hint))
                            }
                        }

                        "pressEnter" -> {
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.pressEnter())
                            }
                        }

                        "scroll" -> {
                            val direction = call.argument<String>("direction") ?: "down"
                            val target = call.argument<String>("target")
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.scroll(direction, target))
                            }
                        }

                        "clickFirstVideo" -> {
                            val rank = call.argument<Int>("rank") ?: 1
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.clickFirstVideo(rank))
                            }
                        }

                        "showToast" -> {
                            val message = call.argument<String>("message") ?: ""
                            android.widget.Toast.makeText(context, message, android.widget.Toast.LENGTH_SHORT).show()
                            result.success(true)
                        }

                        "swipe" -> {
                            val startX = call.argument<Double>("startX")?.toFloat() ?: 0f
                            val startY = call.argument<Double>("startY")?.toFloat() ?: 0f
                            val endX = call.argument<Double>("endX")?.toFloat() ?: 0f
                            val endY = call.argument<Double>("endY")?.toFloat() ?: 0f
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.swipe(startX, startY, endX, endY))
                            }
                        }

                        "pressBack" -> {
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.pressBack())
                            }
                        }

                        "pressHome" -> {
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.pressHome())
                            }
                        }

                        "openNotifications" -> {
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.openNotifications())
                            }
                        }

                        "getCurrentPackage" -> {
                            val service = AgentAccessibilityService.instance
                            if (service == null) {
                                result.error("SERVICE_NOT_RUNNING", "Accessibility service is not running", null)
                            } else {
                                result.success(service.getCurrentPackage())
                            }
                        }

                        else -> result.notImplemented()
                    }
                }
        }

        /**
         * WhatsApp writes a row into Android's own Contacts Provider for every
         * synced contact it has a chat with (mimetype
         * vnd.android.cursor.item/vnd.com.whatsapp.profile). Opening
         * ACTION_VIEW on that row's content URI jumps straight into the chat —
         * no phone number needed at all, so it works regardless of whether the
         * saved number has a country code, spaces, or any particular format.
         */
        fun resolveWhatsappChatUri(context: android.content.Context, name: String): String? {
            if (name.isBlank()) return null
            val resolver = context.contentResolver
            val mimeTypes = listOf(
                "vnd.android.cursor.item/vnd.com.whatsapp.profile",
                "vnd.android.cursor.item/vnd.com.whatsapp.w4b.profile",
            )
            for (mime in mimeTypes) {
                try {
                    val cursor = resolver.query(
                        android.provider.ContactsContract.Data.CONTENT_URI,
                        arrayOf(android.provider.ContactsContract.Data._ID, android.provider.ContactsContract.Data.DISPLAY_NAME_PRIMARY),
                        "${android.provider.ContactsContract.Data.MIMETYPE} = ? AND ${android.provider.ContactsContract.Data.DISPLAY_NAME_PRIMARY} LIKE ?",
                        arrayOf(mime, "%$name%"),
                        null,
                    )
                    cursor?.use {
                        var fallbackId: Long? = null
                        while (it.moveToNext()) {
                            val id = it.getLong(it.getColumnIndexOrThrow(android.provider.ContactsContract.Data._ID))
                            val dn = it.getString(it.getColumnIndexOrThrow(android.provider.ContactsContract.Data.DISPLAY_NAME_PRIMARY)) ?: ""
                            if (dn.equals(name, ignoreCase = true)) {
                                return "content://com.android.contacts/data/$id"
                            }
                            if (fallbackId == null) fallbackId = id
                        }
                        if (fallbackId != null) return "content://com.android.contacts/data/$fallbackId"
                    }
                } catch (_: Exception) {}
            }
            return null
        }
    }
}

class BackgroundEngineReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: android.content.Context, intent: android.content.Intent) {
        val engine = io.flutter.embedding.engine.FlutterEngineCache
            .getInstance()
            .get("myCachedEngine")
        if (engine == null) {
            android.util.Log.e("PrivateAgent", "Background engine myCachedEngine was not found")
            return
        }

        android.util.Log.d(
            "PrivateAgent",
            "Registering accessibility channel on myCachedEngine " +
                "(engine=${System.identityHashCode(engine)}, " +
                "dartExecuting=${engine.dartExecutor.isExecutingDart})"
        )
        MainActivity.registerAccessibilityChannel(engine, context.applicationContext)
    }
}
