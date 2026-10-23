package com.orailnoor.privateagent

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import java.io.File
import java.io.FileOutputStream
import com.k2fsa.sherpa.onnx.OfflineTts
import com.k2fsa.sherpa.onnx.OfflineTtsConfig
import com.k2fsa.sherpa.onnx.OfflineTtsKokoroModelConfig
import com.k2fsa.sherpa.onnx.OfflineTtsModelConfig
import com.k2fsa.sherpa.onnx.OfflineTtsVitsModelConfig

/**
 * Fully local, fully built-in text-to-speech: no Piper-style HTTP server,
 * no network call at speak time. Two independent voices are supported:
 *
 *  - "hindi": a small Hindi (hi_IN) neural voice bundled in the APK's
 *    assets, so it's available immediately with nothing to download.
 *  - "natural": a bigger, more expressive multilingual voice
 *    (Kokoro), downloaded once on request by [NaturalVoiceModelManager]
 *    and loaded from the app's private files dir.
 *
 * Both run on-device via sherpa-onnx (ONNX Runtime + the JNI bindings in
 * jniLibs/arm64-v8a); nothing here talks to the network to produce audio.
 */
object LocalTtsEngine {
    private var hindiEngine: OfflineTts? = null
    private var naturalEngine: OfflineTts? = null
    @Volatile private var stopRequested = false
    @Volatile private var track: AudioTrack? = null

    // Kokoro speaker ids: a female Hindi voice and a female US-English voice,
    // picked automatically from the text so the one natural voice still
    // sounds right for either language without extra configuration.
    private const val KOKORO_SID_HINDI = 31 // hf_alpha
    private const val KOKORO_SID_ENGLISH = 3 // af_heart

    /**
     * espeak-ng (used for phonemes) reads its data with normal file APIs, not
     * Android's AssetManager, so the bundled voice must live on disk. Copies
     * assets/tts/hi once into filesDir and returns that directory.
     */
    private fun hindiDir(context: Context): File {
        val dest = File(context.filesDir, "tts-hi-v1")
        val marker = File(dest, ".complete")
        if (marker.exists()) return dest
        dest.deleteRecursively()
        copyAssetDir(context, "tts/hi", dest)
        marker.writeText("ok")
        return dest
    }

    private fun copyAssetDir(context: Context, assetPath: String, dest: File) {
        val children = context.assets.list(assetPath) ?: emptyArray()
        if (children.isEmpty()) {
            dest.parentFile?.mkdirs()
            context.assets.open(assetPath).use { input ->
                FileOutputStream(dest).use { out -> input.copyTo(out, 256 * 1024) }
            }
        } else {
            dest.mkdirs()
            for (c in children) copyAssetDir(context, "$assetPath/$c", File(dest, c))
        }
    }

    @Synchronized
    private fun hindi(context: Context): OfflineTts? {
        hindiEngine?.let { return it }
        return try {
            val dir = hindiDir(context).absolutePath
            val config = OfflineTtsConfig(
                model = OfflineTtsModelConfig(
                    vits = OfflineTtsVitsModelConfig(
                        model = "$dir/model.onnx",
                        tokens = "$dir/tokens.txt",
                        dataDir = "$dir/espeak-ng-data",
                    ),
                    numThreads = 2,
                    debug = false,
                    provider = "cpu",
                ),
            )
            OfflineTts(config = config).also { hindiEngine = it }
        } catch (e: Throwable) {
            null
        }
    }

    /**
     * Cheap check that the bundled Hindi voice files exist. Deliberately does
     * NOT touch sherpa-onnx / the native library (that only loads lazily on the
     * first real speak, and any failure there is caught, never a crash).
     */
    fun isHindiAssetPresent(context: Context): Boolean {
        return try {
            context.assets.open("tts/hi/model.onnx").use {}
            context.assets.open("tts/hi/tokens.txt").use {}
            true
        } catch (e: Throwable) {
            false
        }
    }

    @Synchronized
    private fun natural(context: Context): OfflineTts? {
        naturalEngine?.let { return it }
        if (!NaturalVoiceModelManager.isReady(context)) return null
        return try {
            val dir = NaturalVoiceModelManager.modelDir(context).absolutePath
            val config = OfflineTtsConfig(
                model = OfflineTtsModelConfig(
                    kokoro = OfflineTtsKokoroModelConfig(
                        model = "$dir/model.int8.onnx",
                        voices = "$dir/voices.bin",
                        tokens = "$dir/tokens.txt",
                        dataDir = "$dir/espeak-ng-data",
                        lexicon = "$dir/lexicon-us-en.txt,$dir/lexicon-zh.txt",
                        lang = "",
                        dictDir = "$dir/dict",
                    ),
                    numThreads = 4,
                    debug = false,
                    provider = "cpu",
                ),
                ruleFsts = "$dir/phone-zh.fst,$dir/date-zh.fst,$dir/number-zh.fst",
            )
            OfflineTts(config = config).also { naturalEngine = it }
        } catch (e: Throwable) {
            null
        }
    }

    private val devanagariRange = '\u0900'..'\u097F'
    private fun looksHindi(text: String): Boolean {
        val letters = text.count { it.isLetter() }
        if (letters == 0) return false
        val hindi = text.count { it in devanagariRange }
        return hindi * 2 >= letters
    }

    /**
     * Synthesizes and plays [text] with [voice] ("hindi" or "natural"),
     * blocking until playback finishes or [stop] is called. Returns true
     * if audio actually played.
     */
    fun speak(context: Context, text: String, voice: String, speed: Float): Boolean {
        val clean = text.trim()
        if (clean.isEmpty()) return false
        stopRequested = false
        val tts = when (voice) {
            "natural" -> natural(context) ?: hindi(context)
            else -> hindi(context)
        } ?: return false
        val sid = if (voice == "natural") {
            if (looksHindi(clean)) KOKORO_SID_HINDI else KOKORO_SID_ENGLISH
        } else {
            0
        }
        val audio = try {
            tts.generate(text = clean, sid = sid, speed = speed.coerceIn(0.5f, 1.8f))
        } catch (e: Throwable) {
            return false
        }
        if (stopRequested || audio.samples.isEmpty()) return false
        return playBlocking(audio.samples, audio.sampleRate)
    }

    private fun playBlocking(samples: FloatArray, sampleRate: Int): Boolean {
        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_FLOAT,
        )
        if (minBuf <= 0) return false
        val bufferSize = maxOf(minBuf, sampleRate) // at least ~1s of headroom
        val newTrack = try {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANT)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setBufferSizeInBytes(bufferSize)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        } catch (e: Throwable) {
            return false
        }
        track = newTrack
        try {
            newTrack.play()
            var offset = 0
            val chunk = 4096
            while (offset < samples.size && !stopRequested) {
                val len = minOf(chunk, samples.size - offset)
                newTrack.write(samples, offset, len, AudioTrack.WRITE_BLOCKING)
                offset += len
            }
            if (!stopRequested) {
                // Let the tail of the buffer actually finish playing.
                val tailMs = (samples.size.toLong() * 1000 / sampleRate) + 150
                var waited = 0L
                while (waited < tailMs && !stopRequested &&
                    newTrack.playState == AudioTrack.PLAYSTATE_PLAYING
                ) {
                    Thread.sleep(50)
                    waited += 50
                }
            }
            return !stopRequested
        } catch (e: Throwable) {
            return false
        } finally {
            try {
                newTrack.stop()
            } catch (_: Exception) {}
            try {
                newTrack.release()
            } catch (_: Exception) {}
            if (track === newTrack) track = null
        }
    }

    fun stop() {
        stopRequested = true
        try {
            track?.pause()
            track?.flush()
        } catch (_: Exception) {}
    }

    fun isHindiReady(context: Context): Boolean = isHindiAssetPresent(context)

    fun isNaturalReady(context: Context): Boolean = NaturalVoiceModelManager.isReady(context)

    /** Frees native resources; call when the app is done with local TTS for now. */
    @Synchronized
    fun release() {
        try { hindiEngine?.free() } catch (_: Exception) {}
        try { naturalEngine?.free() } catch (_: Exception) {}
        hindiEngine = null
        naturalEngine = null
    }
}
