import Foundation
import AppKit
import AVFoundation

// The logic behind the first-run setup window (SetupView.swift): downloads that resume, and
// checking, installing and signing in to the notes providers without Terminal.

// MARK: Resumable downloads

/// What to do with a server response to a (possibly ranged) download request. Pure, so it is tested.
enum DownloadPlan: Equatable {
    case append(total: Int64?)    // the server continues where the partial file ends
    case restart(total: Int64?)   // start over: the server sent the whole file
    case complete                 // the partial file already holds everything
    case fail(String)
}

enum DownloadLogic {
    static func rangeHeader(existing: Int64) -> String? { existing > 0 ? "bytes=\(existing)-" : nil }

    /// "bytes 100-199/2000" → (100, 2000); "bytes */2000" → (nil, 2000); unknown total "…/*" → nil total.
    static func parseContentRange(_ value: String?) -> (start: Int64?, total: Int64?)? {
        guard let value, value.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = value.dropFirst(6).trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let total = Int64(parts[1])
        if parts[0] == "*" { return (nil, total) }
        guard let dash = parts[0].firstIndex(of: "-"), let start = Int64(parts[0][..<dash]) else { return nil }
        return (start, total)
    }

    static func plan(status: Int, existing: Int64, contentRange: String?, contentLength: Int64?) -> DownloadPlan {
        switch status {
        case 206:
            guard let range = parseContentRange(contentRange), let start = range.start else {
                return .restart(total: nil)
            }
            if start == existing { return .append(total: range.total) }
            return start == 0 ? .restart(total: range.total) : .fail("The server sent the wrong part of the file.")
        case 200:
            return .restart(total: contentLength.flatMap { $0 >= 0 ? $0 : nil })
        case 416:
            // Asked for bytes past the end: done if the partial file is exactly the full size.
            if let total = parseContentRange(contentRange)?.total, total == existing, existing > 0 { return .complete }
            return .restart(total: nil)
        case 404, 410:
            return .fail("The file isn't available at the download address (error \(status)).")
        default:
            return .fail("The download server answered with error \(status).")
        }
    }

    /// The downloaded size must match what the server announced.
    static func isComplete(size: Int64, total: Int64?, minimum: Int64) -> Bool {
        if let total { return size == total && size >= minimum }
        return size >= minimum
    }

    static func partURL(_ dest: URL) -> URL { dest.appendingPathExtension("part") }
}

/// Downloads a file to `dest`, keeping what has arrived in `dest.part` so a later call (after a
/// network error, a cancel or quitting the app) continues from there.
final class FileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Progress = @Sendable (_ received: Int64, _ total: Int64?) -> Void

    private let configuration: URLSessionConfiguration
    // Only touched on the session's serial delegate queue.
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var total: Int64?
    private var failure: String?
    private var lastReport = Date.distantPast
    private var progress: Progress?
    private var part: URL?
    private var continuation: CheckedContinuation<Void, Error>?

    init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    func download(_ url: URL, to dest: URL, minimumSize: Int64 = 1, progress: @escaping Progress) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = DownloadLogic.partURL(dest)
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let existing = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0

        var request = URLRequest(url: url, timeoutInterval: 60)
        if let range = DownloadLogic.rangeHeader(existing: existing) { request.setValue(range, forHTTPHeaderField: "Range") }

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        // Set before the task starts, so before any delegate callback reads them.
        self.part = part
        self.received = existing
        self.total = nil
        self.progress = progress
        self.failure = nil

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                queue.addOperation {
                    self.continuation = cont
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }

        let size = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        guard DownloadLogic.isComplete(size: size, total: total, minimum: minimumSize) else {
            try? fm.removeItem(at: part)   // a wrong size won't fix itself by resuming
            throw PipelineError(message: "The download was incomplete. Please try again.")
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: part, to: dest)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let plan = DownloadLogic.plan(status: http?.statusCode ?? 0, existing: received,
                                      contentRange: http?.value(forHTTPHeaderField: "Content-Range"),
                                      contentLength: response.expectedContentLength)
        guard let part else { return completionHandler(.cancel) }
        do {
            switch plan {
            case .append(let t):
                total = t
                handle = try FileHandle(forWritingTo: part)
                try handle?.seekToEnd()
            case .restart(let t):
                total = t
                received = 0
                try Data().write(to: part)
                handle = try FileHandle(forWritingTo: part)
            case .complete:
                total = received
                return completionHandler(.cancel)
            case .fail(let message):
                failure = message
                return completionHandler(.cancel)
            }
        } catch {
            failure = "Couldn't save the download: \(error.localizedDescription)"
            return completionHandler(.cancel)
        }
        progress?(received, total)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            failure = "Couldn't save the download (is the disk full?): \(error.localizedDescription)"
            dataTask.cancel()
            return
        }
        received += Int64(data.count)
        let now = Date()
        if now.timeIntervalSince(lastReport) > 0.2 {
            lastReport = now
            progress?(received, total)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let cont = continuation
        continuation = nil
        progress?(received, total)
        if let failure {
            cont?.resume(throwing: PipelineError(message: failure))
        } else if let error = error as? URLError, error.code == .cancelled, total != nil, received == total {
            cont?.resume()   // `.complete`: nothing left to fetch
        } else if let error = error as? URLError, error.code == .cancelled {
            cont?.resume(throwing: CancellationError())
        } else if let error {
            cont?.resume(throwing: PipelineError(message: "The download stopped: \(error.localizedDescription) It continues where it left off when you try again."))
        } else {
            cont?.resume()
        }
    }
}

// MARK: Notes provider checks

enum ProviderCheck: Equatable {
    case checking
    case notInstalled
    case signedOut          // installed but not signed in
    case unknown(String)    // installed; sign-in couldn't be checked
    case ready
    // Ollama
    case notRunning
    case modelMissing
}

enum ProviderSetup {
    /// Parses `claude auth status --json`; nil when the output isn't that JSON (older versions).
    static func claudeLoggedIn(_ output: String) -> Bool? {
        guard let start = output.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [String: Any],
              let loggedIn = obj["loggedIn"] as? Bool else { return nil }
        return loggedIn
    }

    /// The first https URL in a sign-in command's output, to offer if the browser didn't open.
    static func firstURL(in text: String) -> URL? {
        for word in text.split(whereSeparator: { $0.isWhitespace }) where word.hasPrefix("https://") {
            return URL(string: String(word).trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>()[],")))
        }
        return nil
    }

    static func check(_ provider: NotesProvider) async -> ProviderCheck {
        switch provider {
        case .claude:
            guard let exe = Tools.claude else { return .notInstalled }
            let r = await runProcess(exe, ["auth", "status", "--json"])
            if let loggedIn = claudeLoggedIn(r.out) { return loggedIn ? .ready : .signedOut }
            return .unknown("Installed. Make sure you're signed in (Sign in below).")
        case .codex:
            guard let exe = Tools.codex else { return .notInstalled }
            let r = await runProcess(exe, ["login", "status"])
            return r.status == 0 ? .ready : .signedOut
        case .ollama:
            switch await Ollama.status(model: Ollama.model, base: Ollama.baseURL) {
            case .ready: return .ready
            case .modelMissing: return .modelMissing
            case .notRunning, .checking: return Tools.ollamaInstalled ? .notRunning : .notInstalled
            }
        }
    }

    /// Codex release asset for this Mac.
    static var codexArchive: (url: URL, binary: String) {
        #if arch(arm64)
        let triple = "aarch64-apple-darwin"
        #else
        let triple = "x86_64-apple-darwin"
        #endif
        return (URL(string: "https://github.com/openai/codex/releases/latest/download/codex-\(triple).tar.gz")!, "codex-\(triple)")
    }

    static let claudeInstaller = "curl -fsSL https://claude.ai/install.sh | bash"
    static let claudeDownloadPage = URL(string: "https://claude.com/product/claude-code")!
    static let codexDownloadPage = URL(string: "https://developers.openai.com/codex/cli")!
    static let ollamaDownloadPage = URL(string: "https://ollama.com/download/mac")!
    static let claudeDesktopPage = URL(string: "https://claude.ai/download")!

    /// Opens Terminal running a command, for the rare case a background sign-in doesn't work.
    static func openInTerminal(_ command: String) {
        let script = Tools.dataDir.appendingPathComponent("signin.command")
        let body = "#!/bin/bash\nexport PATH=\"\(Tools.environment["PATH"] ?? "")\"\n\(command)\necho\necho 'Done. You can close this window and go back to Meeting Notes.'\n"
        try? FileManager.default.createDirectory(at: Tools.dataDir, withIntermediateDirectories: true)
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }
}

// MARK: Ollama model download

extension Ollama {
    /// One line of `/api/pull` progress: {"status":"pulling …","total":…,"completed":…} or {"error":"…"}.
    static func pullProgress(_ line: String) -> (status: String, completed: Int64?, total: Int64?, error: String?)? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        return (obj["status"] as? String ?? "",
                (obj["completed"] as? NSNumber)?.int64Value,
                (obj["total"] as? NSNumber)?.int64Value,
                obj["error"] as? String)
    }

    /// Downloads the notes model through the local Ollama server, reporting progress.
    static func pull(model: String, base: String, progress: @escaping (String, Double?) -> Void) async throws {
        guard let url = endpoint(base, "/api/pull") else { throw PipelineError(message: notRunningMessage(base)) }
        var request = URLRequest(url: url, timeoutInterval: 3600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PipelineError(message: "Ollama couldn't download \(model).")
        }
        for try await line in bytes.lines {
            guard let p = pullProgress(line) else { continue }
            if let error = p.error { throw PipelineError(message: "Ollama couldn't download \(model): \(error)") }
            let fraction = p.total.flatMap { t in t > 0 ? Double(p.completed ?? 0) / Double(t) : nil }
            progress(p.status, fraction)
        }
    }
}

// MARK: Where the app runs from

enum AppLocation {
    /// Running from the disk image or a quarantine copy ("App Translocation"): paths given to other
    /// apps (the MCP server) wouldn't last, so setup asks to move the app to Applications first.
    static func needsMove(_ path: String) -> Bool {
        path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    /// A downloaded app's files carry the quarantine flag. Opening the app is approved by the user
    /// (Open Anyway), but the helpers it runs (whisper-cli, and the MCP server that Claude Desktop runs)
    /// are checked again on their own, and macOS stops an unsigned helper that is still flagged. The app
    /// is running, so the user has approved it: remove the flag from its own helpers.
    static func clearQuarantine(_ files: [URL]) {
        for f in files {
            _ = f.withUnsafeFileSystemRepresentation { path in
                path.map { removexattr($0, "com.apple.quarantine", 0) }
            }
        }
    }

    static var bundledHelpers: [URL] {
        let contents = URL(fileURLWithPath: Bundle.main.bundlePath).appendingPathComponent("Contents")
        return ["MacOS/whisper-cli", "MacOS/meetingnotes-mcp", "Resources/MeetingNotes.mcpb"]
            .map { contents.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
