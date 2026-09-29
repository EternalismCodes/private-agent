package com.orailnoor.privateagent

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream

/**
 * Downloads and unpacks the optional "natural voice" model — a bigger,
 * more expressive local neural TTS voice (Kokoro, multilingual) — the
 * first time the user turns it on in Agent preferences. Everything still
 * runs fully on-device afterwards; this is a one-time ~130MB fetch, not a
 * server the phone talks to at speak time.
 *
 * Kept entirely separate from the built-in Hindi voice (bundled in the
 * APK's assets, always present, no download): this one lives in the app's
 * private files dir so the base install stays small and the download is
 * genuinely optional.
 */
object NaturalVoiceModelManager {
    private const val MODEL_URL =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2"
    private const val MODEL_DIR_NAME = "natural-voice-kokoro-v1"

    fun modelDir(context: Context): File = File(context.filesDir, MODEL_DIR_NAME)

    fun isReady(context: Context): Boolean {
        val dir = modelDir(context)
        return File(dir, "model.int8.onnx").exists() &&
            File(dir, "voices.bin").exists() &&
            File(dir, "tokens.txt").exists() &&
            File(dir, "espeak-ng-data").exists()
    }

    /** Removes the downloaded voice to free space; the built-in Hindi voice is unaffected. */
    fun deleteModel(context: Context) {
        modelDir(context).deleteRecursively()
    }

    /** Blocking — call from a background thread. [onProgress] gets 0..100, or -1 if size is unknown. */
    fun ensureModel(context: Context, onProgress: (Int) -> Unit): Boolean {
        if (isReady(context)) return true
        val dir = modelDir(context)
        dir.deleteRecursively()
        val archive = File(context.cacheDir, "natural-voice.tar.bz2")
        try {
            val conn = URL(MODEL_URL).openConnection() as HttpURLConnection
            conn.instanceFollowRedirects = true
            conn.connect()
            val total = conn.contentLength
            conn.inputStream.use { input ->
                FileOutputStream(archive).use { out ->
                    val buf = ByteArray(256 * 1024)
                    var read: Int
                    var downloaded = 0L
                    while (input.read(buf).also { read = it } != -1) {
                        out.write(buf, 0, read)
                        downloaded += read
                        // Extraction afterwards is quick, so the download is ~all of the progress bar.
                        onProgress(if (total > 0) ((downloaded * 95) / total).toInt() else -1)
                    }
                }
            }
            extractTarBz2(archive, dir)
            archive.delete()
            onProgress(100)
            val ok = isReady(context)
            if (!ok) dir.deleteRecursively()
            return ok
        } catch (e: Exception) {
            archive.delete()
            dir.deleteRecursively()
            return false
        }
    }

    /**
     * The release asset is a tar.bz2 with everything nested one directory
     * deep (e.g. "kokoro-int8-multi-lang-v1_0/model.int8.onnx"); this
     * flattens that first path segment away so [modelDir] holds the files
     * directly.
     */
    private fun extractTarBz2(archive: File, destDir: File) {
        destDir.mkdirs()
        BZip2CompressorInputStream(archive.inputStream().buffered()).use { bz ->
            TarArchiveInputStream(bz).use { tar ->
                var entry = tar.nextEntry
                while (entry != null) {
                    val relative = entry.name.substringAfter('/', missingDelimiterValue = "")
                    if (relative.isNotEmpty()) {
                        val outFile = File(destDir, relative)
                        if (entry.isDirectory) {
                            outFile.mkdirs()
                        } else {
                            outFile.parentFile?.mkdirs()
                            FileOutputStream(outFile).use { fos ->
                                val buf = ByteArray(256 * 1024)
                                var read: Int
                                while (tar.read(buf).also { read = it } != -1) fos.write(buf, 0, read)
                            }
                        }
                    }
                    entry = tar.nextEntry
                }
            }
        }
    }
}
