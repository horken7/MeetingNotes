package com.horken7.meetingnotes.whisper

/** One stretch of speech from whisper, times in milliseconds from the start of the samples passed in. */
class WhisperSegment(val startMs: Long, val endMs: Long, textBytes: ByteArray) {
    // Decoded here because whisper can produce broken UTF-8; Kotlin replaces bad bytes instead of crashing.
    val text: String = String(textBytes, Charsets.UTF_8)
}

fun interface WhisperProgress {
    fun onProgress(percent: Int)
}

/** A loaded whisper model. Not thread safe: use from one thread at a time. */
class WhisperModel private constructor(private var handle: Long) : AutoCloseable {

    /**
     * Transcribes 16 kHz mono samples in [-1, 1]. [language] is a whisper code ("sv", "en") or "auto".
     * Text from earlier calls is used as context, so pass consecutive blocks of one recording in order.
     * Returns null when cancelled.
     */
    fun transcribe(
        samples: FloatArray,
        language: String,
        threads: Int,
        vadModelPath: String?,
        prompt: String? = null,
        progress: WhisperProgress = WhisperProgress { },
    ): List<WhisperSegment>? {
        check(handle != 0L) { "model is closed" }
        return WhisperLib.nativeTranscribe(handle, samples, language, threads, vadModelPath, prompt, progress)?.toList()
    }

    /** The language of the last transcription, e.g. "sv". */
    val language: String? get() = if (handle == 0L) null else WhisperLib.nativeLanguage(handle)

    /** Stops a running [transcribe] from another thread. */
    fun cancel() {
        if (handle != 0L) WhisperLib.nativeCancel(handle)
    }

    override fun close() {
        if (handle != 0L) WhisperLib.nativeFree(handle)
        handle = 0L
    }

    companion object {
        /** Loads a ggml whisper model, or returns null if the file isn't a valid model. */
        fun load(path: String): WhisperModel? {
            WhisperLib.ensureLoaded()
            val h = WhisperLib.nativeInit(path)
            return if (h == 0L) null else WhisperModel(h)
        }
    }
}

internal object WhisperLib {
    @Volatile private var loaded = false

    fun ensureLoaded() {
        if (!loaded) synchronized(this) {
            if (!loaded) { System.loadLibrary("whisper_jni"); loaded = true }
        }
    }

    fun systemInfo(): String { ensureLoaded(); return nativeSystemInfo() }

    external fun nativeInit(path: String): Long
    external fun nativeFree(handle: Long)
    external fun nativeCancel(handle: Long)
    external fun nativeTranscribe(
        handle: Long, samples: FloatArray, language: String, threads: Int,
        vadModelPath: String?, prompt: String?, listener: WhisperProgress,
    ): Array<WhisperSegment>?
    external fun nativeLanguage(handle: Long): String?
    external fun nativeSystemInfo(): String
}
