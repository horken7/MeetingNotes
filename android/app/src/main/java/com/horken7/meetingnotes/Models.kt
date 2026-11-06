package com.horken7.meetingnotes

import android.content.Context
import android.os.Build
import com.horken7.meetingnotes.core.Catalog
import com.horken7.meetingnotes.core.ModelFile
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.UnknownHostException

class UserFacingException(message: String) : Exception(message)

/** Downloaded model files, in the app's private storage. */
object Models {
    lateinit var dir: File
        private set

    fun init(context: Context) {
        dir = File(context.filesDir, "models").apply { mkdirs() }
    }

    fun file(m: ModelFile): File = File(dir, m.fileName)

    fun isReady(m: ModelFile): Boolean = file(m).let { it.exists() && it.length() == m.bytes }

    fun delete(m: ModelFile) {
        file(m).delete()
        File(dir, m.fileName + ".part").delete()
    }

    /** True when the processor has the instructions the native libraries are built for (ARMv8.2 dot product and fp16). */
    val cpuSupported: Boolean by lazy {
        if (!Build.SUPPORTED_ABIS.contains("arm64-v8a")) return@lazy false
        val features = runCatching { File("/proc/cpuinfo").readLines() }.getOrDefault(emptyList())
            .firstOrNull { it.startsWith("Features") }?.substringAfter(':')?.trim()?.split(' ')?.toSet() ?: return@lazy true
        "asimddp" in features && "fphp" in features
    }

    const val cpuMessage = "This phone's processor is too old for on-device transcription (it needs an ARMv8.2 processor, " +
        "found in most phones from 2018 on)."

    /**
     * Downloads [m] unless it's already there, resuming a partial download. [progress] gets bytes done and total.
     * Throws [UserFacingException] with a plain explanation when it fails.
     */
    fun download(m: ModelFile, cancelled: () -> Boolean, progress: (Long, Long) -> Unit) {
        if (isReady(m)) return
        val target = file(m)
        val part = File(dir, m.fileName + ".part")
        if (part.length() > m.bytes) part.delete()
        val free = dir.usableSpace
        if (free < (m.bytes - part.length()) + 200_000_000) {
            throw UserFacingException("There isn't enough free space for ${m.label} (${Catalog.size(m.bytes)}). Free up some space and try again.")
        }
        var attempt = 0
        while (true) {
            try {
                fetch(m, part, cancelled, progress)
                break
            } catch (e: IOException) {
                if (cancelled()) throw e
                if (++attempt >= 4) {
                    val why = if (e is UnknownHostException) "there's no internet connection" else (e.message ?: "the connection failed")
                    throw UserFacingException("Couldn't download ${m.label}: $why. It's needed once; after that everything works offline. Try again on Wi-Fi.")
                }
                Thread.sleep(2000L * attempt)
            }
        }
        if (part.length() != m.bytes) {
            part.delete()
            throw UserFacingException("The download of ${m.label} was incomplete. Try again.")
        }
        if (!part.renameTo(target)) throw UserFacingException("Couldn't save ${m.label}.")
    }

    private fun fetch(m: ModelFile, part: File, cancelled: () -> Boolean, progress: (Long, Long) -> Unit) {
        var done = part.length()
        if (done == m.bytes) return
        var url = URL(m.url)
        var conn: HttpURLConnection
        var redirects = 0
        while (true) {
            conn = (url.openConnection() as HttpURLConnection).apply {
                instanceFollowRedirects = false
                connectTimeout = 20_000
                readTimeout = 30_000
                setRequestProperty("User-Agent", "MeetingNotes-Android")
                if (done > 0) setRequestProperty("Range", "bytes=$done-")
            }
            val code = conn.responseCode
            if (code in 300..399 && redirects++ < 8) {
                url = URL(url, conn.getHeaderField("Location"))
                conn.disconnect()
                continue
            }
            if (code == HttpURLConnection.HTTP_OK && done > 0) { done = 0; part.delete() }   // server ignored Range
            if (code != HttpURLConnection.HTTP_OK && code != HttpURLConnection.HTTP_PARTIAL) {
                conn.disconnect()
                throw IOException("the server answered $code")
            }
            break
        }
        try {
            conn.inputStream.use { input ->
                FileOutputStream(part, done > 0).use { out ->
                    val buf = ByteArray(256 * 1024)
                    var lastReport = 0L
                    while (true) {
                        if (cancelled()) throw IOException("cancelled")
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        done += n
                        if (done - lastReport > 1_000_000) { progress(done, m.bytes); lastReport = done }
                    }
                }
            }
            progress(done, m.bytes)
        } finally {
            conn.disconnect()
        }
    }
}
