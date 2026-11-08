import Foundation

/// Rules that keep a small on-device model (Gemma 3 1B or 4B) from making things up.
extension NotesPrompt {
    /// Below this many spoken words there's nothing to summarize, and a small model asked anyway invents a meeting.
    public static let minimumWords = 30

    /// Added to the session instructions of every call (single, part, merge and combine).
    public static func grounding(_ language: MeetingLanguage) -> String {
        """
        Rules:
        - Use only facts stated in the transcript. Never invent names, numbers, dates, decisions or action items.
        - If something is unclear or missing in the transcript, leave it out rather than guess.
        - \(language == .automatic ? "Write in the same language as the transcript (Swedish if the transcript is Swedish)." : "Write in \(language.englishName), the language of the transcript.")
        - Keep it short: at most 5 bullets per heading.
        """
    }

    /// What to write under a heading the transcript says nothing about.
    public static func notMentioned(_ language: MeetingLanguage) -> String {
        switch language {
        case .swedish: return "Inget nämndes"
        case .danish: return "Intet nævnt"
        case .english, .automatic: return "Not mentioned"
        }
    }

    /// The notes saved instead of calling the model when the transcript is (nearly) empty.
    public static func tooLittle(_ language: MeetingLanguage) -> String {
        switch language {
        case .swedish: return "För lite sades i inspelningen för att göra anteckningar."
        case .danish: return "Der blev sagt for lidt i optagelsen til at lave noter."
        case .english, .automatic: return "Too little was said in the recording to summarize."
        }
    }

    /// The number of spoken words, without timestamps and speaker labels.
    public static func wordCount(_ transcript: String) -> Int {
        TranscriptFormatter.plainText(transcript).split(whereSeparator: \.isWhitespace).count
    }
}

/// Sampling for the notes model: nearly greedy, so it sticks to the transcript, with a mild repeat
/// penalty against loops and a cap on the answer.
public enum NotesSampling {
    public static let temperature: Float = 0.2
    public static let topP: Float = 0.9
    public static let topK: Int32 = 40
    public static let repeatPenalty: Float = 1.1
    /// How many recent tokens the repeat penalty looks at.
    public static let repeatLastN: Int32 = 64
    /// Short notes fit easily; a longer answer is usually the model rambling or inventing.
    public static let maxAnswerTokens = 1000
}
