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

func testToolsEnvironment() {
    setenv("ANTHROPIC_API_KEY", "sk-test", 1)
    expect(Tools.environment["ANTHROPIC_API_KEY"] == nil, "API key must be removed so the subscription is used")
    expect(Tools.environment["PATH"]?.contains("/opt/homebrew/bin") == true, "PATH includes Homebrew")
}

@main
struct TestMain {
    static func main() {
        registerDefaults()
        testFormatDuration()
        testIsNoise()
        testMerge()
        testMicUser()
        do { try testStore() } catch { expect(false, "Store threw: \(error)") }
        testCallTitles()
        testToolsEnvironment()
        print("\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
