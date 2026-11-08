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

/// Cleans up what a small model writes: repeated bullets, too many bullets, checkboxes outside the action
/// items, and hints copied into headings ("## Viktiga punkter (grouped by topic)").
public enum NotesTidy {
    public static let maxBullets = 6

    public static func tidy(_ notes: String, language: MeetingLanguage) -> String {
        let actionHeadings = Set([MeetingLanguage.swedish, .danish, .english].map { NotesPrompt.headings($0)[2].lowercased() } + ["action items"])
        var out: [String] = []
        var seen = Set<String>()
        var bullets = 0
        var inActions = false
        let summaryHeadings = Set([MeetingLanguage.swedish, .danish, .english].map { NotesPrompt.headings($0)[0].lowercased() })
        var currentTitle = ""
        var summarySentences = 0
        for raw in notes.components(separatedBy: "\n") {
            var line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                // "## Att göra (Checklista)" -> "## Att göra"
                if let open = line.firstIndex(of: "("), line.hasSuffix(")") {
                    line = String(line[..<open]).trimmingCharacters(in: .whitespaces)
                }
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
                inActions = actionHeadings.contains(title)
                currentTitle = title
                seen = []
                bullets = 0
                out.append(line)
                continue
            }
            let isBullet = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
            if isBullet {
                var item = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                var box = ""
                if item.hasPrefix("[ ]") || item.lowercased().hasPrefix("[x]") {
                    box = String(item.prefix(3))
                    item = String(item.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                let key = item.lowercased().filter { $0.isLetter || $0.isNumber }
                guard !key.isEmpty, !seen.contains(key), bullets < maxBullets else { continue }
                seen.insert(key)
                bullets += 1
                let indent = String(raw.prefix { $0 == " " })
                out.append(indent + "- " + (inActions ? (box.isEmpty ? "[ ] " : box + " ") : "") + item)
                continue
            }
            if !trimmed.isEmpty, summaryHeadings.contains(currentTitle) {
                // The summary: no repeated sentences, at most 5.
                var sentences: [String] = []
                trimmed.enumerateSubstrings(in: trimmed.startIndex..., options: .bySentences) { sub, _, _, _ in
                    if let s = sub?.trimmingCharacters(in: .whitespaces), !s.isEmpty { sentences.append(s) }
                }
                var kept: [String] = []
                for sentence in sentences {
                    let key = sentence.lowercased().filter { $0.isLetter || $0.isNumber }
                    if summarySentences < 5, !key.isEmpty, !seen.contains(key) {
                        seen.insert(key)
                        kept.append(sentence)
                        summarySentences += 1
                    }
                }
                if !kept.isEmpty { out.append(kept.joined(separator: " ")) }
                continue
            }
            out.append(line)
        }
        return out.joined(separator: "\n").replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }
}
