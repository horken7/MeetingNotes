package com.horken7.meetingnotes

import android.content.Context
import android.os.Build
import android.system.Os
import com.horken7.meetingnotes.core.Catalog
import com.horken7.meetingnotes.core.ModelFile
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.UnknownHostException

class UserFacingException(message: String) : Exception(message)

/** Where a model's bytes are: [length] bytes from [offset] of [path] (an APK file for built-in models). */
data class ModelSource(val path: String, val offset: Long, val length: Long)

/**
 * The models: built in as uncompressed assets (from the install-time asset pack, which Play installs as a split APK,
 * or inside the universal APK), or downloaded to the app's private storage.
 */
object Models {
    lateinit var dir: File
        private set
    private lateinit var app: Context
    private val bundled = HashMap<String, ModelSource>()

    fun init(context: Context) {
        app = context.applicationContext
        dir = File(context.filesDir, "models").apply { mkdirs() }
        // Built-in models are read in place: the APK file that holds the asset (the base or the asset pack's split
        // APK, found from the open file descriptor) plus the asset's offset in it (it's stored uncompressed).
        for (m in Catalog.all) {
            runCatching { context.assets.openFd("models/${m.fileName}") }.getOrNull()?.use { fd ->
                val apk = runCatching { Os.readlink("/proc/self/fd/${fd.parcelFileDescriptor.fd}") }.getOrNull()
                if (apk != null && fd.length == m.bytes) bundled[m.id] = ModelSource(apk, fd.startOffset, fd.length)
            }
        }
        cleanUp()
    }

    /** Deletes downloads the app no longer uses, e.g. models that are now built in. */
    private fun cleanUp() {
        val keep = Catalog.all.filter { it.id !in bundled }.map { it.fileName }.toSet() +
            Catalog.vad.fileName
        dir.listFiles()?.filter { f -> keep.none { f.name == it || f.name == "$it.part" } }?.forEach { it.delete() }
    }

    fun isBundled(m: ModelFile): Boolean = m.id in bundled

    private fun file(m: ModelFile): File = File(dir, m.fileName)

    fun isReady(m: ModelFile): Boolean = m.id in bundled || file(m).let { it.exists() && it.length() == m.bytes }

    /** Where to load [m] from, or null if it's neither built in nor downloaded. */
    fun source(m: ModelFile): ModelSource? =
        bundled[m.id] ?: file(m).takeIf { it.exists() && it.length() == m.bytes }?.let { ModelSource(it.path, 0, it.length()) }

    /**
     * A plain file path, for whisper.cpp's voice detection model, which can only be opened by path:
     * the built-in copy is extracted once (it's under 1 MB).
     */
    fun path(m: ModelFile): String? {
        val f = file(m)
        if (f.exists() && f.length() == m.bytes) return f.path
        if (m.id !in bundled) return null
        val tmp = File(dir, m.fileName + ".part")
        app.assets.open("models/${m.fileName}").use { input -> FileOutputStream(tmp).use { input.copyTo(it) } }
        return if (tmp.length() == m.bytes && tmp.renameTo(f)) f.path else null
    }

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
     * Downloads [m] unless it's built in or already there, resuming a partial download. [progress] gets bytes done and
     * total. Throws [UserFacingException] with a plain explanation when it fails.
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
                    throw UserFacingException("Couldn't download ${m.label}: $why. Try again on Wi-Fi.")
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
