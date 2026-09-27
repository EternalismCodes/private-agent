package com.orailnoor.privateagent

import android.content.Context
import android.hardware.ConsumerIrManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Sends raw infrared codes through the phone's built-in IR blaster, if it has one. */
object IrBridge {
    private const val CHANNEL = "com.privateagent/ir"

    fun register(engine: FlutterEngine, ctx: Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            val mgr = ctx.getSystemService(Context.CONSUMER_IR_SERVICE) as? ConsumerIrManager
            when (call.method) {
                "hasEmitter" -> result.success(mgr?.hasIrEmitter() ?: false)
                "transmit" -> {
                    try {
                        if (mgr == null || !mgr.hasIrEmitter()) {
                            result.error("NO_IR", "This phone has no IR blaster.", null)
                            return@setMethodCallHandler
                        }
                        val freq = (call.argument<Number>("frequency") ?: 38000).toInt()
                        val pattern = (call.argument<List<Number>>("pattern") ?: emptyList()).map { it.toInt() }.toIntArray()
                        if (pattern.isEmpty()) {
                            result.error("BAD_PATTERN", "Empty IR pattern.", null)
                            return@setMethodCallHandler
                        }
                        mgr.transmit(freq, pattern)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("IR_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
