import Foundation

/// A piece of recognized speech, with its start and end in seconds from the start of the meeting.
public struct Segment: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum TranscriptFormatter {
    public static let speaker = "Speaker"

    /// Joins recognized segments into transcript paragraphs in the Mac app's format,
    /// `[m:ss] **Speaker:** text`. There's one microphone, so a new paragraph starts after a pause
    /// or once a paragraph gets long, instead of when the speaker changes.
    public static func format(_ segments: [Segment], pause: Double = 2.0, maxLength: Int = 600) -> String {
        var paragraphs: [(start: Double, text: String)] = []
        var lastEnd = -Double.infinity
        for s in segments.sorted(by: { $0.start < $1.start }) {
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !isNoise(text) else { continue }
            if let last = paragraphs.last, s.start - lastEnd < pause, last.text.count + text.count < maxLength {
                paragraphs[paragraphs.count - 1].text += " " + text
            } else {
                paragraphs.append((s.start, text))
            }
            lastEnd = max(lastEnd, s.end)
        }
        return paragraphs.map { "[\(formatDuration($0.start))] **\(speaker):** \($0.text)" }.joined(separator: "\n\n")
    }

    static func isNoise(_ t: String) -> Bool {
        if t.isEmpty { return true }
        if (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("(") && t.hasSuffix(")")) { return true }
        let filler = CharacterSet.punctuationCharacters.union(.whitespaces).union(.symbols)
        return t.unicodeScalars.allSatisfy { filler.contains($0) }
    }

    /// The plain spoken text of a transcript (no timestamps or speaker labels), e.g. for language detection.
    public static func plainText(_ transcript: String) -> String {
        transcript.split(separator: "\n").map { line -> String in
            var s = Substring(line)
            if s.hasPrefix("["), let close = s.firstIndex(of: "]") { s = s[s.index(after: close)...] }
            s = s.drop(while: { $0 == " " })
            if s.hasPrefix("**"), let end = s.range(of: ":**") { s = s[end.upperBound...] }
            return s.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && !$0.hasPrefix("#") }.joined(separator: " ")
    }
}

/// The meeting languages the app offers. "Automatic" picks among them.
public enum MeetingLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic = "auto", swedish = "sv", danish = "da", english = "en"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .swedish: return "Svenska"
        case .danish: return "Dansk"
        case .english: return "English"
        }
    }

    /// The speech recognition locale.
    public var localeIdentifier: String? {
        switch self {
        case .automatic: return nil
        case .swedish: return "sv-SE"
        case .danish: return "da-DK"
        case .english: return "en-US"
        }
    }

    /// The language's English name, used in the notes prompt.
    public var englishName: String {
        switch self {
        case .automatic: return "the main language spoken in the meeting"
        case .swedish: return "Swedish"
        case .danish: return "Danish"
        case .english: return "English"
        }
    }

    /// The first of the phone's preferred languages that the app supports, else English.
    public static func guess(preferred: [String]) -> MeetingLanguage {
        for id in preferred {
            let code = String(id.prefix(2)).lowercased()
            if let l = MeetingLanguage(rawValue: code), l != .automatic { return l }
        }
        return .english
    }
}
