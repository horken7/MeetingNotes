import Foundation
import MeetingCore

/// Which model writes the notes.
enum NotesEngine: String, CaseIterable, Identifiable {
    /// The best Gemma model this iPhone has memory for.
    case automatic = "auto"
    case gemma4b = "gemma3-4b"
    case gemma1b = "gemma3-1b"
    /// Apple Intelligence, on iPhones that have it.
    case apple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .gemma4b: return Catalog.gemma4b.label
        case .gemma1b: return Catalog.gemma1b.label
        case .apple: return "Apple Intelligence"
        }
    }

    static var current: NotesEngine {
        NotesEngine(rawValue: UserDefaults.standard.string(forKey: Keys.notesEngine) ?? "") ?? .automatic
    }

    /// The Gemma model this choice uses, nil for Apple Intelligence.
    var gemma: ModelFile? {
        switch self {
        case .automatic: return Catalog.notesModel(physicalMemory: ProcessInfo.processInfo.physicalMemory, isReady: ModelStore.isReady)
        case .gemma4b: return Catalog.gemma4b
        case .gemma1b: return Catalog.gemma1b
        case .apple: return nil
        }
    }
}

/// Writes the notes on the phone: with Gemma 3 through llama.cpp (any recent iPhone), or optionally with
/// Apple Intelligence. Long transcripts are summarized in parts and then combined.
enum NotesWriter {
    /// Tokens of context for Gemma: about 20 minutes of speech per part, with room for the answer.
    static let contextTokens = 8192
    static let maxAnswerTokens = NotesSampling.maxAnswerTokens

    /// Whether Gemma 3 4B can be loaded now: an 8 GB iPhone, and enough of the app's memory allowance free for
    /// the weights, the context and the compute buffers.
    static var fits4B: Bool {
        Catalog.fits(Catalog.gemma4b, physicalMemory: ProcessInfo.processInfo.physicalMemory)
            && Int64(os_proc_available_memory()) > Catalog.gemma4b.bytes + 1_000_000_000
    }

    /// How much memory iOS lets this app use in all (its current use plus what's still available).
    static var memoryLimit: Int64 { Int64(os_proc_available_memory()) + memoryFootprint() }

    static func write(transcript: String, title: String, language: MeetingLanguage, name: String, instructions: String,
                      engine: NotesEngine, cancel: CancelFlag, report: @escaping Report,
                      onFallback: ((String) -> Void)? = nil) async throws -> String {
        guard let gemma = engine.gemma else {
            return try await AppleNotes.write(transcript: transcript, title: title, language: language, name: name,
                                              instructions: instructions) { report($0, nil) }
        }
        var model = gemma
        if model == Catalog.gemma4b, !fits4B {
            // Loading 4B anyway would get the app stopped by iOS (its GPU memory can't be paged out).
            model = Catalog.gemma1b
            onFallback?("Gemma 3 4B needs more memory than this iPhone has free, so Gemma 3 1B wrote these notes.")
        }
        do {
            return try await local(model, transcript: transcript, title: title, language: language, name: name,
                                   instructions: instructions, cancel: cancel, report: report)
        } catch EngineError.loadFailed where model == Catalog.gemma4b {
            onFallback?("Gemma 3 4B couldn't be loaded, so Gemma 3 1B wrote these notes.")
            return try await local(Catalog.gemma1b, transcript: transcript, title: title, language: language, name: name,
                                   instructions: instructions, cancel: cancel, report: report)
        }
    }

    private static func local(_ model: ModelFile, transcript: String, title: String, language: MeetingLanguage, name: String,
                              instructions: String, cancel: CancelFlag, report: @escaping Report) async throws -> String {
        try await ModelStore.ensure(model, cancel: cancel) { report("Downloading \(model.label)", $0) }
        report("Loading \(model.label)", nil)
        let path = ModelStore.url(model).path
        let engine = try await runBlocking { try LlamaEngine(modelPath: path, contextTokens: contextTokens) }
        var generator = NotesGenerator(maxChars: NotesGenerator.maxChars(contextTokens: contextTokens), generate: { system, prompt in
            try await runBlocking { try engine.generate(system: system, user: prompt, maxTokens: maxAnswerTokens, cancel: cancel) }
        }, progress: { report($0, nil) })
        generator.generatePrefixed = { system, prompt, prefix in
            try await runBlocking { try engine.generate(system: system, user: prompt, prefix: prefix, maxTokens: maxAnswerTokens, cancel: cancel) }
        }
        generator.name = name
        return try await generator.notes(transcript: transcript, title: title, language: language, instructions: instructions)
    }
}
