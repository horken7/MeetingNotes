package com.horken7.meetingnotes.core

/**
 * A model file: built into the app ([bundled]: the install-time asset pack, from ../bundled-models.txt) or an optional
 * download from Hugging Face (all public, no account needed). Bundled models are downloaded too in builds made without them.
 */
data class ModelFile(
    val id: String,
    val label: String,
    val description: String,
    val url: String,
    val fileName: String,
    val bytes: Long,
    val bundled: Boolean = false,
    /** Total phone memory needed to load it comfortably, for the notes models. */
    val minRamBytes: Long = 0,
)

object Catalog {
    private const val GB = 1_000_000_000L

    // Speech: Whisper large-v3-turbo is built in and handles every language (and detects it). KBLab's KB-Whisper small
    // (trained on 50,000 hours of Swedish; better on Swedish than OpenAI's whisper-large-v3, and about 4 times faster
    // than turbo) is an optional download that's used for Swedish once it's on the phone.
    val whisperSwedish = ModelFile("kb-whisper-small", "KB-Whisper small for Swedish",
        "From the National Library of Sweden: far fewer mistakes in Swedish than the built-in model, and about 4 times faster.",
        "https://huggingface.co/KBLab/kb-whisper-small/resolve/main/ggml-model-q5_0.bin",
        "ggml-kb-whisper-small-q5_0.bin", 175_209_680)
    val whisperMultilingual = ModelFile("whisper-turbo", "Whisper large-v3-turbo (OpenAI)",
        "All languages, and detecting the language.",
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",
        "ggml-large-v3-turbo-q5_0.bin", 574_041_195, bundled = true)

    /** Optional download: about 4 times faster than large-v3-turbo on a phone, with more mistakes. */
    val whisperFast = ModelFile("whisper-small", "Whisper small (OpenAI)",
        "About 4 times faster for languages other than Swedish, with more mistakes.",
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin",
        "ggml-small-q5_1.bin", 190_085_487)

    /** Silero voice activity detection: skips silence, which stops whisper inventing phrases. */
    val vad = ModelFile("silero-vad", "Silero VAD", "Skips silence.",
        "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin", "ggml-silero-v5.1.2.bin",
        885_098, bundled = true)

    /** The speech models the app needs, all built in. */
    val speechModels = listOf(whisperMultilingual, vad)

    // Notes: Gemma 3 in GGUF from ggml-org, which (unlike Google's own LiteRT/Kaggle copies) needs no login.
    // 1B is built in, so notes work offline from the first meeting; 4B (2.5 GB) doesn't fit in an asset pack (Play's
    // limit is 1.5 GB) or a GitHub release file (2 GB) and is an optional download for phones with 8 GB of memory.
    val gemma1b = ModelFile("gemma3-1b", "Gemma 3 1B (built in)",
        "Works on most phones. Notes are simpler and it follows the format less reliably.",
        "https://huggingface.co/ggml-org/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf",
        "gemma-3-1b-it-Q4_K_M.gguf", 806_058_240, bundled = true, minRamBytes = 3 * GB)
    val gemma4b = ModelFile("gemma3-4b", "Gemma 3 4B (download)",
        "Much better notes, especially in Swedish and Danish. Needs a phone with 8 GB of memory.",
        "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf",
        "gemma-3-4b-it-Q4_K_M.gguf", 2_489_757_856, minRamBytes = 7 * GB)
    val notesModels = listOf(gemma1b, gemma4b)

    val all = speechModels + notesModels + whisperSwedish + whisperFast

    fun byId(id: String?): ModelFile? = all.firstOrNull { it.id == id }

    /**
     * The speech model for a language: KB-Whisper for Swedish when it's downloaded ([swedish]); Whisper small when the
     * user chose speed and has it ([fast]); otherwise the built-in Whisper large-v3-turbo.
     */
    fun speechModel(language: String, swedish: Boolean = false, fast: Boolean = false): ModelFile = when {
        language == "sv" && swedish -> whisperSwedish
        fast -> whisperFast
        else -> whisperMultilingual
    }

    /** A better optional model for meetings in [language], if there is one: KB-Whisper for Swedish. */
    fun betterSpeechModel(language: String): ModelFile? = if (language == "sv") whisperSwedish else null

    /** The notes model the user chose: the built-in 1B unless they picked 4B. Null when the phone has too little memory. */
    fun notesModel(choice: String?, totalRamBytes: Long): ModelFile? = when {
        choice == gemma4b.id -> gemma4b
        totalRamBytes >= gemma1b.minRamBytes -> gemma1b
        else -> null
    }

    /** "190 MB", "2.5 GB". */
    fun size(bytes: Long): String =
        if (bytes >= GB) String.format(java.util.Locale.ROOT, "%.1f GB", bytes / GB.toDouble())
        else "${(bytes + 500_000) / 1_000_000} MB"
}

/**
 * Picks the language of a recording from whisper's guesses on a few loud stretches (silence at the start can
 * mislead a single guess): the language with the highest summed probability.
 */
object LanguageVote {
    fun pick(guesses: List<Pair<String, Float>>): String? =
        guesses.groupBy({ it.first }, { it.second }).maxByOrNull { (_, p) -> p.sum() }?.key
}
