plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest

// Models built into the APK (see ../bundled-models.txt). -PnoBundledModels builds without them (the app then downloads
// them on first use), which keeps debug builds small and quick.
val bundleModels = !project.hasProperty("noBundledModels")
val modelCache = rootProject.file("model-cache")

data class BundledModel(val file: String, val size: Long, val sha256: String, val url: String)

val bundledModels: List<BundledModel> = rootProject.file("bundled-models.txt").readLines()
    .map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }
    .map { it.split(Regex("\\s+")).let { p -> BundledModel(p[0], p[1].toLong(), p[2], p[3]) } }

/** Downloads the bundled models into model-cache/assets/models (once; checked by SHA-256) and removes any others. */
val downloadBundledModels by tasks.registering {
    inputs.file(rootProject.file("bundled-models.txt"))
    outputs.dir(File(modelCache, "assets/models"))
    doLast {
        val dir = File(modelCache, "assets/models").apply { mkdirs() }
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

// Release signing: a keystore from the environment (CI secrets) when there is one, otherwise the debug key.
val releaseKeystore = System.getenv("ANDROID_KEYSTORE_PATH")?.let { file(it) }?.takeIf { it.exists() }

android {
    namespace = "com.horken7.meetingnotes"
    compileSdk = 36
    ndkVersion = "27.1.12297006"

    defaultConfig {
        applicationId = "com.horken7.meetingnotes"
        // Android 10: the oldest version with the microphone-silencing callback used to detect phone calls,
        // and in practice the floor for phones with enough memory for on-device speech and language models.
        minSdk = 29
        targetSdk = 35
        versionCode = (System.getenv("VERSION_CODE") ?: "1").toInt()
        versionName = System.getenv("VERSION_NAME") ?: "0.1.0"
        ndk { abiFilters += listOf("arm64-v8a") }
    }

    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD") ?: System.getenv("ANDROID_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // No shrinking: the native code looks up Kotlin classes by name.
            isMinifyEnabled = false
            // -PdebuggableRelease for testing on an emulator (adb run-as) with optimized native code.
            isDebuggable = project.hasProperty("debuggableRelease")
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    packaging {
        jniLibs { useLegacyPackaging = false }
    }
    // Stored uncompressed, so the native code reads the models straight out of the installed APK (no copy).
    androidResources { noCompress += listOf("bin", "gguf") }
    if (bundleModels) sourceSets["main"].assets.srcDir(File(modelCache, "assets").path)
    testOptions { unitTests.isReturnDefaultValues = true }
}

kotlin { jvmToolchain(17) }

if (bundleModels) {
    tasks.named("preBuild") { dependsOn(downloadBundledModels) }
}

dependencies {
    implementation(project(":whisper"))
    implementation(project(":llama"))

    val composeBom = platform("androidx.compose:compose-bom:2025.10.01")
    implementation(composeBom)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")

    testImplementation("junit:junit:4.13.2")
}
