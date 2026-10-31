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
    for provider in NotesProvider.allCases {
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

@main
struct TestMain {
    static func main() async {
        registerDefaults()
        testFormatDuration()
        testIsNoise()
        testMerge()
        testMicUser()
        do { try testStore() } catch { expect(false, "Store threw: \(error)") }
        testCallTitles()
        do { try testNotificationSummary() } catch { expect(false, "notes summary threw: \(error)") }
        testToolsEnvironment()
        testLoginErrors()
        do { try await testNotesProviders() } catch { expect(false, "providers threw: \(error)") }
        do { try await testNotesInstructions() } catch { expect(false, "instructions threw: \(error)") }
        do { try testMCPServer() } catch { expect(false, "MCP server threw: \(error)") }
        print("\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
