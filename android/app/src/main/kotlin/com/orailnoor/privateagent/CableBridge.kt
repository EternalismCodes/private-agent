package com.orailnoor.privateagent

import android.content.Context
import android.content.pm.PackageManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Facts the Dart side needs to start the virtual-cable helper (see CableMain):
 * where this app's APK is, and which Linux uids the call apps run as.
 */
object CableBridge {
    private const val CHANNEL = "com.privateagent/cable"

    // WhatsApp, WhatsApp Business, Telegram (+ web build, + Telegram X), Signal.
    private val callApps = listOf(
        "com.whatsapp", "com.whatsapp.w4b",
        "org.telegram.messenger", "org.telegram.messenger.web", "org.thunderdog.challegram",
        "org.thoughtcrime.securesms",
    )

    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> {
                    val pm = app.packageManager
                    val uids = LinkedHashMap<String, Int>()
                    for (pkg in callApps) {
                        try { uids[pkg] = pm.getApplicationInfo(pkg, 0).uid } catch (_: PackageManager.NameNotFoundException) {}
                    }
                    result.success(mapOf("apk" to app.applicationInfo.sourceDir, "uids" to uids))
                }
                else -> result.notImplemented()
            }
        }
    }
}
