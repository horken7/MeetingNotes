import Foundation

// Meeting Notes MCP server: a read-only stdio server (JSON-RPC 2.0, one message per line) that lets
// Claude Code, Claude Desktop and other MCP clients list, search and read your meetings.
// It only reads meta.json, notes.md and transcript.md; it never writes and never touches audio files.
// Built by install.sh into ~/.meetnotes/bin/meetingnotes-mcp. Connect with:
//   claude mcp add meeting-notes -- ~/.meetnotes/bin/meetingnotes-mcp

let serverVersion = "1.0"
let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
let maxText = 100_000   // characters per get_notes / get_transcript call; use offset for the rest

// MARK: Meetings on disk

/// The app's meetings folder: MEETINGNOTES_DIR (used by the tests), else the app's setting, else the default.
let root: URL = {
    let env = ProcessInfo.processInfo.environment["MEETINGNOTES_DIR"]
    let setting = UserDefaults(suiteName: "se.frinkle.meetingnotes")?.string(forKey: "outputDir")
    let path = env ?? setting ?? "~/Documents/Meetings"
    return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}()

struct Meta: Decodable {
    var title: String
    var created: Date?
    var status: String?
    var app: String?
    var duration: Double?
}

struct Meeting {
    let id: String   // the folder name
    let folder: URL
    let meta: Meta
    let created: Date
    let status: String

    var notesURL: URL { folder.appendingPathComponent("notes.md") }
    var transcriptURL: URL { folder.appendingPathComponent("transcript.md") }
}

func loadMeeting(_ dir: URL) -> Meeting? {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")) else { return nil }
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    guard let meta = try? d.decode(Meta.self, from: data) else { return nil }
    let created = meta.created
        ?? (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        ?? .distantPast
    var status = meta.status ?? ""
    if status.isEmpty {
        status = FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.md").path) ? "done" : "failed"
    }
    return Meeting(id: dir.lastPathComponent, folder: dir, meta: meta, created: created, status: status)
}

/// All meetings, newest first.
func loadAll() -> [Meeting] {
    let dirs = (try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
    return dirs.compactMap(loadMeeting).sorted { $0.created > $1.created }
}

/// A meeting by folder name. Rejects anything that isn't a plain folder name inside the meetings folder.
func meeting(_ id: String) -> Meeting? {
    guard !id.isEmpty, !id.hasPrefix("."), !id.contains("/"), !id.contains("\0") else { return nil }
    return loadMeeting(root.appendingPathComponent(id, isDirectory: true))
}

func read(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

// MARK: Formatting

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    return f
}()

let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func formatDuration(_ seconds: Double) -> String {
    let t = max(0, Int(seconds))
    if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) }
    return String(format: "%d:%02d", t / 60, t % 60)
}

func summary(_ m: Meeting) -> [String: Any] {
    var out: [String: Any] = [
        "id": m.id, "title": m.meta.title, "status": m.status,
        "has_notes": FileManager.default.fileExists(atPath: m.notesURL.path),
        "has_transcript": FileManager.default.fileExists(atPath: m.transcriptURL.path),
    ]
    if m.created != .distantPast { out["date"] = isoFormatter.string(from: m.created) }
    if let d = m.meta.duration { out["duration"] = formatDuration(d) }
    if let app = m.meta.app { out["app"] = app }
    return out
}

func json(_ value: Any, pretty: Bool = false) -> String {
    var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
    if pretty { options.insert(.prettyPrinted) }
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return "null" }
    return String(decoding: data, as: UTF8.self)
}

/// Up to `limit` one-line snippets around each case- and accent-insensitive match of `query` in `text`.
func snippets(_ text: String, _ query: String, limit: Int = 3) -> [String] {
    var out: [String] = []
    var from = text.startIndex
    while out.count < limit,
          let r = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
        let start = text.index(r.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
        var s = text[start..<end].components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if start != text.startIndex { s = "…" + s }
        if end != text.endIndex { s += "…" }
        out.append(s)
        from = end
    }
    return out
}

/// A slice of a long text, with a note on how to read the rest.
func page(_ text: String, offset: Int) -> String {
    let chars = Array(text)
    let start = min(max(0, offset), chars.count)
    let end = min(start + maxText, chars.count)
    var out = String(chars[start..<end])
    if end < chars.count {
        out += "\n\n[Truncated: showing characters \(start)–\(end) of \(chars.count). Call again with offset \(end) for more.]"
    }
    return out
}

// MARK: Tools

struct ToolError: Error { let message: String }

let tools: [[String: Any]] = [
    [
        "name": "list_meetings",
        "description": "List recorded meetings, newest first, with id, title, date, duration, status and call app. Use the id with get_notes or get_transcript.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "from": ["type": "string", "description": "Only meetings on or after this date (YYYY-MM-DD)."],
                "to": ["type": "string", "description": "Only meetings on or before this date (YYYY-MM-DD)."],
                "limit": ["type": "integer", "description": "Maximum number of meetings (default 50, max 500)."],
            ],
        ],
        "annotations": ["readOnlyHint": true],
    ],
    [
        "name": "search_meetings",
        "description": "Case-insensitive text search across meeting titles, notes and transcripts. Returns matching meetings with snippets.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Text to search for."],
                "limit": ["type": "integer", "description": "Maximum number of meetings (default 20, max 100)."],
            ],
            "required": ["query"],
        ],
        "annotations": ["readOnlyHint": true],
    ],
    [
        "name": "get_notes",
        "description": "The meeting notes (Markdown: summary, decisions, action items, open questions, key points) for a meeting id.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "Meeting id from list_meetings or search_meetings."],
                "offset": ["type": "integer", "description": "Character offset to continue a truncated result."],
            ],
            "required": ["id"],
        ],
        "annotations": ["readOnlyHint": true],
    ],
    [
        "name": "get_transcript",
        "description": "The full transcript (Markdown, timestamped, with speaker names) for a meeting id. Long transcripts are returned in parts; use offset to continue.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "Meeting id from list_meetings or search_meetings."],
                "offset": ["type": "integer", "description": "Character offset to continue a truncated result."],
            ],
            "required": ["id"],
        ],
        "annotations": ["readOnlyHint": true],
    ],
]

func intArg(_ args: [String: Any], _ key: String, default value: Int, max upper: Int) -> Int {
    min(max(1, (args[key] as? NSNumber)?.intValue ?? value), upper)
}

func dayArg(_ args: [String: Any], _ key: String) throws -> Date? {
    guard let s = args[key] as? String, !s.isEmpty else { return nil }
    guard let d = dayFormatter.date(from: s) else { throw ToolError(message: "\(key) must be a date like 2026-01-31.") }
    return d
}

func requiredMeeting(_ args: [String: Any]) throws -> Meeting {
    guard let id = args["id"] as? String, !id.isEmpty else { throw ToolError(message: "id is required.") }
    guard let m = meeting(id) else { throw ToolError(message: "No meeting with id \"\(id)\". Use list_meetings to find ids.") }
    return m
}

func callTool(_ name: String, _ args: [String: Any]) throws -> String {
    switch name {
    case "list_meetings":
        let from = try dayArg(args, "from")
        let to = try dayArg(args, "to").map { Calendar.current.date(byAdding: .day, value: 1, to: $0)! }
        let limit = intArg(args, "limit", default: 50, max: 500)
        let all = loadAll().filter { m in
            (from.map { m.created >= $0 } ?? true) && (to.map { m.created < $0 } ?? true)
        }
        var out: [String: Any] = ["meetings": all.prefix(limit).map(summary), "total": all.count]
        if all.count > limit { out["note"] = "Showing the newest \(limit) of \(all.count). Narrow the dates or raise limit." }
        return json(out, pretty: true)

    case "search_meetings":
        let query = ((args["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolError(message: "query is required.") }
        let limit = intArg(args, "limit", default: 20, max: 100)
        var results: [[String: Any]] = []
        for m in loadAll() where results.count < limit {
            var matches: [[String: String]] = []
            for (field, text) in [("title", m.meta.title), ("notes", read(m.notesURL)), ("transcript", read(m.transcriptURL))] {
                guard let text else { continue }
                matches += snippets(text, query).map { ["in": field, "text": $0] }
            }
            if !matches.isEmpty {
                var r = summary(m)
                r["matches"] = matches
                results.append(r)
            }
        }
        return json(["query": query, "results": results], pretty: true)

    case "get_notes", "get_transcript":
        let m = try requiredMeeting(args)
        let notes = name == "get_notes"
        guard let text = read(notes ? m.notesURL : m.transcriptURL) else {
            throw ToolError(message: "\"\(m.meta.title)\" has no \(notes ? "notes" : "transcript") yet (status: \(m.status)).")
        }
        let header = "# \(m.meta.title)\n\(m.created == .distantPast ? "" : isoFormatter.string(from: m.created) + "\n")\n"
        return header + page(text, offset: (args["offset"] as? NSNumber)?.intValue ?? 0)

    default:
        throw ToolError(message: "Unknown tool: \(name)")
    }
}

// MARK: Resources (notes and transcripts of recent meetings)

func resourceURI(_ m: Meeting, _ file: String) -> String {
    let id = m.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? m.id
    return "meetingnotes://meetings/\(id)/\(file)"
}

func listResources() -> [[String: Any]] {
    loadAll().prefix(100).flatMap { m -> [[String: Any]] in
        var out: [[String: Any]] = []
        if FileManager.default.fileExists(atPath: m.notesURL.path) {
            out.append(["uri": resourceURI(m, "notes.md"), "name": "\(m.meta.title) – notes", "mimeType": "text/markdown"])
        }
        if FileManager.default.fileExists(atPath: m.transcriptURL.path) {
            out.append(["uri": resourceURI(m, "transcript.md"), "name": "\(m.meta.title) – transcript", "mimeType": "text/markdown"])
        }
        return out
    }
}

func readResource(_ uri: String) -> String? {
    let prefix = "meetingnotes://meetings/"
    guard uri.hasPrefix(prefix) else { return nil }
    let parts = uri.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, ["notes.md", "transcript.md"].contains(String(parts[1])),
          let id = String(parts[0]).removingPercentEncoding, let m = meeting(id) else { return nil }
    return read(m.folder.appendingPathComponent(String(parts[1]))).map { page($0, offset: 0) }
}

// MARK: JSON-RPC

struct RPCError: Error {
    let code: Int
    let message: String
}

func handle(_ method: String, _ params: [String: Any]) throws -> Any {
    switch method {
    case "initialize":
        let requested = params["protocolVersion"] as? String ?? ""
        return [
            "protocolVersion": protocolVersions.contains(requested) ? requested : protocolVersions[0],
            "capabilities": ["tools": [String: Any](), "resources": [String: Any]()],
            "serverInfo": ["name": "meeting-notes", "version": serverVersion],
            "instructions": "Read-only access to the user's recorded meetings from the Meeting Notes app. Use list_meetings or search_meetings to find a meeting id, then get_notes (summary, decisions, action items) or get_transcript (what was said).",
        ] as [String: Any]
    case "ping":
        return [String: Any]()
    case "tools/list":
        return ["tools": tools]
    case "tools/call":
        guard let name = params["name"] as? String, tools.contains(where: { $0["name"] as? String == name }) else {
            throw RPCError(code: -32602, message: "Unknown tool: \(params["name"] ?? "")")
        }
        do {
            let text = try callTool(name, params["arguments"] as? [String: Any] ?? [:])
            return ["content": [["type": "text", "text": text]], "isError": false] as [String: Any]
        } catch let e as ToolError {
            return ["content": [["type": "text", "text": e.message]], "isError": true] as [String: Any]
        }
    case "resources/list":
        return ["resources": listResources()]
    case "resources/templates/list":
        return ["resourceTemplates": [Any]()]
    case "resources/read":
        let uri = params["uri"] as? String ?? ""
        guard let text = readResource(uri) else { throw RPCError(code: -32002, message: "Resource not found: \(uri)") }
        return ["contents": [["uri": uri, "mimeType": "text/markdown", "text": text]]]
    default:
        throw RPCError(code: -32601, message: "Method not found: \(method)")
    }
}

func send(_ message: [String: Any]) {
    FileHandle.standardOutput.write(Data((json(message) + "\n").utf8))
}

while let line = readLine() {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    guard let msg = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
        send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        continue
    }
    guard let method = msg["method"] as? String else { continue }   // a response to us; we send no requests
    guard let id = msg["id"] else { continue }                        // a notification, e.g. notifications/initialized
    do {
        let result = try handle(method, msg["params"] as? [String: Any] ?? [:])
        send(["jsonrpc": "2.0", "id": id, "result": result])
    } catch let e as RPCError {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": e.code, "message": e.message]])
    } catch {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": "\(error)"]])
    }
}
