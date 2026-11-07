import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest

plugins {
    id("com.android.asset-pack")
}

// The default models, delivered with the app at install time (Play Asset Delivery; also merged into the universal APK).
// Play allows up to 1.5 GB per asset pack.
assetPack {
    packName.set("models")
    dynamicDelivery { deliveryType.set("install-time") }
}


val modelCache = rootProject.file("model-cache")
val assetsDir = file("src/main/assets/models")

data class BundledModel(val file: String, val size: Long, val sha256: String, val url: String)

val bundledModels: List<BundledModel> = rootProject.file("bundled-models.txt").readLines()
    .map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }
    .map { it.split(Regex("\\s+")).let { p -> BundledModel(p[0], p[1].toLong(), p[2], p[3]) } }

/** Downloads the bundled models into src/main/assets/models (once; checked by SHA-256) and removes any others. */
val downloadBundledModels by tasks.registering {
    inputs.file(rootProject.file("bundled-models.txt"))
    outputs.dir(assetsDir)
    doLast {
        val dir = assetsDir.apply { mkdirs() }
        val partial = File(modelCache, "partial").apply { mkdirs() }
        dir.listFiles()?.filter { f -> bundledModels.none { it.file == f.name } }?.forEach { it.delete() }
        for (m in bundledModels) {
            val target = File(dir, m.file)
            val verified = File(partial, m.file + ".verified")
            if (target.length() == m.size && verified.exists() && verified.readText() == m.sha256) continue
            val part = File(partial, m.file + ".part")
            if (target.length() != m.size) {
                logger.lifecycle("Downloading ${m.file} (${m.size / 1_000_000} MB)")
                var url = URI(m.url).toURL()
                var conn: HttpURLConnection
                while (true) {
                    conn = url.openConnection() as HttpURLConnection
                    conn.instanceFollowRedirects = false
                    conn.setRequestProperty("User-Agent", "MeetingNotes-build")
                    if (part.length() in 1 until m.size) conn.setRequestProperty("Range", "bytes=${part.length()}-")
                    if (conn.responseCode in 300..399) { url = URI(url.toString()).resolve(conn.getHeaderField("Location")).toURL(); continue }
                    break
                }
                val append = conn.responseCode == 206
                if (conn.responseCode != 200 && !append) throw GradleException("${m.url}: HTTP ${conn.responseCode}")
                conn.inputStream.use { input -> FileOutputStream(part, append).use { input.copyTo(it, 1 shl 20) } }
                part.renameTo(target)
            }
            val digest = MessageDigest.getInstance("SHA-256")
            target.inputStream().use { input ->
                val buf = ByteArray(1 shl 20)
                while (true) { val n = input.read(buf); if (n < 0) break; digest.update(buf, 0, n) }
            }
            val sha = digest.digest().joinToString("") { "%02x".format(it) }
            if (sha != m.sha256 || target.length() != m.size) {
                target.delete()
                throw GradleException("${m.file}: checksum mismatch (got $sha), deleted; run the build again")
            }
            verified.writeText(sha)
        }
    }
}


// Every task that packs the asset pack needs the models first.
tasks.configureEach { if (name != "downloadBundledModels" && !name.startsWith("clean")) dependsOn(downloadBundledModels) }
