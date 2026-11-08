import Foundation

/// A model file the app downloads once from Hugging Face (all public, no account needed).
public struct ModelFile: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let detail: String
    public let url: URL
    public let fileName: String
    public let bytes: Int64

    public init(id: String, label: String, detail: String, url: String, fileName: String, bytes: Int64) {
        self.id = id
        self.label = label
        self.detail = detail
        self.url = URL(string: url)!
        self.fileName = fileName
        self.bytes = bytes
    }
}

public enum Catalog {
    static let whisper = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"

    // MARK: Built into the app (about 1 GB): works offline right after install, in every language.

    /// Silero voice activity detection: skips silence, which stops Whisper inventing phrases.
    public static let vad = ModelFile(
        id: "silero-vad", label: "Voice detection (Silero)", detail: "Skips silence.",
        url: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin",
        fileName: "ggml-silero-v5.1.2.bin", bytes: 885_098)
    /// OpenAI's multilingual Whisper small: the built-in speech model for every language, and language detection.
    public static let whisperSmall = ModelFile(
        id: "whisper-small", label: "Whisper small",
        detail: "Built-in speech recognition for Swedish, Danish and English.",
        url: whisper + "ggml-small-q5_1.bin", fileName: "ggml-small-q5_1.bin", bytes: 190_085_487)
    public static let gemma1b = ModelFile(
        id: "gemma3-1b", label: "Gemma 3 1B",
        detail: "Built-in notes model. Quick, with simpler notes.",
        url: "https://huggingface.co/ggml-org/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf",
        fileName: "gemma-3-1b-it-Q4_K_M.gguf", bytes: 806_058_240)

    // MARK: Optional downloads

    /// KBLab's Swedish fine-tune of Whisper (trained on 50,000 hours of Swedish): far fewer mistakes in Swedish.
    public static let kbWhisperMedium = ModelFile(
        id: "kb-whisper-medium", label: "KB-Whisper medium (Swedish)",
        detail: "KBLab's Swedish Whisper: much better Swedish transcripts.",
        url: "https://huggingface.co/KBLab/kb-whisper-medium/resolve/main/ggml-model-q5_0.bin",
        fileName: "kb-whisper-medium-q5_0.bin", bytes: 539_212_484)
    public static let kbWhisperLarge = ModelFile(
        id: "kb-whisper-large", label: "KB-Whisper large (Swedish)",
        detail: "The most accurate Swedish, about twice as slow as medium.",
        url: "https://huggingface.co/KBLab/kb-whisper-large/resolve/main/ggml-model-q5_0.bin",
        fileName: "kb-whisper-large-q5_0.bin", bytes: 1_081_140_203)
    public static let whisperTurbo = ModelFile(
        id: "whisper-turbo", label: "Whisper large-v3-turbo",
        detail: "More accurate English and Danish transcripts.",
        url: whisper + "ggml-large-v3-turbo-q5_0.bin", fileName: "ggml-large-v3-turbo-q5_0.bin", bytes: 574_041_195)
    public static let gemma4b = ModelFile(
        id: "gemma3-4b", label: "Gemma 3 4B",
        detail: "Much better notes, especially in Swedish and Danish. Needs an iPhone with 8 GB of memory (iPhone 15 Pro or newer).",
        url: "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf",
        fileName: "gemma-3-4b-it-Q4_K_M.gguf", bytes: 2_489_757_856)

    public static let builtIn = [vad, whisperSmall, gemma1b]
    public static let optional = [kbWhisperMedium, kbWhisperLarge, whisperTurbo, gemma4b]
    public static let all = builtIn + optional

    public static func byID(_ id: String?) -> ModelFile? { all.first { $0.id == id } }

    /// The speech models for a language, best first. The built-in Whisper small is always last.
    public static func speechModels(for language: MeetingLanguage) -> [ModelFile] {
        switch language {
        case .swedish: return [kbWhisperLarge, kbWhisperMedium, whisperSmall]
        case .english, .danish: return [whisperTurbo, whisperSmall]
        case .automatic: return [whisperSmall]
        }
    }

    /// The best speech model for a language among those on the phone.
    public static func speechModel(for language: MeetingLanguage, isReady: (ModelFile) -> Bool) -> ModelFile {
        speechModels(for: language).first(where: isReady) ?? whisperSmall
    }

    /// The download to suggest for a language (much better than the built-in model), if any.
    public static func recommendedDownload(for language: MeetingLanguage) -> ModelFile? {
        switch language {
        case .swedish: return kbWhisperMedium
        case .english, .danish: return whisperTurbo
        case .automatic: return nil
        }
    }

    /// The 4B notes model needs an iPhone with 8 GB of memory: on 6 GB iPhones its GPU memory (which iOS
    /// can't page out) uses up the phone and iOS stops the app (tested on an iPhone 13 Pro Max).
    public static let gemma4bPhysicalMemory: UInt64 = 7_500_000_000

    /// Whether a model can run on a phone with `physicalMemory` bytes of memory.
    public static func fits(_ m: ModelFile, physicalMemory: UInt64) -> Bool {
        m != gemma4b || physicalMemory >= gemma4bPhysicalMemory
    }

    /// The best notes model on the phone that fits its memory.
    public static func notesModel(physicalMemory: UInt64, isReady: (ModelFile) -> Bool) -> ModelFile {
        fits(gemma4b, physicalMemory: physicalMemory) && isReady(gemma4b) ? gemma4b : gemma1b
    }

    /// "190 MB", "2.5 GB".
    public static func size(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB", Double(bytes) / 1e9) }
        return "\((bytes + 500_000) / 1_000_000) MB"
    }
}

/// Splits long audio into blocks of about `target` samples, cutting at the quietest moment within `window`
/// samples before each ideal cut, so no word is cut in half. Same as the Android app.
public enum AudioBlocks {
    public static func plan(total: Int, target: Int, window: Int, step: Int = 1600,
                            energy: (_ start: Int, _ length: Int) -> Double) -> [Range<Int>] {
        precondition(target > window && window >= step)
        var blocks: [Range<Int>] = []
        var start = 0
        while total - start > target + window / 2 {
            let ideal = start + target
            var best = ideal
            var bestEnergy = Double.greatestFiniteMagnitude
            var at = ideal - window
            while at + step <= ideal {
                let e = energy(at, step)
                if e < bestEnergy { bestEnergy = e; best = at + step / 2 }
                at += step
            }
            blocks.append(start..<best)
            start = best
        }
        if total > start { blocks.append(start..<total) }
        return blocks
    }
}
