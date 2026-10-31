import Foundation

// Minimal test runner: compiled together with src/ (minus App.swift) by tests/run.sh.
// No XCTest, so it works with just the Xcode command line tools.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func expect(_ ok: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok {
        failures += 1
        print("FAIL (line \(line)): \(message())")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, line: Int = #line) {
    expect(a == b, "\(a) != \(b)", line: line)
}

func testFormatDuration() {
    expectEqual(formatDuration(0), "0:00")
    expectEqual(formatDuration(-5), "0:00")
    expectEqual(formatDuration(65.9), "1:05")
    expectEqual(formatDuration(3599), "59:59")
    expectEqual(formatDuration(3600), "1:00:00")
    expectEqual(formatDuration(3725), "1:02:05")
}

func testIsNoise() {
    for t in ["", "[Music]", "(laughs)", "*applause*", "...", " - ", "♪"] {
        expect(Pipeline.isNoise(t), "should be noise: \(t)")
    }
    for t in ["Hej", "OK.", "Det här är ett test.", "[Music] then talking"] {
        expect(!Pipeline.isNoise(t), "should be speech: \(t)")
    }
}

func testMerge() {
    let me: [(Double, String)] = [(0, "Hej."), (2, "Hur mår du?"), (20, "Bra.")]
    let others: [(Double, String)] = [(10, "Fint, tack."), (65, "Hej då.")]
    let out = Pipeline.merge(me: me, others: others, myName: "Anna")
    let expected = """
    [0:00] **Anna:** Hej. Hur mår du?

    [0:10] **Others:** Fint, tack.

    [0:20] **Anna:** Bra.

    [1:05] **Others:** Hej då.
    """
    expectEqual(out, expected)
    expectEqual(Pipeline.merge(me: [], others: [], myName: "Anna"), "")
}

func testMicUser() {
    let chrome = MicUser(pid: 1, bundleID: "com.google.Chrome.helper", name: "Google Chrome")
    expectEqual(chrome.key, "com.google.Chrome")
    expect(!chrome.isSystem, "Chrome is not a system process")

    let zoom = MicUser(pid: 1, bundleID: "us.zoom.xos", name: "zoom.us")
    expectEqual(zoom.key, "us.zoom.xos")

    for b in ["com.apple.FaceTime", "com.apple.WebKit.GPU", "com.apple.Safari"] {
        expect(!MicUser(pid: 1, bundleID: b, name: "").isSystem, "\(b) should count as a call app")
    }
    for b in ["com.apple.replayd", "com.apple.SpeechRecognitionCore", ""] {
        expect(MicUser(pid: 1, bundleID: b, name: "").isSystem, "\(b) should be ignored")
    }
    expect(MicUser(pid: getpid(), bundleID: "x.y", name: "").isSystem, "own process should be ignored")
}

func testStore() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("meetingnotes-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    UserDefaults.standard.register(defaults: [Keys.outputDir: root.path])
    expectEqual(Store.root.path, root.path)

    let date = Date(timeIntervalSince1970: 1_760_000_000)
    let a = try Store.newFolder(title: "Q3: plan/review?", date: date)
    let b = try Store.newFolder(title: "Q3: plan/review?", date: date)
    expect(a.lastPathComponent.hasSuffix(" Q3 planreview"), "unsafe characters removed: \(a.lastPathComponent)")
    expect(b.lastPathComponent.hasSuffix(" Q3 planreview 2"), "duplicate gets a suffix: \(b.lastPathComponent)")
    let blank = try Store.newFolder(title: " /:: ", date: date)
    expect(blank.lastPathComponent.hasSuffix(" Meeting"), "empty title falls back: \(blank.lastPathComponent)")

    let created = Date(timeIntervalSince1970: 1_760_000_100)
    Store.writeMeta(Meta(title: "Weekly", created: created, status: "done", app: "Zoom",
                         lang: "sv", offsets: ["me": 0.2, "others": 0], duration: 61), to: a)
    let m = Store.readMeta(a)
    expectEqual(m?.title, "Weekly")
    expectEqual(m?.created, created)
    expectEqual(m?.offsets?["me"], 0.2)

    Store.update(a) { $0.status = "failed"; $0.error = "boom" }
    expectEqual(Store.readMeta(a)?.status, "failed")
    expectEqual(Store.readMeta(a)?.error, "boom")
    expectEqual(Store.readMeta(a)?.title, "Weekly")

    // Folders without meta.json are skipped; the rest are sorted newest first.
    Store.writeMeta(Meta(title: "Older", created: created.addingTimeInterval(-3600)), to: b)
    let all = Store.loadAll()
    expectEqual(all.map(\.title), ["Weekly", "Older"])
    expectEqual(all.first?.isBusy, false)
}

func testArchiveAudio() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("mn-archive-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    Store.writeMeta(Meta(title: "Weekly", status: "done"), to: dir)
    for f in ["me.wav", "others.wav", "me.caf", "transcript.md", "notes.md", "me.json"] {
        try "x".write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8)
    }
    expectEqual(Store.audioFiles(dir).map(\.lastPathComponent).sorted(), ["me.caf", "me.wav", "others.wav"])
    let before = Meeting(folder: dir, meta: Meta(title: "Weekly"), created: Date(), status: "done",
                         hasAudio: !Store.audioFiles(dir).isEmpty)
    expect(!before.isArchived, "meeting with audio is not archived")

    Store.archiveAudio(dir)
    expect(Store.audioFiles(dir).isEmpty, "audio files are deleted")
    for f in ["transcript.md", "notes.md", "meta.json", "me.json"] {
        expect(fm.fileExists(atPath: dir.appendingPathComponent(f).path), "\(f) is kept")
    }
    expect(Store.readMeta(dir)?.audioArchived != nil, "archive date is recorded")
    expectEqual(Store.readMeta(dir)?.title, "Weekly")
    let after = Meeting(folder: dir, meta: Meta(title: "Weekly"), created: Date(), status: "done", hasAudio: false)
    expect(after.isArchived, "meeting without audio is archived")
    expect(!Meeting(folder: dir, meta: Meta(title: "R"), created: Date(), status: "recording").isArchived,
           "a recording in progress is not archived")
}

func testSearch() {
    expect(TextSearch.matches("budget anna", in: "Weekly\n**Anna:** We agreed on the Budget."), "all words, any order, any case")
    expect(TextSearch.matches("mote", in: "Möte om budget"), "diacritics are ignored")
    expect(!TextSearch.matches("budget bob", in: "Anna: the budget"), "every word must appear")
    expect(TextSearch.matches("  ", in: "anything"), "empty query matches everything")
    expectEqual(TextSearch.ranges(of: "ab", in: "abcABab").count, 3)
    expectEqual(TextSearch.ranges(of: "aa", in: "aaaa").count, 2)
    expectEqual(TextSearch.ranges(of: "", in: "abc").count, 0)

    // Find in note matches the rendered text: Markdown markers and list bullets don't get in the way.
    let note = "## Budget\n\n- **Anna:** budget is fine\n- [ ] Send the budget\nNo match here"
    expectEqual(MarkdownView.matches(of: "budget", in: note),
                [.init(line: 0, index: 0), .init(line: 2, index: 0), .init(line: 3, index: 0)])
    expectEqual(MarkdownView.matches(of: "Anna: budget", in: note), [.init(line: 2, index: 0)])
    expectEqual(MarkdownView.matches(of: "[ ]", in: note), [])
    expectEqual(MarkdownView.matches(of: "", in: note), [])

    // A long transcript stays quick to search.
    let transcript = (0..<500).map { "[\(formatDuration(Double($0) * 7))] **Anna:** line \($0) about the budget and the plan" }
        .joined(separator: "\n\n")
    let start = Date()
    let found = MarkdownView.matches(of: "plan", in: transcript)
    expectEqual(found.count, 500)
    expect(Date().timeIntervalSince(start) < 0.5, "searching 500 lines took \(Date().timeIntervalSince(start)) s")
}

// Capture can fail mid-meeting (#4): earlier segments are kept as me-N/others-N, and a meeting
// with only the microphone track is still transcribed.
func testSegmentsAndMicOnly() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("mn-segments-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    func touch(_ f: String) throws { try "x".write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8) }

    try touch("me.caf")
    expectEqual(Pipeline.tracks(in: dir), ["me"])   // mic only: nothing from the call audio

    try touch("others.caf")
    let kept = Store.closeSegment(dir, number: 1, offsets: ["me": 0.5, "others": 0], start: 0)
    expectEqual(kept, ["me-1": 0.5, "others-1": 0])
    expect(!fm.fileExists(atPath: dir.appendingPathComponent("me.caf").path), "segment files are renamed")
    try touch("me.caf")   // the mic-only segment after the failure
    let later = Store.closeSegment(dir, number: 2, offsets: ["missing": 1], start: 600)
    expectEqual(later, [:])
    try touch("transcript.md")
    try touch("me.json")
    try touch("notes-2.wav")
    expectEqual(Pipeline.tracks(in: dir), ["me", "me-1", "others-1"])

    expectEqual(Pipeline.speaker(of: "me"), "me")
    expectEqual(Pipeline.speaker(of: "others-12"), "others")
    expectEqual(Pipeline.speaker(of: "me-x"), nil)
    expectEqual(Pipeline.speaker(of: "notes"), nil)
}

func testCallTitles() {
    expectEqual(CallInfo.cleanTitle("Meet – Work RightHub"), "Work RightHub")
    expectEqual(CallInfo.cleanTitle("(2) Meet - Weekly sync"), "Weekly sync")
    expectEqual(CallInfo.cleanTitle("Meet – oka-dnjv-xkd"), nil)
    expectEqual(CallInfo.cleanTitle("Planning | Microsoft Teams"), "Planning")
    expectEqual(CallInfo.cleanTitle("Microsoft Teams"), nil)
    expectEqual(CallInfo.cleanTitle("Zoom"), nil)
}

func testNotificationSummary() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-notes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    expectEqual(Notifier.summary(dir), nil)
    try "# Weekly\n\n## Summary\n\nWe agreed on the budget.\n\n## Decisions\n- Ship it\n"
        .write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    expectEqual(Notifier.summary(dir), "We agreed on the budget.")
    try ("# T\n\n" + String(repeating: "a", count: 300)).write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    expectEqual(Notifier.summary(dir)?.count, 180)
}

func testToolsEnvironment() {
    setenv("ANTHROPIC_API_KEY", "sk-test", 1)
    expect(Tools.environment["ANTHROPIC_API_KEY"] == nil, "API key must be removed so the subscription is used")
    expect(Tools.environment["PATH"]?.contains("/opt/homebrew/bin") == true, "PATH includes Homebrew")
}

// Exercise the actual subprocess boundary without accounts or meeting data.
func testNotesProviders() async throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("mn-provider-tests-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let defaults = UserDefaults.standard
    let keys = [Keys.claudePath, Keys.codexPath, Keys.notesProvider]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer {
        try? fm.removeItem(at: dir)
        for (key, value) in zip(keys, saved) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
    defaults.set("unknown", forKey: Keys.notesProvider)
    expectEqual(SettingsSnapshot.current().notesProvider, .claude)
    defaults.set("codex", forKey: Keys.notesProvider)
    expectEqual(SettingsSnapshot.current().notesProvider, .codex)

    let fake = dir.appendingPathComponent("fake-cli")
    let script = """
    #!/bin/sh
    case "$1" in
      -p)
        case "$2" in *"Meeting title: Synthetic sync"*) ;; *) exit 21 ;; esac
        [ "$(cat)" = "Synthetic transcript" ] || exit 22
        [ -z "$ANTHROPIC_API_KEY" ] || exit 23
        ;;
      --ask-for-approval)
        [ "$*" = "--ask-for-approval never exec --skip-git-repo-check --sandbox read-only --ephemeral -" ] || exit 24
        input="$(cat)"
        case "$input" in *"Meeting title: Synthetic sync"*"<transcript>"*"Synthetic transcript"*"</transcript>"*) ;; *) exit 25 ;; esac
        case "$PWD" in *meetingnotes-codex-*) ;; *) exit 26 ;; esac
        ;;
      *) exit 27 ;;
    esac
    echo 'progress on stderr' >&2
    printf '  ## Summary\\nSynthetic notes\\n'
    """
    try script.write(to: fake, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    defaults.set(fake.path, forKey: Keys.claudePath)
    defaults.set(fake.path, forKey: Keys.codexPath)
    for provider in [NotesProvider.claude, .codex] {
        let notes = try await Pipeline.summarize(transcript: "Synthetic transcript",
            meta: Meta(title: "Synthetic sync"), myName: "Test", folder: dir, provider: provider)
        expectEqual(notes, "## Summary\nSynthetic notes")
    }
    for (script, detail) in [("#!/bin/sh\ncat >/dev/null\necho login-required >&2\nexit 1\n", "login-required"),
                             ("#!/bin/sh\ncat >/dev/null\n", "codex login")] {
        try script.write(to: fake, atomically: true, encoding: .utf8)
        do {
            _ = try await Pipeline.summarize(transcript: "Synthetic transcript",
                meta: Meta(title: "Synthetic sync"), myName: "Test", folder: dir, provider: .codex)
            expect(false, "Failed/empty output must throw")
        } catch {
            expect(error.localizedDescription.contains("Codex (OpenAI)"), "Error identifies provider")
            expect(error.localizedDescription.contains(detail), "Error includes diagnostic or login hint")
        }
    }
}

// The editable instructions are part of the prompt; empty falls back to the default.
func testNotesInstructions() async throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("mn-instructions-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let d = UserDefaults.standard
    let keys = [Keys.claudePath, Keys.notesInstructions]
    let saved = keys.map { d.object(forKey: $0) }
    defer {
        try? fm.removeItem(at: dir)
        for (key, value) in zip(keys, saved) {
            if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        }
    }
    let echo = dir.appendingPathComponent("echo-prompt")   // prints the -p prompt back as the "notes"
    try "#!/bin/sh\ncat >/dev/null\nprintf '%s' \"$2\"\n".write(to: echo, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: echo.path)
    d.set(echo.path, forKey: Keys.claudePath)

    func prompt() async throws -> String {
        try await Pipeline.summarize(transcript: "x", meta: Meta(title: "Sync"), myName: "Ana", folder: dir, provider: .claude)
    }
    d.set("Only list action items as a checklist.", forKey: Keys.notesInstructions)
    var p = try await prompt()
    expect(p.contains("Only list action items as a checklist."), "custom instructions are used")
    expect(!p.contains("## Key points"), "default sections are replaced")
    expect(p.contains("lines marked \"Ana\" are Ana") && p.contains("Meeting title: Sync"), "context is always included")
    expect(p.hasSuffix("Output only the notes."), "output rule is always last")
    d.set("  \n ", forKey: Keys.notesInstructions)
    p = try await prompt()
    expect(p.contains("## Key points (grouped by topic)"), "empty instructions fall back to the default")
}

func testRecorderOffsets() {
    expectEqual(Recorder.offsets([:]), [:])
    expectEqual(Recorder.offsets(["me": 100.5]), ["me": 0])
    expectEqual(Recorder.offsets(["me": 100.25, "others": 101.0]), ["me": 0, "others": 0.75])
    expectEqual(Recorder.offsets(["me": 12.0, "others": 10.0]), ["me": 2, "others": 0])
}

func testLoginErrors() {
    expect(Pipeline.isLoginError("Failed to authenticate: OAuth session expired and could not be refreshed"), "Claude expired session")
    expect(Pipeline.isLoginError("Invalid API key · Please run /login"), "Claude logged out")
    expect(Pipeline.isLoginError("ERROR: unexpected status 401 Unauthorized: Missing bearer"), "Codex logged out")
    expect(!Pipeline.isLoginError("Error: prompt is too long"), "other errors are shown as is")
}

/// Pipes JSON-RPC requests into the built MCP server (MEETINGNOTES_MCP, set by run.sh) and checks the replies.
func testMCPServer() throws {
    guard let exe = ProcessInfo.processInfo.environment["MEETINGNOTES_MCP"] else {
        print("Skipping MCP server tests (MEETINGNOTES_MCP not set)")
        return
    }
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("mn-mcp-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    func meeting(_ name: String, _ meta: String, notes: String?, transcript: String?) throws {
        let f = dir.appendingPathComponent(name)
        try fm.createDirectory(at: f, withIntermediateDirectories: true)
        try meta.write(to: f.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        try notes?.write(to: f.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try transcript?.write(to: f.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try Data([0, 1]).write(to: f.appendingPathComponent("me.wav"))
    }
    try meeting("2026-01-05 0900 Weekly sync",
                #"{"title":"Weekly sync","created":"2026-01-05T09:00:00Z","status":"done","app":"Zoom","duration":1830}"#,
                notes: "## Summary\nWe agreed on the Budget for Q1.\n", transcript: "[0:00] **Ana:** Hej, budgeten är klar.\n")
    try meeting("2026-02-10 1400 Kundmöte", #"{"title":"Kundmöte","created":"2026-02-10T14:00:00Z","status":"transcribing"}"#,
                notes: nil, transcript: nil)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.environment = ["MEETINGNOTES_DIR": dir.path]
    let input = Pipe(), output = Pipe()
    p.standardInput = input
    p.standardOutput = output
    try p.run()
    let requests: [[String: Any]] = [
        ["method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:],
                                            "clientInfo": ["name": "tests", "version": "1"]]],
        ["method": "notifications/initialized"],
        ["method": "tools/list"],
        ["method": "tools/call", "params": ["name": "list_meetings", "arguments": [:]]],
        ["method": "tools/call", "params": ["name": "list_meetings", "arguments": ["from": "2026-02-01"]]],
        ["method": "tools/call", "params": ["name": "search_meetings", "arguments": ["query": "BUDGET"]]],
        ["method": "tools/call", "params": ["name": "get_notes", "arguments": ["id": "2026-01-05 0900 Weekly sync"]]],
        ["method": "tools/call", "params": ["name": "get_transcript", "arguments": ["id": "2026-02-10 1400 Kundmöte"]]],
        ["method": "tools/call", "params": ["name": "get_notes", "arguments": ["id": "../2026-01-05 0900 Weekly sync"]]],
        ["method": "resources/list"],
        ["method": "nope"],
    ]
    var id = 0
    for var r in requests {
        r["jsonrpc"] = "2.0"
        if r["method"] as? String != "notifications/initialized" { id += 1; r["id"] = id }
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: r) + Data("\n".utf8))
    }
    input.fileHandleForWriting.write(Data("not json\n".utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let replies = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
    }
    expectEqual(replies.count, id + 1)   // one per request plus the parse error; none for the notification
    guard replies.count == id + 1 else { return }
    func result(_ n: Int) -> [String: Any] { replies[n - 1]["result"] as? [String: Any] ?? [:] }
    func text(_ n: Int) -> String {
        ((result(n)["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }
    func isError(_ n: Int) -> Bool { result(n)["isError"] as? Bool ?? false }

    expectEqual(result(1)["protocolVersion"] as? String, "2025-06-18")
    expectEqual(((result(2)["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String },
                ["list_meetings", "search_meetings", "get_notes", "get_transcript"])
    let all = text(3)
    expect(all.contains("\"total\" : 2") && all.contains("\"duration\" : \"30:30\"") && all.contains("\"app\" : \"Zoom\""),
           "list_meetings: \(all)")
    expect(all.range(of: "Kundmöte")!.lowerBound < all.range(of: "Weekly sync")!.lowerBound, "newest first")
    expect(!all.contains(".wav"), "audio files are never listed")
    expect(text(4).contains("\"total\" : 1") && !text(4).contains("Weekly sync"), "from filters by date")
    let search = text(5)
    expect(search.contains("Weekly sync") && search.contains("the Budget for Q1") && search.contains("budgeten är klar"),
           "search matches notes and transcript case-insensitively: \(search)")
    expect(!search.contains("Kundmöte"), "search skips meetings without a match")
    expect(text(6).hasPrefix("# Weekly sync") && text(6).contains("We agreed on the Budget"), "get_notes")
    expect(isError(7) && text(7).contains("no transcript yet"), "missing transcript is a tool error")
    expect(isError(8) && text(8).contains("No meeting"), "ids can't leave the meetings folder")
    let uris = ((result(9)["resources"] as? [[String: Any]]) ?? []).compactMap { $0["uri"] as? String }
    expectEqual(uris, ["meetingnotes://meetings/2026-01-05%200900%20Weekly%20sync/notes.md",
                       "meetingnotes://meetings/2026-01-05%200900%20Weekly%20sync/transcript.md"])
    expectEqual((replies[9]["error"] as? [String: Any])?["code"] as? Int, -32601)
    expectEqual((replies[10]["error"] as? [String: Any])?["code"] as? Int, -32700)
}

// Stands in for the Ollama server: records each request and answers with `respond`.
final class MockOllama: URLProtocol {
    nonisolated(unsafe) static var requests: [(path: String, body: [String: Any])] = []
    nonisolated(unsafe) static var respond: (String, [String: Any]) -> (Int, String) = { _, _ in (500, "") }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {   // URLSession moves the body into a stream
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
        }
        let path = request.url?.path ?? ""
        let body = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        MockOllama.requests.append((path, body))
        let (status, reply) = MockOllama.respond(path, body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func testOllamaRequest() {
    let body = Ollama.chatBody(model: "qwen3:8b", prompt: "PROMPT", transcript: "[0:00] **Ana:** Hej.", cut: false)
    expectEqual(body["model"] as? String, "qwen3:8b")
    expectEqual(body["stream"] as? Bool, false)
    expectEqual(body["think"] as? Bool, false)
    let messages = body["messages"] as? [[String: String]] ?? []
    expectEqual(messages.map { $0["role"] ?? "" }, ["system", "user"])
    expectEqual(messages.first?["content"], "PROMPT")
    expect(messages.last?["content"]?.hasSuffix("<transcript>\n[0:00] **Ana:** Hej.\n</transcript>") == true, "transcript is sent as data")
    expectEqual((body["options"] as? [String: Int])?["num_ctx"], 8_192)
    expect(Ollama.chatBody(model: "m", prompt: "p", transcript: "x", cut: false, skipThinking: false)["think"] == nil, "think can be left out")

    // An hour of talk (~60k characters) gets a window that holds all of it.
    let hour = String(repeating: "[12:34] **Others:** Det här är en mening om budgeten.\n\n", count: 1_100)
    expect(Ollama.contextSize(hour) >= Ollama.estimatedTokens(hour) + Ollama.reserve, "window fits an hour")
    expect(Ollama.contextSize(hour) <= Ollama.maxContext, "window is capped")
    expectEqual(Ollama.truncated(hour), nil)
    let long = String(repeating: "[1:02:05] **Others:** Ett långt möte.\n\n", count: 4_000)
    let cut = Ollama.truncated(long) ?? ""
    expect(!cut.isEmpty && cut.count <= (Ollama.maxContext - Ollama.reserve) * 5 / 2, "long transcript is cut to fit")
    expect(cut.hasSuffix("Ett långt möte."), "cut at a whole turn")
    expectEqual(Ollama.lastTimestamp(cut), "1:02:05")
    expectEqual(Ollama.lastTimestamp("[0:10] a\n\n[3:07] b"), "3:07")

    expectEqual(Ollama.language(of: "[0:00] **Ana:** Hej allihop, idag ska vi bestämma budgeten för lanseringen i mars och vem som gör vad."), "Swedish")
    expectEqual(Ollama.language(of: "[0:00] **Ana:** Hej alle sammen. I dag skal vi tale om flytningen til det nye kontor, og hvem der gør hvad."), "Danish")
    expectEqual(Ollama.language(of: ""), nil)
    let sv = Ollama.chatBody(model: "m", prompt: "p", transcript: "t", cut: false, language: "Swedish", useLanguage: true)
    expect((sv["messages"] as? [[String: String]])?.last?["content"]?.hasSuffix("</transcript>\n\nThe transcript is in Swedish, so write the notes in Swedish, headings included.") == true, "language rule")
    let fact = Ollama.chatBody(model: "m", prompt: "p", transcript: "t", cut: false, language: "Swedish")
    expect((fact["messages"] as? [[String: String]])?.last?["content"]?.hasSuffix("</transcript>\n\nThe transcript is in Swedish.") == true, "custom instructions decide the language")

    expectEqual(Ollama.endpoint("http://localhost:11434/", "/api/chat")?.absoluteString, "http://localhost:11434/api/chat")
    expectEqual(Ollama.endpoint("localhost:11434", "/api/chat"), nil)
    expect(Ollama.hasModel(["qwen3:latest"], "qwen3"), "untagged name means :latest")
    expect(Ollama.hasModel(["qwen3:8b"], "qwen3:8b"), "exact tag")
    expect(!Ollama.hasModel(["qwen3:4b"], "qwen3:8b"), "other tag doesn't count")
}

func testOllamaProvider() async throws {
    let d = UserDefaults.standard
    let keys = [Keys.ollamaModel, Keys.ollamaURL, Keys.notesProvider]
    let saved = keys.map { d.object(forKey: $0) }
    let realSession = Ollama.session
    defer {
        Ollama.session = realSession
        for (key, value) in zip(keys, saved) {
            if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        }
    }
    d.set("ollama", forKey: Keys.notesProvider)
    expectEqual(SettingsSnapshot.current().notesProvider, .ollama)
    d.set("test-model:1b", forKey: Keys.ollamaModel)
    d.set("http://127.0.0.1:9/", forKey: Keys.ollamaURL)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockOllama.self]
    Ollama.session = URLSession(configuration: config)

    let meta = Meta(title: "Synthetic sync")
    func summarize() async throws -> String {
        try await Pipeline.summarize(transcript: "Synthetic transcript", meta: meta, myName: "Test",
                                     folder: FileManager.default.temporaryDirectory, provider: .ollama)
    }

    MockOllama.requests = []
    MockOllama.respond = { _, _ in (200, #"{"message":{"role":"assistant","content":"<think>\n</think>\n\n## Summary\nLocal notes\n"},"done":true}"#) }
    expectEqual(try await summarize(), "## Summary\nLocal notes")
    expectEqual(MockOllama.requests.count, 1)
    let sent = MockOllama.requests.first
    expectEqual(sent?.path, "/api/chat")
    expectEqual(sent?.body["model"] as? String, "test-model:1b")
    let messages = sent?.body["messages"] as? [[String: String]] ?? []
    expectEqual(messages.first?["content"], Pipeline.notesPrompt(meta: meta, myName: "Test"))
    expect(messages.last?["content"]?.contains("<transcript>\nSynthetic transcript\n</transcript>") == true, "transcript sent")

    // A server that rejects `think` is asked again without it.
    MockOllama.requests = []
    MockOllama.respond = { _, body in
        body["think"] == nil ? (200, #"{"message":{"content":"Notes"}}"#) : (400, #"{"error":"\"test-model:1b\" does not support thinking"}"#)
    }
    expectEqual(try await summarize(), "Notes")
    expectEqual(MockOllama.requests.count, 2)

    for (status, reply, detail) in [
        (404, #"{"error":"model \"test-model:1b\" not found, try pulling it first"}"#, "ollama pull test-model:1b"),
        (500, #"{"error":"out of memory"}"#, "out of memory"),
        (200, #"{"message":{"content":"  "}}"#, "returned no notes"),
    ] {
        MockOllama.respond = { _, _ in (status, reply) }
        do {
            _ = try await summarize()
            expect(false, "HTTP \(status) must throw")
        } catch {
            expect(error.localizedDescription.contains(detail), "error explains the fix: \(error.localizedDescription)")
        }
    }

    MockOllama.respond = { _, _ in (200, #"{"models":[{"name":"test-model:1b"},{"name":"other:latest"}]}"#) }
    expectEqual(await Ollama.status(model: "test-model:1b", base: Ollama.baseURL), .ready)
    expectEqual(await Ollama.status(model: "qwen3:8b", base: Ollama.baseURL), .modelMissing)
    expectEqual(MockOllama.requests.last?.path, "/api/tags")

    // Nothing listening: a clear "not running" message, not a raw network error.
    Ollama.session = realSession
    d.set("http://127.0.0.1:1", forKey: Keys.ollamaURL)
    do {
        _ = try await summarize()
        expect(false, "unreachable server must throw")
    } catch {
        expect(error.localizedDescription.contains("Ollama isn't running at http://127.0.0.1:1"), "not running: \(error.localizedDescription)")
        expect(error.localizedDescription.contains("press Retry"), "says the transcript is kept")
    }
    expectEqual(await Ollama.status(model: "qwen3:8b", base: "http://127.0.0.1:1"), .notRunning)
}

@main
struct TestMain {
    static func main() async {
        registerDefaults()
        testFormatDuration()
        testIsNoise()
        testMerge()
        testMicUser()
        do { try testStore() } catch { expect(false, "Store threw: \(error)") }
        do { try testArchiveAudio() } catch { expect(false, "archive threw: \(error)") }
        testSearch()
        do { try testSegmentsAndMicOnly() } catch { expect(false, "segments threw: \(error)") }
        testCallTitles()
        do { try testNotificationSummary() } catch { expect(false, "notes summary threw: \(error)") }
        testToolsEnvironment()
        testLoginErrors()
        testRecorderOffsets()
        do { try await testNotesProviders() } catch { expect(false, "providers threw: \(error)") }
        do { try await testNotesInstructions() } catch { expect(false, "instructions threw: \(error)") }
        do { try testMCPServer() } catch { expect(false, "MCP server threw: \(error)") }
        testOllamaRequest()
        do { try await testOllamaProvider() } catch { expect(false, "ollama threw: \(error)") }
        print("\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
