package com.orailnoor.privateagent

import android.content.Context
import android.content.ContextWrapper
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Looper
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.system.exitProcess

/**
 * The "virtual cable" helper. It is NOT run inside the app: PrivateAgent starts
 * it through Shizuku with
 *
 *   CLASSPATH=<base.apk> app_process /system/bin com.orailnoor.privateagent.CableMain <port> <token> <uid,uid,..>
 *
 * so it runs as the shell user, which holds MODIFY_AUDIO_ROUTING. That is what
 * lets it register an audio policy with a RECORDER (loop-back) mix: every AudioRecord opened
 * by the listed call apps (WhatsApp, Telegram...) is fed from an AudioTrack that
 * we write to, instead of from the real microphone. The agent's voice therefore
 * reaches the other person with no speaker, no echo and no room noise.
 *
 * Everything touching the audio-policy system API is reflection, because those
 * classes are @SystemApi and absent from the public SDK.
 *
 * Wire protocol (TCP, 127.0.0.1 only):
 *   client -> "HELLO <token>\n"      helper -> "OK <rate> <channels>\n" | "ERR <why>\n"
 *   then frames: [type:1][len:4 big-endian][payload]
 *     'P' payload = [sampleRate:4 BE][PCM16 little-endian mono ...]   play (queued)
 *     'F' flush: drop everything not yet played
 *     'Q' quit
 */
object CableMain {
    private const val LOG = "/data/local/tmp/pa_cable.log"
    private const val RULE_MATCH_UID = 0x1 shl 2 // AudioMixingRule.RULE_MATCH_UID
    private const val RULE_MATCH_CAPTURE_PRESET = 0x1 shl 1 // RULE_MATCH_ATTRIBUTE_CAPTURE_PRESET
    private const val MIX_TYPE_RECORDER = 1
    // A RECORDER mix that apps' microphone recordings are re-routed into; we then
    // inject audio into it with AudioPolicy.createAudioTrackSource().
    private const val ROUTE_FLAG_LOOP_BACK = 0x1 shl 1
    
    @Volatile private var track: AudioTrack? = null
    @Volatile private var trackRate = 48000
    @Volatile private var trackChannels = 2
    @Volatile private var flushGen = 0
    private var policy: Any? = null
    private var audioManager: AudioManager? = null

    private fun log(msg: String) {
        try { File(LOG).appendText("${System.currentTimeMillis()} $msg\n") } catch (_: Throwable) {}
    }

    @JvmStatic
    fun main(args: Array<String>) {
        try { File(LOG).writeText("") } catch (_: Throwable) {}
        if (args.size < 3) {
            log("usage: port token uids")
            exitProcess(2)
        }
        val port = args[0].toInt()
        val token = args[1]
        val uids = args[2].split(",").mapNotNull { it.trim().toIntOrNull() }
        log("start port=$port uids=$uids")

        var setupError: String? = null
        try {
            try { Looper.prepareMainLooper() } catch (_: Throwable) {}
            val ctx = fakeShellContext()
            setupPolicy(ctx, uids)
        } catch (t: Throwable) {
            setupError = rootCause(t)
            log("setup failed: ${t.stackTraceToString()}")
        }

        val server = try {
            ServerSocket(port, 1, InetAddress.getByName("127.0.0.1"))
        } catch (t: Throwable) {
            log("bind failed: $t")
            exitProcess(3)
        }
        Thread { serve(server, token, setupError) }.apply { isDaemon = false; name = "cable-server" }.start()
        // Keep the main thread alive (the audio policy delivers callbacks on it).
        try { Looper.loop() } catch (_: Throwable) {}
    }

    private fun rootCause(t: Throwable): String {
        var c: Throwable = t
        while (c.cause != null && c.cause !== c) c = c.cause!!
        return "${c.javaClass.simpleName}: ${c.message}"
    }

    // ── Context that looks like the shell app ─────────────────────────────

    private class ShellContext(base: Context) : ContextWrapper(base) {
        override fun getPackageName(): String = "com.android.shell"
        @Suppress("unused")
        override fun getOpPackageName(): String = "com.android.shell"
        override fun getApplicationContext(): Context = this
    }

    private fun fakeShellContext(): Context {
        val atClass = Class.forName("android.app.ActivityThread")
        var thread: Any? = null
        try {
            val ctor = atClass.getDeclaredConstructor()
            ctor.isAccessible = true
            thread = ctor.newInstance()
            val cur = atClass.getDeclaredField("sCurrentActivityThread")
            cur.isAccessible = true
            cur.set(null, thread)
            val sys = atClass.getDeclaredField("mSystemThread")
            sys.isAccessible = true
            sys.setBoolean(thread, true)
        } catch (t: Throwable) {
            log("private ActivityThread failed ($t), trying systemMain")
            thread = atClass.getMethod("systemMain").invoke(null)
        }
        val sysCtx = atClass.getMethod("getSystemContext").invoke(thread) as Context
        return ShellContext(sysCtx)
    }

    // ── Audio policy ──────────────────────────────────────────────────────

    private fun setupPolicy(ctx: Context, uids: List<Int>) {
        if (uids.isEmpty()) throw IllegalStateException("no call-app uids given")
        val am = try {
            AudioManager::class.java.getConstructor(Context::class.java).newInstance(ctx)
        } catch (t: Throwable) {
            ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        }
        audioManager = am

        // Each strategy is a RECORDER mix (capture-preset rule) optionally narrowed
        // to the call apps' uids. A uid rule alone would make a PLAYERS mix.
        val strategies = listOf(
            "presets+uid" to (listOf(7, 1, 6, 9, 5) to true),
            "voiceComm+uid" to (listOf(7) to true),
            "voiceComm" to (listOf(7) to false),
        )
        val errors = ArrayList<String>()
        for ((name, spec) in strategies) {
            try {
                val mix = buildMix(spec.first, if (spec.second) uids else emptyList())
                val pol = buildPolicy(ctx, mix)
                val rc = AudioManager::class.java
                    .getMethod("registerAudioPolicy", Class.forName("android.media.audiopolicy.AudioPolicy"))
                    .invoke(am, pol) as Int
                if (rc != 0) throw IllegalStateException("registerAudioPolicy returned $rc")
                policy = pol
                val t = Class.forName("android.media.audiopolicy.AudioPolicy")
                    .getMethod("createAudioTrackSource", Class.forName("android.media.audiopolicy.AudioMix"))
                    .invoke(pol, mix) as AudioTrack
                track = t
                trackRate = t.sampleRate
                trackChannels = t.channelCount
                t.play()
                log("cable ready via $name: ${trackRate} Hz x$trackChannels")
                return
            } catch (t: Throwable) {
                errors.add("$name: ${rootCause(t)}")
                log("strategy $name failed: ${t.stackTraceToString()}")
                try { releasePolicy() } catch (_: Throwable) {}
            }
        }
        throw IllegalStateException(errors.joinToString(" | "))
    }

    private fun buildMix(presets: List<Int>, uids: List<Int>): Any {
        val ruleBuilderClass = Class.forName("android.media.audiopolicy.AudioMixingRule\$Builder")
        val rb = ruleBuilderClass.getConstructor().newInstance()
        val addMixRule = ruleBuilderClass.getMethod("addMixRule", Int::class.javaPrimitiveType, Any::class.java)
        val setPreset = AudioAttributes.Builder::class.java.getMethod("setCapturePreset", Int::class.javaPrimitiveType)
        for (p in presets) {
            val ab = AudioAttributes.Builder()
            setPreset.invoke(ab, p)
            addMixRule.invoke(rb, RULE_MATCH_CAPTURE_PRESET, ab.build())
        }
        for (uid in uids) addMixRule.invoke(rb, RULE_MATCH_UID, Integer.valueOf(uid))
        val rule = ruleBuilderClass.getMethod("build").invoke(rb)

        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(48000)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
            .build()

        val mixBuilderClass = Class.forName("android.media.audiopolicy.AudioMix\$Builder")
        val mb = mixBuilderClass.getConstructor(Class.forName("android.media.audiopolicy.AudioMixingRule")).newInstance(rule)
        mixBuilderClass.getMethod("setFormat", AudioFormat::class.java).invoke(mb, format)
        mixBuilderClass.getMethod("setRouteFlags", Int::class.javaPrimitiveType).invoke(mb, ROUTE_FLAG_LOOP_BACK)
        return mixBuilderClass.getMethod("build").invoke(mb)!!
    }

    private fun buildPolicy(ctx: Context, mix: Any): Any {
        val pbClass = Class.forName("android.media.audiopolicy.AudioPolicy\$Builder")
        val pb = pbClass.getConstructor(Context::class.java).newInstance(ctx)
        pbClass.getMethod("addMix", Class.forName("android.media.audiopolicy.AudioMix")).invoke(pb, mix)
        try {
            pbClass.getMethod("setLooper", Looper::class.java).invoke(pb, Looper.getMainLooper())
        } catch (_: Throwable) {}
        return pbClass.getMethod("build").invoke(pb)!!
    }

    private fun releasePolicy() {
        try { track?.stop() } catch (_: Throwable) {}
        try { track?.release() } catch (_: Throwable) {}
        track = null
        val pol = policy
        val am = audioManager
        if (pol != null && am != null) {
            try {
                AudioManager::class.java
                    .getMethod("unregisterAudioPolicy", Class.forName("android.media.audiopolicy.AudioPolicy"))
                    .invoke(am, pol)
            } catch (_: Throwable) {}
        }
        policy = null
    }

    // ── Server ────────────────────────────────────────────────────────────

    private fun serve(server: ServerSocket, token: String, setupError: String?) {
        log("listening")
        // If nobody connects for a while, don't leave a stray process behind.
        server.soTimeout = 60_000
        while (true) {
            val s: Socket = try { server.accept() } catch (t: Throwable) {
                log("no client: $t")
                shutdown()
                return
            }
            try {
                handle(s, token, setupError)
            } catch (t: Throwable) {
                log("client error: $t")
            } finally {
                try { s.close() } catch (_: Throwable) {}
            }
            // One session per process: when the app disconnects, release the cable.
            shutdown()
            return
        }
    }

    private fun handle(s: Socket, token: String, setupError: String?) {
        s.tcpNoDelay = true
        val input = DataInputStream(BufferedInputStream(s.getInputStream(), 1 shl 16))
        val out = s.getOutputStream()
        val hello = readLine(input)
        if (hello != "HELLO $token") {
            out.write("ERR bad token\n".toByteArray()); out.flush()
            return
        }
        if (setupError != null || track == null) {
            out.write("ERR ${setupError ?: "cable not ready"}\n".replace('\n', ' ').plus("\n").toByteArray()); out.flush()
            return
        }
        out.write("OK $trackRate $trackChannels\n".toByteArray()); out.flush()
        s.soTimeout = 0

        while (true) {
            val type = input.read()
            if (type < 0) return
            val len = input.readInt()
            if (len < 0 || len > (1 shl 24)) return
            val payload = ByteArray(len)
            input.readFully(payload)
            when (type.toChar()) {
                'P' -> play(payload)
                'F' -> flush()
                'Q' -> return
            }
        }
    }

    private fun readLine(i: DataInputStream): String {
        val sb = StringBuilder()
        while (sb.length < 256) {
            val b = i.read()
            if (b < 0 || b == '\n'.code) break
            sb.append(b.toChar())
        }
        return sb.toString().trim()
    }

    private fun flush() {
        flushGen++
        val t = track ?: return
        try { t.pause(); t.flush(); t.play() } catch (_: Throwable) {}
    }

    /** [payload] = 4-byte big-endian sample rate + PCM16 LE mono. Resampled to the cable format. */
    private fun play(payload: ByteArray) {
        val t = track ?: return
        if (payload.size < 6) return
        val srcRate = ((payload[0].toInt() and 0xff) shl 24) or ((payload[1].toInt() and 0xff) shl 16) or
            ((payload[2].toInt() and 0xff) shl 8) or (payload[3].toInt() and 0xff)
        if (srcRate < 4000 || srcRate > 192000) return
        val n = (payload.size - 4) / 2
        val src = ShortArray(n)
        for (i in 0 until n) {
            src[i] = ((payload[4 + 2 * i].toInt() and 0xff) or (payload[5 + 2 * i].toInt() shl 8)).toShort()
        }
        val ch = trackChannels
        val dstRate = trackRate
        val outFrames = (n.toLong() * dstRate / srcRate).toInt()
        val dst = ShortArray(outFrames * ch)
        val ratio = srcRate.toDouble() / dstRate
        for (i in 0 until outFrames) {
            val pos = i * ratio
            val i0 = pos.toInt()
            val i1 = if (i0 + 1 < n) i0 + 1 else i0
            val frac = pos - i0
            val v = (src[i0] * (1 - frac) + src[i1] * frac).toInt().toShort()
            for (c in 0 until ch) dst[i * ch + c] = v
        }
        val gen = flushGen
        var off = 0
        while (off < dst.size && gen == flushGen) {
            val chunk = minOf(4096, dst.size - off)
            val w = t.write(dst, off, chunk)
            if (w <= 0) break
            off += w
        }
    }

    private fun shutdown() {
        log("shutdown")
        releasePolicy()
        exitProcess(0)
    }
}
