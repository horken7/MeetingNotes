package com.horken7.meetingnotes.llama

/** Progress of one [LlamaModel.generate] call. */
interface LlamaListener {
    /** [done] of [total] prompt tokens read. */
    fun onPrompt(done: Int, total: Int) {}
    /** More of the reply, as UTF-8 bytes (always whole characters). */
    fun onText(bytes: ByteArray) {}
}

/** A loaded GGUF chat model (llama.cpp, CPU). Not thread safe: use from one thread at a time. */
class LlamaModel private constructor(private var handle: Long) : AutoCloseable {

    val contextSize: Int get() = LlamaLib.nativeContextSize(handle)

    /** Tokens the chat-formatted prompt for these messages takes. */
    fun promptTokens(system: String, user: String): Int = LlamaLib.nativePromptTokens(handle, system, user)

    /**
     * Generates the assistant's reply to [system] + [user]. Returns null when cancelled or decoding failed.
     * @throws IllegalArgumentException when the prompt plus [maxTokens] doesn't fit the context.
     */
    fun generate(system: String, user: String, maxTokens: Int, temperature: Float = 0.3f,
                 listener: LlamaListener = object : LlamaListener {}): String? {
        check(handle != 0L) { "model is closed" }
        return LlamaLib.nativeGenerate(handle, system, user, maxTokens, temperature, listener)
            ?.let { String(it, Charsets.UTF_8) }
    }

    /** Stops a running [generate] from another thread. */
    fun cancel() {
        if (handle != 0L) LlamaLib.nativeCancel(handle)
    }

    override fun close() {
        if (handle != 0L) LlamaLib.nativeFree(handle)
        handle = 0L
    }

    companion object {
        /**
         * Loads a GGUF model that starts at [offset] of the file at [path] (inside the APK, stored uncompressed, or 0
         * for a downloaded file) with a context of [contextTokens], or returns null when it can't be loaded.
         */
        fun load(path: String, offset: Long, contextTokens: Int, threads: Int): LlamaModel? {
            LlamaLib.ensureLoaded()
            val h = LlamaLib.nativeLoad(path, offset, contextTokens, threads)
            return if (h == 0L) null else LlamaModel(h)
        }
    }
}

internal object LlamaLib {
    @Volatile private var loaded = false

    fun ensureLoaded() {
        if (!loaded) synchronized(this) {
            if (!loaded) { System.loadLibrary("llama_jni"); loaded = true }
        }
    }

    external fun nativeLoad(path: String, offset: Long, nCtx: Int, threads: Int): Long
    external fun nativeFree(handle: Long)
    external fun nativeCancel(handle: Long)
    external fun nativeContextSize(handle: Long): Int
    external fun nativePromptTokens(handle: Long, system: String, user: String): Int
    external fun nativeGenerate(
        handle: Long, system: String, user: String, maxTokens: Int, temperature: Float, listener: LlamaListener,
    ): ByteArray?
}
