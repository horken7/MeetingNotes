import Foundation

/// meta.json, with the same fields and encoding as the Mac app's `Meta` so a meeting folder can move
/// between the two (for example through iCloud Drive).
public struct Meta: Codable, Hashable, Sendable {
    public var title: String
    public var created: Date?
    public var status: String?      // recording, transcribing, summarizing, done, failed
    public var error: String?
    public var app: String?
    public var lang: String?
    public var offsets: [String: Double]?
    public var duration: Double?
    public var audioArchived: Date?

    public init(title: String, created: Date? = nil, status: String? = nil, error: String? = nil, app: String? = nil,
                lang: String? = nil, offsets: [String: Double]? = nil, duration: Double? = nil, audioArchived: Date? = nil) {
        self.title = title
        self.created = created
        self.status = status
        self.error = error
        self.app = app
        self.lang = lang
        self.offsets = offsets
        self.duration = duration
        self.audioArchived = audioArchived
    }
}

public struct Meeting: Identifiable, Hashable, Sendable {
    public let folder: URL
    public var meta: Meta
    public var created: Date
    public var status: String
    public var hasAudio: Bool

    public var id: String { folder.path }
    public var title: String { meta.title }
    public var isBusy: Bool { ["recording", "transcribing", "summarizing"].contains(status) }
}

/// The meeting folders: one folder per meeting with meta.json, transcript.md, notes.md and the audio,
/// the same layout as the Mac app.
public struct MeetingStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static let transcriptFile = "transcript.md"
    public static let notesFile = "notes.md"

    public static func readMeta(_ folder: URL) -> Meta? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(Meta.self, from: data)
    }

    public static func encode(_ meta: Meta) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(meta)
    }

    public static func writeMeta(_ meta: Meta, to folder: URL) {
        if let data = try? encode(meta) {
            try? data.write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
        }
    }

    public static func update(_ folder: URL, _ change: (inout Meta) -> Void) {
        var m = readMeta(folder) ?? Meta(title: folder.lastPathComponent)
        change(&m)
        writeMeta(m, to: folder)
    }

    public func loadAll() -> [Meeting] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        let meetings: [Meeting] = dirs.compactMap { dir in
            guard let meta = Self.readMeta(dir) else { return nil }
            let created = meta.created
                ?? (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                ?? .distantPast
            var status = meta.status ?? ""
            if status.isEmpty {
                status = fm.fileExists(atPath: dir.appendingPathComponent(Self.notesFile).path) ? "done" : "failed"
            }
            return Meeting(folder: dir, meta: meta, created: created, status: status, hasAudio: !Self.audioFiles(dir).isEmpty)
        }
        return meetings.sorted { $0.created > $1.created }
    }

    /// The recording segments, in order: audio.caf, then audio-1.caf, audio-2.caf… when recording was
    /// interrupted (a phone call) and resumed. The Mac app's .caf/.wav tracks count too.
    public static func audioFiles(_ folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["caf", "wav", "m4a"].contains($0.pathExtension.lowercased()) }
            .sorted { segmentNumber($0) < segmentNumber($1) }
    }

    /// 0 for "audio", N for "audio-N".
    public static func segmentNumber(_ url: URL) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
        guard let dash = name.lastIndex(of: "-"), let n = Int(name[name.index(after: dash)...]) else { return 0 }
        return n
    }

    public static func segmentName(_ number: Int) -> String {
        number == 0 ? "audio" : "audio-\(number)"
    }

    public static func folderName(title: String, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        var safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined()
        safe = safe.trimmingCharacters(in: .whitespaces)
        if safe.isEmpty { safe = "Meeting" }
        return "\(f.string(from: date)) \(safe)"
    }

    public func newFolder(title: String, date: Date) throws -> URL {
        let base = Self.folderName(title: title, date: date)
        var url = root.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(base) \(n)")
            n += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A file's text without its first "# Title" line, which the screen already shows.
    public static func readBody(_ folder: URL, _ file: String) -> String {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8) else { return "" }
        return stripTitle(text)
    }

    public static func stripTitle(_ text: String) -> String {
        if text.hasPrefix("# "), let nl = text.firstIndex(of: "\n") {
            return String(text[text.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func writeNotes(_ notes: String, title: String, to folder: URL) throws {
        try "# \(title)\n\n\(notes)\n".write(to: folder.appendingPathComponent(notesFile), atomically: true, encoding: .utf8)
    }

    public static func writeTranscript(_ transcript: String, title: String, to folder: URL) throws {
        try "# \(title): transcript\n\n\(transcript)\n".write(to: folder.appendingPathComponent(transcriptFile), atomically: true, encoding: .utf8)
    }

    /// Renames the meeting: meta.json and the "# Title" headings of the notes and transcript.
    public static func rename(_ folder: URL, to title: String) {
        update(folder) { $0.title = title }
        let notes = readBody(folder, notesFile)
        if !notes.isEmpty { try? writeNotes(notes, title: title, to: folder) }
        let transcript = readBody(folder, transcriptFile)
        if !transcript.isEmpty { try? writeTranscript(transcript, title: title, to: folder) }
    }
}

public func formatDuration(_ seconds: Double) -> String {
    let t = max(0, Int(seconds))
    if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) }
    return String(format: "%d:%02d", t / 60, t % 60)
}

/// A meeting's length for lists: "45 s", "21 min", "1 h 5 min".
public func formatLength(_ seconds: Double) -> String {
    let t = max(0, Int(seconds.rounded()))
    if t < 60 { return "\(t) s" }
    let m = (t + 30) / 60
    if m < 60 { return "\(m) min" }
    return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
}

/// Case- and accent-insensitive match of every word of the query.
public func matches(_ query: String, in texts: [String]) -> Bool {
    let words = query.split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty else { return true }
    return words.allSatisfy { w in
        texts.contains { $0.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
