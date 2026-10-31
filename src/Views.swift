import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

// MARK: Main window

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    @State private var pendingTrash: Meeting?
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let shown = model.meetings(matching: query)
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(shown) { m in
                    MeetingRow(meeting: m).tag(m.id)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.folder]) }
                            Button("Move to Trash…", role: .destructive) { pendingTrash = m }
                                .disabled(m.status == "recording")
                        }
                }
            }
            .onDeleteCommand {
                if let m = model.meetings.first(where: { $0.id == model.selection }), m.status != "recording" {
                    pendingTrash = m
                }
            }
            .confirmationDialog("Move \"\(pendingTrash?.title ?? "")\" to the Trash?",
                                isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })) {
                Button("Move to Trash", role: .destructive) {
                    if let m = pendingTrash { model.trash(m) }
                    pendingTrash = nil
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search meetings")
            .searchFocused($searchFocused)
            .onChange(of: model.searchRequest) { _, _ in searchFocused = true }
            .overlay {
                if model.meetings.isEmpty {
                    ContentUnavailableView(
                        "No meetings yet",
                        systemImage: "waveform",
                        description: Text("Press Start when a call begins, or just join a call and Meeting Notes will offer to take notes.")
                    )
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 290)
        } detail: {
            if let m = model.meetings.first(where: { $0.id == model.selection }) {
                MeetingDetail(meeting: m, search: query).id(m.id)
            } else {
                ContentUnavailableView("Select a meeting", systemImage: "doc.text")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { RecordControl() }
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { Banners() }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
        .frame(minWidth: 760, minHeight: 480)
    }
}

struct RecordControl: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let r = model.recording {
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                TimelineView(.periodic(from: r.start, by: 1)) { ctx in
                    Text(formatDuration(ctx.date.timeIntervalSince(r.start))).monospacedDigit()
                }
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .tint(.red)
            }
        } else {
            Button { model.start() } label: {
                Label(model.starting ? "Starting…" : "Start meeting", systemImage: "record.circle")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(model.starting)
        }
    }
}

struct Banners: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let msg = model.banner {
                BannerRow(text: msg, color: .orange) { model.banner = nil }
            }
            if !Tools.modelInstalled {
                BannerRow(text: "The speech model is missing. Run the installer again.", color: .red, onClose: nil)
            }
        }
    }
}

struct BannerRow: View {
    let text: String
    let color: Color
    let onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
            Text(text).textSelection(.enabled)
            Spacer()
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(color.opacity(0.12))
    }
}

// MARK: Sidebar

struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.created, format: .dateTime.day().month(.abbreviated).hour().minute())
                if let d = meeting.meta.duration { Text("· \(formatDuration(d))") }
                Spacer()
                if meeting.isArchived && meeting.status == "done" {
                    Image(systemName: "archivebox").help("Audio archived")
                }
                StatusBadge(status: meeting.status)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct StatusBadge: View {
    let status: String

    var body: some View {
        switch status {
        case "recording":
            Label("Recording", systemImage: "record.circle").foregroundStyle(Color.red)
        case "transcribing":
            Label("Transcribing", systemImage: "waveform")
        case "summarizing":
            Label("Writing notes", systemImage: "sparkles")
        case "failed":
            Label("Failed", systemImage: "exclamationmark.triangle").foregroundStyle(Color.orange)
        default:
            EmptyView()
        }
    }
}

// MARK: Detail

struct MeetingDetail: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting
    var search = ""   // the sidebar search, which opens the find bar when the meeting is opened

    @State private var title = ""
    @State private var tab = 0
    @State private var finding = false
    @State private var find = ""
    @State private var current = 0   // index of the selected match
    @State private var matches: [MarkdownView.Match] = []
    @FocusState private var findFocused: Bool
    @State private var notes = ""
    @State private var transcript = ""
    @State private var confirmTrash = false
    @State private var confirmArchive = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .onSubmit { model.rename(meeting, to: title) }
                HStack(spacing: 6) {
                    Text(meeting.created, format: .dateTime.weekday(.wide).day().month().year().hour().minute())
                    if let d = meeting.meta.duration { Text("· \(formatDuration(d))") }
                    if let app = meeting.meta.app { Text("· \(app)") }
                    if meeting.isArchived {
                        Text("·")
                        Label("Audio archived", systemImage: "archivebox")
                            .help("The audio files were deleted, so the transcript can't be redone.")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            statusSection

            HStack {
                Picker("", selection: $tab) {
                    Text("Notes").tag(0)
                    Text("Transcript").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                Spacer()
                let text = tab == 0 ? notes : transcript
                Button {
                    copy(text)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : (tab == 0 ? "Copy notes" : "Copy transcript"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(text.isEmpty)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy to the clipboard (⇧⌘C)")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            if finding { findBar }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    let text = tab == 0 ? notes : transcript
                    Group {
                        if text.isEmpty {
                            Text(placeholder).foregroundStyle(.secondary)
                        } else {
                            MarkdownView(text: text, highlight: finding ? find : "", current: currentMatch)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .textSelection(.enabled)
                }
                .onChange(of: currentMatch) { _, m in
                    if let m { withAnimation { proxy.scrollTo(m.line, anchor: .center) } }
                }
            }
        }
        .onChange(of: model.findRequest) { _, _ in
            finding = true
            findFocused = true
        }
        .onChange(of: find) { _, _ in refreshMatches() }
        .onChange(of: tab) { _, _ in refreshMatches() }
        .onChange(of: finding) { _, _ in refreshMatches() }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Copy notes") { copy(notes) }.disabled(notes.isEmpty)
                    Button("Copy transcript") { copy(transcript) }.disabled(transcript.isEmpty)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([meeting.folder]) }
                    Divider()
                    Button("Regenerate notes") { model.retry(meeting, notesOnly: true) }
                        .disabled(meeting.isBusy || transcript.isEmpty)
                    Button("Redo transcript and notes") { model.retry(meeting, notesOnly: false) }
                        .disabled(meeting.isBusy || meeting.isArchived)
                    Divider()
                    Button("Archive audio files…") { confirmArchive = true }
                        .disabled(meeting.isBusy || !meeting.hasAudio)
                    Button("Move to Trash…", role: .destructive) { confirmTrash = true }
                        .disabled(meeting.status == "recording")
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Move \"\(meeting.title)\" to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { model.trash(meeting) }
        }
        .confirmationDialog("Archive the audio for \"\(meeting.title)\"?", isPresented: $confirmArchive) {
            Button("Delete audio files", role: .destructive) { model.archiveAudio(meeting) }
        } message: {
            Text("The recordings are deleted for good. The notes and transcript are kept, but the transcript can no longer be redone.")
        }
        .task(id: meeting) {
            title = meeting.title
            notes = readBody("notes.md")
            transcript = readBody("transcript.md")
            refreshMatches()
        }
        .onAppear {
            let q = search.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty {
                find = q
                finding = true
                // Show the tab where the search matched.
                let n = readBody("notes.md"), t = readBody("transcript.md")
                if MarkdownView.matches(of: q, in: n).isEmpty, !MarkdownView.matches(of: q, in: t).isEmpty { tab = 1 }
            }
        }
    }

    private func refreshMatches() {
        current = 0
        matches = finding ? MarkdownView.matches(of: find, in: tab == 0 ? notes : transcript) : []
    }

    private var currentMatch: MarkdownView.Match? {
        let all = matches
        return all.isEmpty ? nil : all[min(current, all.count - 1)]
    }

    private func step(_ delta: Int) {
        let n = matches.count
        guard n > 0 else { return }
        current = ((min(current, n - 1) + delta) % n + n) % n
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(tab == 0 ? "Find in notes" : "Find in transcript", text: $find)
                .textFieldStyle(.roundedBorder)
                .focused($findFocused)
                .onSubmit { step(1) }
                .onExitCommand { finding = false }
                .frame(maxWidth: 280)
            let n = matches.count
            if !find.isEmpty {
                Text(n == 0 ? "No matches" : "\(min(current, n - 1) + 1) of \(n)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Previous match (⇧⌘G)")
                .disabled(n == 0)
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .keyboardShortcut("g")
                .help("Next match (⌘G or Return)")
                .disabled(n == 0)
            Spacer()
            Button("Done") { finding = false }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var placeholder: String {
        switch meeting.status {
        case "recording": return "Notes appear here after the meeting."
        case "transcribing", "summarizing": return "Working on it…"
        default: return tab == 0 ? "No notes yet." : "No transcript yet."
        }
    }

    @ViewBuilder private var statusSection: some View {
        switch meeting.status {
        case "recording":
            StatusBox {
                HStack {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                    Text(model.recording?.micOnly == true
                         ? "Recording your microphone only (the call audio couldn't be captured). Press stop when the call ends."
                         : "Recording. Press stop when the call ends, or it stops by itself when the call app releases the mic.")
                    Spacer()
                    Button("Stop and take notes") { model.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            }
        case "transcribing":
            StatusBox {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing on your Mac. Roughly a minute per 10 minutes of call.")
                }
            }
        case "summarizing":
            StatusBox {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Writing the notes…")
                }
            }
        case "failed":
            StatusBox {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                    Text(meeting.meta.error ?? "Something went wrong.").textSelection(.enabled)
                    Spacer()
                    Button("Retry") { model.retry(meeting, notesOnly: !transcript.isEmpty) }
                }
            }
        default:
            EmptyView()
        }
    }

    private func readBody(_ file: String) -> String {
        guard let text = try? String(contentsOf: meeting.folder.appendingPathComponent(file), encoding: .utf8) else { return "" }
        // The first line is the "# Title" heading, which the header already shows.
        if text.hasPrefix("# "), let nl = text.firstIndex(of: "\n") {
            return String(text[text.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct StatusBox<Content: View>: View {
    let content: Content

    init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
    }
}

/// Small Markdown renderer for headings, bullets and inline formatting.
/// Find-in-note highlights matches of `highlight`, with `current` (line and occurrence) stronger.
struct MarkdownView: View {
    let text: String
    var highlight = ""
    var current: Match?

    struct Match: Equatable {
        let line: Int    // line number, also the scroll id
        let index: Int   // occurrence within the line
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { n, line in
                lineView(line, number: n)
            }
        }
    }

    @ViewBuilder private func lineView(_ raw: String, number: Int) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let indent = CGFloat(raw.prefix(while: { $0 == " " }).count / 2) * 18
        let content = Self.content(line)
        let text = highlighted(Self.inline(content.text), line: number)
        if line.isEmpty {
            Color.clear.frame(height: 2)
        } else if line.hasPrefix("### ") {
            Text(text).font(.headline).padding(.top, 6)
        } else if line.hasPrefix("## ") {
            Text(text).font(.title3.weight(.semibold)).padding(.top, 12)
        } else if line.hasPrefix("# ") {
            Text(text).font(.title2.weight(.bold)).padding(.top, 12)
        } else if let bullet = content.bullet {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bullet).foregroundStyle(.secondary)
                Text(text)
            }
            .padding(.leading, indent)
        } else {
            Text(text).padding(.leading, indent)
        }
    }

    /// The text shown for a (trimmed) line without its heading or list marker, and the bullet to show.
    static func content(_ line: String) -> (text: String, bullet: String?) {
        for prefix in ["### ", "## ", "# "] where line.hasPrefix(prefix) {
            return (String(line.dropFirst(prefix.count)), nil)
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            let item = String(line.dropFirst(2))
            let task = item.hasPrefix("[ ] ") ? "☐" : (item.lowercased().hasPrefix("[x] ") ? "☑" : nil)   // task lists
            return (task == nil ? item : String(item.dropFirst(4)), task ?? "•")
        }
        return (line, nil)
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    /// All matches of the query in the rendered text (Markdown markers like ** don't count).
    static func matches(of query: String, in text: String) -> [Match] {
        guard !query.isEmpty else { return [] }
        var result: [Match] = []
        for (n, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let shown = String(inline(content(line).text).characters)
            for i in TextSearch.ranges(of: query, in: shown).indices { result.append(Match(line: n, index: i)) }
        }
        return result
    }

    private func highlighted(_ s: AttributedString, line: Int) -> AttributedString {
        guard !highlight.isEmpty else { return s }
        let plain = String(s.characters)
        let found = TextSearch.ranges(of: highlight, in: plain)
        guard !found.isEmpty else { return s }
        var out = s
        for (i, r) in found.enumerated() {
            let lower = plain.distance(from: plain.startIndex, to: r.lowerBound)
            let length = plain.distance(from: r.lowerBound, to: r.upperBound)
            let start = out.index(out.startIndex, offsetByCharacters: lower)
            let end = out.index(start, offsetByCharacters: length)
            let isCurrent = current == Match(line: line, index: i)
            out[start..<end].backgroundColor = isCurrent ? Color.orange : Color.yellow.opacity(0.45)
        }
        return out
    }
}

// MARK: Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage(Keys.myName) private var myName = "Me"
    @AppStorage(Keys.language) private var language = "auto"
    @AppStorage(Keys.autoDetect) private var autoDetect = true
    @AppStorage(Keys.autoStart) private var autoStart = false
    @AppStorage(Keys.autoStop) private var autoStop = true
    @AppStorage(Keys.promptStyle) private var promptStyle = "notification"
    @AppStorage(Keys.keepAudio) private var keepAudio = true
    @AppStorage(Keys.outputDir) private var outputDir = ""
    @AppStorage(Keys.notesProvider) private var notesProvider = NotesProvider.claude.rawValue
    @AppStorage(Keys.claudePath) private var claudePath = ""
    @AppStorage(Keys.codexPath) private var codexPath = ""
    @AppStorage(Keys.ollamaModel) private var ollamaModel = Ollama.defaultModel
    @AppStorage(Keys.ollamaURL) private var ollamaURL = Ollama.defaultURL
    @State private var ollamaStatus = Ollama.Status.checking
    @AppStorage(Keys.notesInstructions) private var instructions = Pipeline.defaultInstructions

    private var provider: NotesProvider { NotesProvider(rawValue: notesProvider) ?? .claude }

    @State private var ignored: [String] = UserDefaults.standard.stringArray(forKey: Keys.ignoredApps) ?? []
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("You") {
                    TextField("Your name in notes", text: $myName)
                    Picker("Meeting language", selection: $language) {
                        Text("Detect automatically").tag("auto")
                        Text("Svenska").tag("sv")
                        Text("Dansk").tag("da")
                        Text("English").tag("en")
                    }
                }
                Section("Notes") {
                    Picker("Write notes with", selection: $notesProvider) {
                        ForEach(NotesProvider.allCases, id: \.rawValue) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    switch provider {
                    case .claude:
                        TextField("Claude executable (optional)", text: $claudePath)
                    case .codex:
                        TextField("Codex executable (optional)", text: $codexPath)
                    case .ollama:
                        TextField("Model", text: $ollamaModel)
                        TextField("Ollama address", text: $ollamaURL)
                    }
                    Text(provider.loginHint).font(.caption).foregroundStyle(.secondary)
                    Text(provider == .ollama
                         ? "The notes are written on your Mac by the local model. Nothing leaves the Mac (unless the address points to another computer)."
                         : "The text transcript is sent to the selected provider. Audio stays on your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("How the notes should look")
                        TextEditor(text: $instructions)
                            .font(.system(.callout, design: .monospaced))
                            .frame(height: 170)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                        HStack(alignment: .top) {
                            Text("Sections, length, style or language. Your name, who is who and the meeting title are added automatically. Headings, bullets and bold are shown nicely; tables aren't. Use Regenerate notes to apply changes to an existing meeting.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Reset to default") { instructions = Pipeline.defaultInstructions }
                                .disabled(instructions == Pipeline.defaultInstructions)
                        }
                    }
                }
                Section("Automatic") {
                    Toggle("Detect calls when an app starts using the microphone", isOn: $autoDetect)
                    Toggle("Start recording without asking", isOn: $autoStart)
                        .disabled(!autoDetect)
                    Picker("Ask with", selection: $promptStyle) {
                        Text("A notification").tag("notification")
                        Text("A floating panel").tag("panel")
                    }
                    .disabled(!autoDetect || autoStart)
                    if promptStyle == "notification" {
                        Text("Uses the floating panel instead while notifications aren't allowed (see Setup). Set Meeting Notes to Alerts in System Settings > Notifications to keep it on screen until you answer.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Stop automatically when the call ends", isOn: $autoStop)
                    Toggle("Start at login and run in the background", isOn: $openAtLogin)
                        .onChange(of: openAtLogin) { _, on in setLogin(on) }
                    ForEach(ignored, id: \.self) { key in
                        HStack {
                            Text("Never detect \(key)").foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove") {
                                ignored.removeAll { $0 == key }
                                UserDefaults.standard.set(ignored, forKey: Keys.ignoredApps)
                            }
                        }
                    }
                }
                Section("Storage") {
                    HStack {
                        Text("Folder")
                        Spacer()
                        Text(outputDir).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                    }
                    Toggle("Keep audio recordings", isOn: $keepAudio)
                }
                Section("Setup") {
                    check("Whisper (transcription on your Mac)", Tools.whisper != nil)
                    check("Speech model", Tools.modelInstalled)
                    if provider == .ollama {
                        ollamaCheck
                    } else {
                        check("\(provider.label) installed", provider.executable != nil)
                    }
                    HStack {
                        Button("Microphone permission…") { openPrivacy("Privacy_Microphone") }
                        Button("System Audio permission…") { openPrivacy("Privacy_AudioCapture") }
                    }
                    NotificationRow()
                    MCPRow()
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 720)
        .onChange(of: outputDir) { _, _ in model.reload() }
        .task(id: "\(notesProvider) \(ollamaModel) \(ollamaURL)") {
            guard provider == .ollama else { return }
            ollamaStatus = .checking
            try? await Task.sleep(for: .milliseconds(400))   // wait for typing to pause
            guard !Task.isCancelled else { return }
            ollamaStatus = await Ollama.status(model: Ollama.model, base: Ollama.baseURL)
        }
    }

    @ViewBuilder private var ollamaCheck: some View {
        switch ollamaStatus {
        case .checking:
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking Ollama…")
            }
        case .ready:
            check("Local model \(Ollama.model) ready", true)
        case .notRunning, .modelMissing:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    check(ollamaStatus == .notRunning ? "Ollama not running" : "Model \(Ollama.model) not downloaded", false)
                    Spacer()
                    Button("Check again") {
                        Task { ollamaStatus = await Ollama.status(model: Ollama.model, base: Ollama.baseURL) }
                    }
                }
                Text(ollamaStatus == .notRunning
                     ? Ollama.notRunningMessage(Ollama.baseURL)
                     : Ollama.missingModelMessage(Ollama.model))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func check(_ label: String, _ ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.red)
            Text(label)
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            model.banner = "Couldn't change the login setting: \(error.localizedDescription)"
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use folder"
        if panel.runModal() == .OK, let url = panel.url {
            outputDir = url.path
        }
    }

    private func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Connects the read-only MCP server to Claude Desktop (extension), Claude Code and other MCP clients.
struct MCPRow: View {
    @State private var copied: String?

    private var path: String { Tools.mcpServer.path }
    private var config: String {
        """
        {
          "mcpServers": {
            "meeting-notes": {
              "command": "\(path)"
            }
          }
        }
        """
    }

    var body: some View {
        let installed = FileManager.default.isExecutableFile(atPath: path)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(installed ? Color.green : Color.red)
                Text("Ask AI apps about your meetings (MCP server)")
                Spacer()
                Button("Add to Claude Desktop") { NSWorkspace.shared.open(Tools.mcpExtension) }
                    .disabled(!installed || !FileManager.default.fileExists(atPath: Tools.mcpExtension.path))
                    .help("Opens the Meeting Notes extension in Claude Desktop, which asks you to install it")
                Menu(copied.map { "Copied \($0)" } ?? "Other apps") {
                    Button("Claude Code command") { copy("claude mcp add --scope user meeting-notes -- \(path)", "Claude Code") }
                    Button("Codex command") { copy("codex mcp add meeting-notes -- \(path)", "Codex") }
                    Button("VS Code command") {
                        copy("code --add-mcp '{\"name\":\"meeting-notes\",\"command\":\"\(path)\"}'", "VS Code")
                    }
                    Button("JSON config (Cursor, LM Studio, others)") { copy(config, "JSON") }
                    Button("Server path") { copy(path, "path") }
                }
                .fixedSize()
                .disabled(!installed)
            }
            Text(installed ? "AI apps can then list, search and read your notes and transcripts. Never audio, and they can't change anything. Commands go in Terminal; the JSON goes in the app's MCP settings."
                           : "Run bash install.sh again to install the MCP server.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func copy(_ text: String, _ what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = what
    }
}

/// Notification permission state, with buttons to allow, open System Settings or send a test.
struct NotificationRow: View {
    @State private var status: UNAuthorizationStatus?
    @AppStorage(Notifier.errorKey) private var lastError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(allowed ? Color.green : Color.red)
                Text(allowed ? "Notifications" : "Notifications (fallback via Script Editor)")
                Spacer()
                if status == .notDetermined {
                    Button("Allow…") { Notifier.shared.requestPermission { _ in Task { @MainActor in refresh() } } }
                } else if !allowed {
                    Button("Open Settings…") {
                        let id = Bundle.main.bundleIdentifier ?? ""
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Button("Send test") {
                    Notifier.shared.post(title: "Meeting Notes", body: "Notifications are working.", folder: nil)
                    Task { try? await Task.sleep(for: .seconds(1)); refresh() }
                }
            }
            if !allowed, !lastError.isEmpty {
                Text("macOS said: \(lastError). Notes-ready alerts are sent through Script Editor instead (allow Script Editor in System Settings > Notifications if they don't appear) and calls are offered with the floating panel. Signing the app with a certificate fixes this; see the README.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { refresh() }
    }

    private var allowed: Bool { status == .authorized || status == .provisional }

    private func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let st = s.authorizationStatus
            Task { @MainActor in status = st }
        }
    }
}

// MARK: Meeting detected popup

struct PromptView: View {
    let appName: String
    let meetingName: String?
    let onStart: () -> Void
    let onDismiss: () -> Void
    let onNever: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meetingName ?? "Meeting detected").font(.headline).lineLimit(1)
                    Text("\(appName) is using the microphone").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Start notes", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("Not now", action: onDismiss)
                Spacer()
                Button("Never for \(appName)", action: onNever)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

@MainActor
final class PromptPanel {
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(appName: String, meetingName: String?, onStart: @escaping () -> Void, onDismiss: @escaping () -> Void, onNever: @escaping () -> Void) {
        hide()
        let host = NSHostingView(rootView: PromptView(appName: appName, meetingName: meetingName, onStart: onStart, onDismiss: onDismiss, onNever: onNever))
        let size = host.fittingSize
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            p.standardWindowButton(button)?.isHidden = true
        }
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.maxX - p.frame.width - 16, y: screen.maxY - p.frame.height - 16))
        }
        p.orderFrontRegardless()
        NSSound(named: "Glass")?.play()
        panel = p
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

