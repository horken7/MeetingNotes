plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

import java.util.zip.ZipFile

// The default models go in the install-time asset pack :models (see ../bundled-models.txt), so the app works offline
// right after install, from Google Play (Play Asset Delivery) and in the universal APK for GitHub releases.
// -PnoBundledModels leaves them out: a small build that downloads them on first use, for quick debug builds.
val bundleModels = !project.hasProperty("noBundledModels")

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
        // Google Play requires apps to target Android 16 (API 36) from August 2026.
        targetSdk = 36
        versionCode = (System.getenv("VERSION_CODE") ?: "1").toInt()
        // CI sets these from the tag and the commit count; local builds use the repository's version.txt.
        versionName = System.getenv("VERSION_NAME") ?: rootProject.file("../version.txt").readText().trim()
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
    if (bundleModels) assetPacks += listOf(":models")
    testOptions { unitTests.isReturnDefaultValues = true }
}

kotlin { jvmToolchain(17) }

// The universal APK for GitHub releases: built from the app bundle by bundletool, so it contains the asset pack too.
val bundletool by configurations.creating
dependencies { bundletool("com.android.tools.build:bundletool:1.18.1") }

/** Arguments for bundletool build-apks: the release bundle, signed like the app. */
fun bundletoolArgs(mode: String, output: File): List<String> {
    val sc = android.signingConfigs.findByName("release") ?: android.signingConfigs.getByName("debug")
    return listOf("build-apks", "--mode=$mode", "--overwrite",
        "--bundle=${layout.buildDirectory.file("outputs/bundle/release/app-release.aab").get().asFile}",
        "--output=$output",
        "--ks=${sc.storeFile}", "--ks-pass=pass:${sc.storePassword}",
        "--ks-key-alias=${sc.keyAlias}", "--key-pass=pass:${sc.keyPassword}",
        // The Maven bundletool has no aapt2 of its own; use the SDK's.
        "--aapt2=${android.sdkDirectory}/build-tools/${android.buildToolsVersion}/aapt2")
}

val universalApk by tasks.registering(JavaExec::class) {
    description = "Builds build/outputs/universal/MeetingNotes.apk from the release app bundle, with the models inside."
    dependsOn("bundleRelease")
    val aab = layout.buildDirectory.file("outputs/bundle/release/app-release.aab")
    val apks = layout.buildDirectory.file("outputs/universal/MeetingNotes.apks")
    val apk = layout.buildDirectory.file("outputs/universal/MeetingNotes.apk")
    classpath = bundletool
    mainClass.set("com.android.tools.build.bundletool.BundleToolMain")
    doFirst { args(bundletoolArgs("universal", apks.get().asFile)) }
    doLast {
        ZipFile(apks.get().asFile).use { zip ->
            zip.getInputStream(zip.getEntry("universal.apk")).use { input ->
                apk.get().asFile.outputStream().use { input.copyTo(it, 1 shl 20) }
            }
        }
        apks.get().asFile.delete()
        logger.lifecycle("Universal APK: ${apk.get().asFile} (${apk.get().asFile.length()} bytes)")
    }
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


/**
 * Checks what Google Play would install: builds the split APKs from the bundle and fails if the base module is over
 * Play's 200 MB limit, the asset pack over 1.5 GB, or a model isn't stored uncompressed (the app reads them in place).
 */
val checkPlaySplits by tasks.registering(JavaExec::class) {
    dependsOn("bundleRelease")
    val apks = layout.buildDirectory.file("outputs/splits/MeetingNotes.apks")
    classpath = bundletool
    mainClass.set("com.android.tools.build.bundletool.BundleToolMain")
    doFirst { args(bundletoolArgs("default", apks.get().asFile)) }
    doLast {
        ZipFile(apks.get().asFile).use { zip ->
            val sizes = zip.entries().asSequence().filter { it.name.endsWith(".apk") }.associate { it.name to it.size }
            sizes.toSortedMap().forEach { (name, size) -> logger.lifecycle("%-45s %,15d bytes".format(name, size)) }
            val base = sizes.filterKeys { it.startsWith("splits/base") }.values.sum()
            val pack = sizes.filterKeys { it.contains("models") }.values.sum()
            logger.lifecycle("Base module (all splits): %,d bytes; models asset pack: %,d bytes".format(base, pack))
            if (base > 200_000_000) throw GradleException("The base module is over Play's 200 MB limit")
            if (pack > 1_500_000_000) throw GradleException("The models asset pack is over Play's 1.5 GB limit")
            val packEntry = zip.entries().asSequence().first { it.name.contains("models") && it.name.endsWith(".apk") }
            val tmp = File(temporaryDir, "pack.apk")
            zip.getInputStream(packEntry).use { input -> tmp.outputStream().use { input.copyTo(it, 1 shl 20) } }
            ZipFile(tmp).use { pz ->
                val models = pz.entries().asSequence().filter { it.name.startsWith("assets/models/") }.toList()
                models.forEach { logger.lifecycle("  ${it.name}: ${if (it.method == 0) "stored" else "COMPRESSED"}") }
                if (models.isEmpty() || models.any { it.method != 0 }) throw GradleException("The models must be stored uncompressed")
            }
            tmp.delete()
        }
        logger.lifecycle("Split APKs: ${apks.get().asFile}")
    }
}