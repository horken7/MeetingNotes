import SwiftUI
import AppKit
import AVFoundation

// MARK: State

/// Drives the setup window. A singleton, so downloads and installs keep going when the window is closed,
/// and every check re-reads the real state, so setup can be left and resumed at any point.
@MainActor
final class SetupModel: ObservableObject {
    static let shared = SetupModel()
    nonisolated static let completedKey = "setupCompleted"
    nonisolated static let stepKey = "setupStep"
    static let systemAudioKey = "systemAudioAsked"

    enum Step: Int, CaseIterable, Identifiable {
        case welcome, speech, notes, permissions, claudeDesktop, done
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .speech: return "Speech model"
            case .notes: return "Writing notes"
            case .permissions: return "Permissions"
            case .claudeDesktop: return "Claude Desktop"
            case .done: return "Ready"
            }
        }
    }

    enum Download: Equatable {
        case idle
        case running(received: Int64, total: Int64?, rate: Double?)
        case paused
        case failed(String)
        case done
    }

    @Published var step: Step {
        didSet { UserDefaults.standard.set(step.rawValue, forKey: Self.stepKey) }
    }
    @Published var speech: Download = Tools.modelInstalled ? .done : .idle
    @Published var provider: NotesProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: Keys.notesProvider)
            refreshProvider()
        }
    }
    @Published var providerCheck: ProviderCheck = .checking
    @Published var busy: String?             // what's being installed or signed in to right now
    @Published var busyProgress: Double?
    @Published var actionError: String?
    @Published var signInURL: URL?
    @Published var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var systemAudioAsked = UserDefaults.standard.bool(forKey: systemAudioKey)
    @Published var completed = UserDefaults.standard.bool(forKey: completedKey) {
        didSet { UserDefaults.standard.set(completed, forKey: Self.completedKey) }
    }

    private var speechTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?

    private init() {
        let saved = Step(rawValue: UserDefaults.standard.integer(forKey: Self.stepKey)) ?? .welcome
        step = saved == .speech && Tools.modelBundled ? .notes : saved
        provider = NotesProvider.saved(UserDefaults.standard.string(forKey: Keys.notesProvider))
    }

    var appPath: String { Bundle.main.bundlePath }

    /// The steps to show: no download step when the app carries the speech model.
    var steps: [Step] { Step.allCases.filter { $0 != .speech || !Tools.modelBundled } }
    func next() { step = steps.first { $0.rawValue > step.rawValue } ?? .done }
    func back() { step = steps.last { $0.rawValue < step.rawValue } ?? .welcome }
    var needsMove: Bool { AppLocation.needsMove(appPath) }

    func isDone(_ s: Step) -> Bool {
        switch s {
        case .welcome: return !needsMove
        case .speech: return speech == .done
        case .notes: return providerCheck == .ready
        case .permissions: return mic == .authorized && systemAudioAsked
        case .claudeDesktop, .done: return false
        }
    }

    // MARK: Speech model

    static let whisperURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
    static let vadURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!
    static let modelBytes: Int64 = 1_624_555_275

    func startSpeechDownload() {
        guard speechTask == nil else { return }
        if Tools.modelInstalled && FileManager.default.fileExists(atPath: Tools.vadModel.path) {
            speech = .done
            return
        }
        let part = DownloadLogic.partURL(Tools.downloadedModel)
        let have = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        if !Tools.modelInstalled, let free = Self.freeSpace(), free < Self.modelBytes - have + 200_000_000 {
            speech = .failed("Your Mac needs about \(Self.bytes(Self.modelBytes - have + 200_000_000)) of free space for the speech model, and has \(Self.bytes(free)). Free up some space, then press Try again.")
            return
        }
        speech = .running(received: have, total: nil, rate: nil)
        speechTask = Task { [weak self] in
            await self?.runSpeechDownload()
            self?.speechTask = nil
        }
    }

    func pauseSpeechDownload() {
        speechTask?.cancel()
    }

    private func runSpeechDownload() async {
        var attempt = 0
        while true {
            do {
                if !Tools.modelInstalled {
                    rateSamples = []
                    try await FileDownloader().download(Self.whisperURL, to: Tools.downloadedModel, minimumSize: 100_000_000) { received, total in
                        Task { @MainActor [weak self] in self?.speechProgress(received, total) }
                    }
                }
                // Voice activity detection (under 1 MB): skips silence so whisper doesn't invent phrases.
                // Optional, so a failure here doesn't block setup.
                if !FileManager.default.fileExists(atPath: Tools.vadModel.path) {
                    try? await FileDownloader().download(Self.vadURL, to: Tools.downloadedVADModel, minimumSize: 100_000) { _, _ in }
                }
                speech = .done
                AppModel.shared.objectWillChange.send()   // the "speech model missing" banner
                return
            } catch is CancellationError {
                speech = .paused
                return
            } catch {
                attempt += 1
                // Retry network hiccups on its own a few times; each try continues where the last stopped.
                if attempt <= 3 {
                    try? await Task.sleep(for: .seconds(Double(attempt * attempt) * 2))
                    if Task.isCancelled { speech = .paused; return }
                    continue
                }
                speech = .failed(error.localizedDescription)
                return
            }
        }
    }

    private var rateSamples: [(Date, Int64)] = []

    private func speechProgress(_ received: Int64, _ total: Int64?) {
        guard case .running = speech else { return }
        let now = Date()
        rateSamples.append((now, received))
        rateSamples.removeAll { now.timeIntervalSince($0.0) > 10 }
        var rate: Double?
        if let first = rateSamples.first, now.timeIntervalSince(first.0) > 2 {
            rate = Double(received - first.1) / now.timeIntervalSince(first.0)
        }
        speech = .running(received: received, total: total ?? Self.modelBytes, rate: rate)
    }

    static func freeSpace() -> Int64? {
        let dir = Tools.dataDir.deletingLastPathComponent()
        let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    // MARK: Notes provider

    func refreshProvider() {
        checkTask?.cancel()
        providerCheck = .checking
        let p = provider
        checkTask = Task { [weak self] in
            let result = await ProviderSetup.check(p)
            guard !Task.isCancelled, let self, self.provider == p else { return }
            self.providerCheck = result
        }
    }

    private func perform(_ label: String, _ work: @escaping @MainActor () async throws -> Void) {
        guard actionTask == nil else { return }
        busy = label
        busyProgress = nil
        actionError = nil
        actionTask = Task { [weak self] in
            do {
                try await work()
            } catch is CancellationError {
            } catch {
                self?.actionError = error.localizedDescription
            }
            self?.busy = nil
            self?.busyProgress = nil
            self?.actionTask = nil
            self?.refreshProvider()
        }
    }

    func cancelAction() {
        actionTask?.cancel()
    }

    func installClaude() {
        perform("Installing Claude Code… (about a minute)") {
            let r = await runProcess("/bin/bash", ["-c", ProviderSetup.claudeInstaller])
            guard Tools.claude != nil else {
                throw PipelineError(message: "Claude Code couldn't be installed automatically. \(String(r.err.suffix(300)))".trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    func installCodex() {
        perform("Downloading Codex…") { [weak self] in
            let (url, binary) = ProviderSetup.codexArchive
            let fm = FileManager.default
            let downloads = Tools.dataDir.appendingPathComponent("downloads")
            let archive = downloads.appendingPathComponent("\(binary).tar.gz")
            try await FileDownloader().download(url, to: archive, minimumSize: 1_000_000) { received, total in
                Task { @MainActor in
                    if let total, total > 0 { self?.busyProgress = Double(received) / Double(total) }
                }
            }
            let unpack = downloads.appendingPathComponent("codex-\(UUID().uuidString)")
            try fm.createDirectory(at: unpack, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: unpack); try? fm.removeItem(at: archive) }
            let r = await runProcess("/usr/bin/tar", ["-xzf", archive.path, "-C", unpack.path])
            let exe = unpack.appendingPathComponent(binary)
            guard r.status == 0, fm.fileExists(atPath: exe.path) else {
                throw PipelineError(message: "The Codex download couldn't be unpacked. \(r.err)")
            }
            let bin = URL(fileURLWithPath: Tools.home).appendingPathComponent(".local/bin")
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            let dest = bin.appendingPathComponent("codex")
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: exe, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
    }

    /// Runs the provider's own sign-in in the background: it opens the browser and waits for the
    /// sign-in to finish, while the check here notices when it has.
    func signIn() {
        let p = provider
        guard let exe = p.executable else { return }
        let args = p == .claude ? ["auth", "login"] : ["login"]
        signInURL = nil
        perform("Waiting for you to sign in in your browser…") { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = args
            process.environment = Tools.environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let text = String(decoding: handle.availableData, as: UTF8.self)
                if let url = ProviderSetup.firstURL(in: text) {
                    Task { @MainActor in if self?.signInURL == nil { self?.signInURL = url } }
                }
            }
            try process.run()
            defer {
                pipe.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
            }
            // Up to 10 minutes; stops early once signed in or when the command ends.
            for _ in 0..<300 {
                try await Task.sleep(for: .seconds(2))
                if await ProviderSetup.check(p) == .ready { return }
                if !process.isRunning {
                    if await ProviderSetup.check(p) == .ready { return }
                    throw PipelineError(message: "Signing in didn't finish. Try again, or use \"Sign in using Terminal\".")
                }
            }
            throw PipelineError(message: "Signing in took too long. Try again.")
        }
    }

    func signInWithTerminal() {
        guard let exe = provider.executable else { return }
        ProviderSetup.openInTerminal(provider == .claude ? "'\(exe)' auth login" : "'\(exe)' login")
    }

    func openOllama() {
        perform("Starting Ollama…") {
            let app = URL(fileURLWithPath: "/Applications/Ollama.app")
            if FileManager.default.fileExists(atPath: app.path) {
                _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            } else if let exe = Tools.find("ollama", inBundle: false) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = ["serve"]
                p.environment = Tools.environment
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
            }
            for _ in 0..<20 {
                try await Task.sleep(for: .seconds(1))
                if await Ollama.status(model: Ollama.model, base: Ollama.baseURL) != .notRunning { return }
            }
            throw PipelineError(message: "Ollama didn't start. Open the Ollama app yourself, then press Check again.")
        }
    }

    func pullOllamaModel() {
        let model = Ollama.model
        perform("Downloading the local model \(model)…") { [weak self] in
            try await Ollama.pull(model: model, base: Ollama.baseURL) { status, fraction in
                Task { @MainActor in
                    self?.busy = "Downloading the local model \(model): \(status)"
                    if let fraction { self?.busyProgress = fraction }
                }
            }
        }
    }

    /// For a copy of the app without the built-in model (built from source): download it to ~/.meetnotes.
    func downloadBuiltInModel() {
        perform("Downloading \(BuiltIn.modelLabel) (\(Self.bytes(BuiltIn.modelBytes)))…") { [weak self] in
            try await FileDownloader().download(BuiltIn.modelURL, to: BuiltIn.downloadedModel, minimumSize: BuiltIn.modelBytes) { received, total in
                Task { @MainActor in
                    if let total, total > 0 { self?.busyProgress = Double(received) / Double(total) }
                }
            }
        }
    }

    // MARK: Permissions

    func refreshPermissions() {
        mic = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestMic() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refreshPermissions()
        }
    }

    /// Starts system audio capture for a moment, which makes macOS ask for System Audio Recording.
    /// macOS doesn't tell apps whether it was allowed, so this only records that it was asked.
    func requestSystemAudio() {
        Task {
            let queue = DispatchQueue(label: "se.frinkle.meetingnotes.setup-probe")
            let tap = try? SystemAudioTap(queue: queue) { _, _ in }
            try? await Task.sleep(for: .seconds(2))
            tap?.stop()
            systemAudioAsked = true
            UserDefaults.standard.set(true, forKey: Self.systemAudioKey)
        }
    }

    static func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Claude Desktop

    static var claudeDesktop: URL? {
        ["/Applications/Claude.app", "\(Tools.home)/Applications/Claude.app"]
            .map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func addToClaudeDesktop() {
        let ext = Tools.mcpExtension
        guard FileManager.default.fileExists(atPath: ext.path) else {
            actionError = "The Claude Desktop extension isn't included in this copy of Meeting Notes."
            return
        }
        if let app = Self.claudeDesktop {
            NSWorkspace.shared.open([ext], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(ext)
        }
    }

    // MARK: Launch

    /// On launch: open setup until it has been finished once. Installs that already work (for example
    /// built with install.sh before setup existed) are marked finished without showing it.
    func launchCheck(open: @escaping () -> Void) {
        guard !completed else { return }
        Task {
            // Not for the built-in model: it is ready in every new install, which should still see setup once
            // (permissions, moving the app out of the disk image).
            if provider != .builtin, Tools.modelInstalled, Tools.whisper != nil, await ProviderSetup.check(provider) == .ready {
                completed = true
                return
            }
            open()
        }
    }
}

// MARK: Window

struct SetupView: View {
    @StateObject private var setup = SetupModel.shared
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    page.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer.padding(16)
            }
        }
        .frame(width: 760, height: 560)
        .onAppear {
            setup.refreshProvider()
            setup.refreshPermissions()
            if !Tools.modelInstalled, setup.speech == .idle { setup.startSpeechDownload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings, the browser or an installer.
            setup.refreshPermissions()
            if setup.busy == nil { setup.refreshProvider() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Set up Meeting Notes").font(.headline).padding(.bottom, 10)
            ForEach(setup.steps) { s in
                Button { setup.step = s } label: {
                    HStack(spacing: 8) {
                        Image(systemName: setup.isDone(s) ? "checkmark.circle.fill" : (s == setup.step ? "circle.inset.filled" : "circle"))
                            .foregroundStyle(setup.isDone(s) ? Color.green : (s == setup.step ? Color.accentColor : Color.secondary))
                        Text(s.title).fontWeight(s == setup.step ? .semibold : .regular)
                        Spacer()
                    }
                    .padding(.vertical, 5).padding(.horizontal, 8)
                    .background(s == setup.step ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if case .running(let received, let total, _) = setup.speech, setup.step != .speech {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Downloading speech model").font(.caption)
                    ProgressView(value: total.map { Double(received) / Double(max($0, 1)) } ?? 0)
                }
            }
        }
        .padding(16)
        .frame(width: 200)
        .background(.background.secondary)
    }

    @ViewBuilder private var page: some View {
        switch setup.step {
        case .welcome: WelcomePage(setup: setup)
        case .speech: SpeechPage(setup: setup)
        case .notes: NotesPage(setup: setup)
        case .permissions: PermissionsPage(setup: setup)
        case .claudeDesktop: ClaudeDesktopPage(setup: setup)
        case .done: DonePage(setup: setup)
        }
    }

    private var footer: some View {
        HStack {
            if setup.step != .welcome {
                Button("Back") { setup.back() }
            }
            Spacer()
            if setup.step == .done {
                Button("Start using Meeting Notes") {
                    setup.completed = true
                    setup.step = .welcome
                    AppModel.shared.openMainWindow?()
                    dismissWindow(id: "setup")
                }
                .keyboardShortcut(.defaultAction)
            } else {
                if !setup.isDone(setup.step) && setup.step != .welcome && setup.step != .claudeDesktop {
                    Text("You can do this later from Settings.").font(.caption).foregroundStyle(.secondary)
                }
                Button(setup.isDone(setup.step) || setup.step == .welcome ? "Continue" : "Skip for now") {
                    setup.next()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: Pages

private struct PageHeader: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2).bold()
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 18)
    }
}

private struct StatusLine: View {
    let ok: Bool?
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch ok {
            case .some(true): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .some(false): Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .none: ProgressView().controlSize(.small)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomePage: View {
    @ObservedObject var setup: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Welcome to Meeting Notes",
                       text: "Meeting Notes listens to your video calls, writes down what was said on your Mac, and turns it into tidy notes with a summary, decisions and action items.")
            Label("Recordings and transcripts stay on your Mac.", systemImage: "lock")
            Label("It notices when a call starts and offers to take notes.", systemImage: "phone")
            Label("A few steps, about five minutes, plus a download that runs in the background.", systemImage: "clock")
            if setup.needsMove {
                VStack(alignment: .leading, spacing: 8) {
                    StatusLine(ok: false, text: "Meeting Notes is running from the download, not from your Applications folder.")
                    Text("Quit Meeting Notes, drag it from the download window into Applications (or another folder on your Mac), and open it from there. Otherwise some parts (like Claude Desktop) can't find it later.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open Applications folder") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications")) }
                        Button("Quit Meeting Notes") { NSApp.terminate(nil) }
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct SpeechPage: View {
    @ObservedObject var setup: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Download the speech model",
                       text: "Meeting Notes turns speech into text on your Mac with a speech model. It's a one-time download of about 1.6 GB, and it keeps going while you do the next steps.")
            switch setup.speech {
            case .done:
                StatusLine(ok: true, text: "The speech model is ready.")
            case .idle:
                Button("Download (1.6 GB)") { setup.startSpeechDownload() }
            case .running(let received, let total, let rate):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: total.map { Double(received) / Double(max($0, 1)) } ?? 0)
                    HStack {
                        Text(progressText(received, total, rate)).font(.callout).monospacedDigit()
                        Spacer()
                        Button("Pause") { setup.pauseSpeechDownload() }
                    }
                }
            case .paused:
                StatusLine(ok: false, text: "Paused. It continues where it stopped.")
                Button("Resume download") { setup.startSpeechDownload() }
            case .failed(let message):
                StatusLine(ok: false, text: message)
                Button("Try again") { setup.startSpeechDownload() }
                Text("If it keeps failing, check your internet connection. What's already downloaded is kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func progressText(_ received: Int64, _ total: Int64?, _ rate: Double?) -> String {
        var s = SetupModel.bytes(received)
        if let total { s += " of \(SetupModel.bytes(total))" }
        if let rate, rate > 0, let total {
            let left = Double(total - received) / rate
            s += left > 90 ? " · about \(Int(left / 60) + 1) min left" : " · less than 2 min left"
        }
        return s
    }
}

private struct NotesPage: View {
    @ObservedObject var setup: SetupModel

    private func blurb(_ p: NotesProvider) -> String {
        switch p {
        case .builtin: return "Ready now: free and private, no account, nothing leaves your Mac. Comes with Meeting Notes and needs 8 GB of memory. Simpler notes than Claude's."
        case .claude: return "Needs a paid Claude plan (Pro or Max). The text of the conversation is sent to Anthropic to write the notes; audio stays on your Mac. Best notes."
        case .codex: return "Needs a ChatGPT plan that includes Codex (Plus or higher). The text is sent to OpenAI to write the notes; audio stays on your Mac."
        case .ollama: return "Free and private: runs a bigger model of your choice in Ollama. Needs a recent Mac with 16 GB of memory or more and an 8 GB download."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Choose how notes are written",
                       text: "After a call, an AI writes the notes from the transcript. The built-in model works right away; the others are optional. You can change it later in Settings.")
            ForEach(NotesProvider.allCases, id: \.self) { p in
                Button { setup.provider = p } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: setup.provider == p ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(setup.provider == p ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.label).fontWeight(.semibold)
                            Text(blurb(p)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(setup.provider == p ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(setup.busy != nil)
            }
            Divider().padding(.vertical, 4)
            status
            if let busy = setup.busy {
                VStack(alignment: .leading, spacing: 6) {
                    if let p = setup.busyProgress { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
                    HStack {
                        Text(busy).font(.callout)
                        Spacer()
                        Button("Cancel") { setup.cancelAction() }
                    }
                    if let url = setup.signInURL {
                        Link("Browser didn't open? Open the sign-in page", destination: url).font(.callout)
                    }
                }
            }
            if let error = setup.actionError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var status: some View {
        let name = setup.provider.label
        VStack(alignment: .leading, spacing: 10) {
            switch setup.providerCheck {
            case .checking:
                StatusLine(ok: nil, text: "Checking \(name)…")
            case .ready:
                switch setup.provider {
                case .builtin: StatusLine(ok: true, text: "\(BuiltIn.modelLabel) is ready. Nothing else to set up.")
                case .ollama: StatusLine(ok: true, text: "Ollama and the local model \(Ollama.model) are ready.")
                default: StatusLine(ok: true, text: "\(name) is installed and signed in.")
                }
            case .notInstalled where setup.provider == .builtin:
                StatusLine(ok: false, text: "This copy of Meeting Notes doesn't include the built-in notes engine. Download Meeting Notes from the Releases page, or run `brew install llama.cpp` if you built it from source.")
                actions
            case .modelMissing where setup.provider == .builtin:
                StatusLine(ok: false, text: "This copy of Meeting Notes doesn't include the built-in model. Download \(BuiltIn.modelLabel) (\(SetupModel.bytes(BuiltIn.modelBytes)), once).")
                actions
            case .notInstalled:
                StatusLine(ok: false, text: "\(name) isn't installed on this Mac yet.")
                actions
            case .signedOut:
                StatusLine(ok: false, text: "\(name) is installed. Now sign in with your account.")
                actions
            case .unknown(let text):
                StatusLine(ok: false, text: text)
                actions
            case .notRunning:
                StatusLine(ok: false, text: "Ollama is installed but not running.")
                actions
            case .modelMissing:
                StatusLine(ok: false, text: "Ollama is running. Now download the local model \(Ollama.model) (about 8 GB).")
                actions
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack {
            switch (setup.provider, setup.providerCheck) {
            case (.builtin, .modelMissing):
                Button("Download the model") { setup.downloadBuiltInModel() }
            case (.builtin, _):
                EmptyView()
            case (.claude, .notInstalled):
                Button("Install Claude Code") { setup.installClaude() }
                Button("Download page") { NSWorkspace.shared.open(ProviderSetup.claudeDownloadPage) }
            case (.codex, .notInstalled):
                Button("Install Codex") { setup.installCodex() }
                Button("Download page") { NSWorkspace.shared.open(ProviderSetup.codexDownloadPage) }
            case (.claude, _), (.codex, _):
                Button("Sign in") { setup.signIn() }
                Button("Sign in using Terminal") { setup.signInWithTerminal() }
            case (.ollama, .notInstalled):
                Button("Download Ollama") { NSWorkspace.shared.open(ProviderSetup.ollamaDownloadPage) }
            case (.ollama, .notRunning):
                Button("Open Ollama") { setup.openOllama() }
            case (.ollama, _):
                Button("Download the model") { setup.pullOllamaModel() }
            }
            Button("Check again") { setup.refreshProvider() }
        }
        .disabled(setup.busy != nil)
        if setup.provider == .ollama && setup.providerCheck == .notInstalled {
            Text("Open the downloaded file and move Ollama to Applications, open it once, then come back and press Check again.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PermissionsPage: View {
    @ObservedObject var setup: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Allow Meeting Notes to listen",
                       text: "To write down a call, Meeting Notes needs to hear you (the microphone) and the other people (the sound your Mac plays). It only records while a meeting is being noted. Your screen is never recorded.")
            VStack(alignment: .leading, spacing: 8) {
                switch setup.mic {
                case .authorized:
                    StatusLine(ok: true, text: "Microphone: allowed")
                case .notDetermined:
                    StatusLine(ok: false, text: "Microphone: not allowed yet")
                    Button("Allow microphone") { setup.requestMic() }
                default:
                    StatusLine(ok: false, text: "Microphone: turned off for Meeting Notes")
                    Text("Turn on Meeting Notes in System Settings > Privacy & Security > Microphone.").font(.callout).foregroundStyle(.secondary)
                    Button("Open System Settings") { SetupModel.openPrivacy("Privacy_Microphone") }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                StatusLine(ok: setup.systemAudioAsked ? true : false,
                           text: setup.systemAudioAsked ? "System audio: asked" : "System audio: not asked yet")
                Text("When macOS asks, click Allow. To check or change it later, see System Settings > Privacy & Security > Screen & System Audio Recording, under \"System Audio Recording Only\".")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(setup.systemAudioAsked ? "Ask again" : "Allow system audio") { setup.requestSystemAudio() }
                    Button("Open System Settings") { SetupModel.openPrivacy("Privacy_AudioCapture") }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Optional: notifications, so Meeting Notes can offer to take notes when a call starts and tell you when notes are ready.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                NotificationRow()
            }
        }
    }
}

private struct ClaudeDesktopPage: View {
    @ObservedObject var setup: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Ask Claude about your meetings (optional)",
                       text: "If you use the Claude Desktop app, Meeting Notes can let Claude read your notes and transcripts, so you can ask things like \"what did we decide about the budget last week?\". Claude can only read, never change or delete, and never hears the audio.")
            if SetupModel.claudeDesktop != nil {
                Button("Add to Claude Desktop") { setup.addToClaudeDesktop() }
                Text("Claude Desktop opens and asks you to confirm. Click Install.").font(.callout).foregroundStyle(.secondary)
            } else {
                StatusLine(ok: false, text: "Claude Desktop isn't installed.")
                HStack {
                    Button("Get Claude Desktop") { NSWorkspace.shared.open(ProviderSetup.claudeDesktopPage) }
                    Button("Add to Claude Desktop") { setup.addToClaudeDesktop() }
                }
                Text("Install Claude Desktop first, then come back and press Add to Claude Desktop. Or skip this; it can be done later in Settings.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if setup.needsMove {
                StatusLine(ok: false, text: "Move Meeting Notes to Applications first (see Welcome), so Claude can find it.")
            }
            if let error = setup.actionError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
    }
}

private struct DonePage: View {
    @ObservedObject var setup: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let pending = setup.steps.filter { [.welcome, .speech, .notes, .permissions].contains($0) && !setup.isDone($0) }
            PageHeader(title: pending.isEmpty ? "You're all set" : "Almost there",
                       text: "Join a video call (Zoom, Teams, Meet, Slack…) and Meeting Notes offers to take notes. Or click the waveform icon in the menu bar and choose Start meeting notes. When the call ends, the notes appear in the Meeting Notes window.")
            ForEach(pending) { s in
                Button { setup.step = s } label: {
                    StatusLine(ok: false, text: "\(s.title) isn't finished. Click to go back to it.")
                }
                .buttonStyle(.plain)
            }
            if case .running = setup.speech {
                Text("The speech model is still downloading. You can close this window; it keeps going.").font(.callout).foregroundStyle(.secondary)
            }
            Text("You can open this setup again any time from Settings.").font(.callout).foregroundStyle(.secondary)
        }
    }
}
