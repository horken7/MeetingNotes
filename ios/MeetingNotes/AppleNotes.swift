import Foundation
import FoundationModels
import MeetingCore

/// Optional: writes the notes with Apple's on-device Foundation Models (Apple Intelligence). Its context window is
/// small (about 4,000 tokens), so long transcripts are summarized in parts and then combined.
enum AppleNotes {
    static var model: SystemLanguageModel {
        // Meeting transcripts are the user's own content being summarized, which is what this setting is for.
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    /// Why notes can't be written on this iPhone right now, or nil when they can.
    static var unavailableReason: String? {
        switch model.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This iPhone doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings > Apple Intelligence & Siri, then tap Write notes. The transcript is saved."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading its model. Keep the iPhone on Wi-Fi and charging, then tap Write notes. The transcript is saved."
        case .unavailable:
            return "Apple Intelligence isn't available right now. The transcript is saved."
        }
    }

    static func write(transcript: String, title: String, language: MeetingLanguage, name: String, instructions: String,
                      progress: @escaping @Sendable (String) -> Void) async throws -> String {
        if let reason = unavailableReason { throw NotesError.failed(reason) }
        let model = self.model
        if language != .automatic, let id = language.localeIdentifier, !model.supportsLocale(Locale(identifier: id)) {
            throw NotesError.failed("Apple Intelligence can't write notes in \(language.label) yet. The transcript is saved.")
        }
        var generator = NotesGenerator(maxChars: NotesGenerator.maxChars(contextTokens: model.contextSize), generate: { system, prompt in
            let session = LanguageModelSession(model: model, instructions: system)
            do {
                return try await session.respond(to: prompt, options: GenerationOptions(temperature: Double(NotesSampling.temperature),
                                                                                        maximumResponseTokens: NotesSampling.maxAnswerTokens)).content
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .exceededContextWindowSize:
                    throw NotesError.contextExceeded
                case .guardrailViolation, .refusal:
                    throw NotesError.failed("Apple Intelligence declined to summarize this meeting. The transcript is saved.")
                case .unsupportedLanguageOrLocale:
                    throw NotesError.failed("Apple Intelligence doesn't support this meeting's language. The transcript is saved.")
                case .assetsUnavailable:
                    throw NotesError.failed("The Apple Intelligence model isn't ready yet. Try again later. The transcript is saved.")
                default:
                    throw NotesError.failed("Apple Intelligence couldn't write the notes: \(error.localizedDescription)")
                }
            }
        }, progress: progress)
        generator.name = name
        return try await generator.notes(transcript: transcript, title: title,
                                         language: language, instructions: instructions)
    }
}
