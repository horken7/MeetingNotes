package com.horken7.meetingnotes.core

/** A model file the app downloads once from Hugging Face (all public, no account needed). */
data class ModelFile(
    val id: String,
    val label: String,
    val description: String,
    val url: String,
    val fileName: String,
    val bytes: Long,
    /** Total phone memory needed to load it comfortably, for the notes models. */
    val minRamBytes: Long = 0,
)

object Catalog {
    private const val GB = 1_000_000_000L
    private const val WHISPER = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"

    // Speech. Small is the default: base makes many more mistakes in Swedish and Danish, while large-v3-turbo
    // is about 3x slower again on a phone CPU and needs over 1 GB of memory while it runs.
    val whisperBase = ModelFile("whisper-base", "Fast (Whisper base)",
        "Quickest, but makes noticeably more mistakes, especially in Swedish and Danish.",
        WHISPER + "ggml-base-q5_1.bin", "ggml-base-q5_1.bin", 59_707_625)
    val whisperSmall = ModelFile("whisper-small", "Balanced (Whisper small)",
        "Good Swedish, Danish and English at a speed most phones manage. Recommended.",
        WHISPER + "ggml-small-q5_1.bin", "ggml-small-q5_1.bin", 190_085_487)
    val whisperTurbo = ModelFile("whisper-turbo", "Best (Whisper large-v3-turbo)",
        "Most accurate, but several times slower; for recent high-end phones.",
        WHISPER + "ggml-large-v3-turbo-q5_0.bin", "ggml-large-v3-turbo-q5_0.bin", 574_041_195)
    val whisperModels = listOf(whisperBase, whisperSmall, whisperTurbo)

    /** Silero voice activity detection: skips silence, which stops whisper inventing phrases. */
    val vad = ModelFile("silero-vad", "Voice detection (Silero)", "Skips silence.",
        "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin", "ggml-silero-v5.1.2.bin", 885_098)

    // Notes: Gemma 3 in GGUF from ggml-org, which (unlike Google's own LiteRT/Kaggle copies) needs no login.
    val gemma1b = ModelFile("gemma3-1b", "Gemma 3 1B",
        "Small and quick. Notes are simpler and it follows the format less reliably.",
        "https://huggingface.co/ggml-org/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf",
        "gemma-3-1b-it-Q4_K_M.gguf", 806_058_240, minRamBytes = 3 * GB)
    val gemma4b = ModelFile("gemma3-4b", "Gemma 3 4B",
        "Much better notes, especially in Swedish and Danish. Needs a phone with 8 GB of memory.",
        "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf",
        "gemma-3-4b-it-Q4_K_M.gguf", 2_489_757_856, minRamBytes = 7 * GB)
    val notesModels = listOf(gemma1b, gemma4b)

    fun byId(id: String?): ModelFile? = (whisperModels + notesModels + vad).firstOrNull { it.id == id }

    /** The best notes model this phone can run, or null when it has too little memory for any. */
    fun defaultNotesModel(totalRamBytes: Long): ModelFile? =
        notesModels.sortedByDescending { it.minRamBytes }.firstOrNull { totalRamBytes >= it.minRamBytes }

    /** The chosen notes model ("auto" or unknown picks by memory). */
    fun notesModel(choice: String?, totalRamBytes: Long): ModelFile? =
        notesModels.firstOrNull { it.id == choice } ?: defaultNotesModel(totalRamBytes)

    fun whisperModel(choice: String?): ModelFile = whisperModels.firstOrNull { it.id == choice } ?: whisperSmall

    /** "190 MB", "2.5 GB". */
    fun size(bytes: Long): String =
        if (bytes >= GB) String.format(java.util.Locale.ROOT, "%.1f GB", bytes / GB.toDouble())
        else "${(bytes + 500_000) / 1_000_000} MB"
}
