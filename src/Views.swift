import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

// MARK: Main window

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    @State private var pendingTrash: Meeting?

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.meetings) { m in
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
            .overlay {
                if model.meetings.isEmpty {
                    ContentUnavailableView(
                        "No meetings yet",
                        systemImage: "waveform",
                        description: Text("Press Start when a call begins, or just join a call and Meeting Notes will offer to take notes.")
                    )
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 290)
        } detail: {
            if let m = model.meetings.first(where: { $0.id == model.selection }) {
                MeetingDetail(meeting: m).id(m.id)
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

    @State private var title = ""
    @State private var tab = 0
    @State private var notes = ""
    @State private var transcript = ""
    @State private var confirmTrash = false
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

            Divider()

            ScrollView {
                let text = tab == 0 ? notes : transcript
                Group {
                    if text.isEmpty {
                        Text(placeholder).foregroundStyle(.secondary)
                    } else {
                        MarkdownView(text: text)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .textSelection(.enabled)
            }
        }
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
                        .disabled(meeting.isBusy)
                    Divider()
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
        .task(id: meeting) {
            title = meeting.title
            notes = readBody("notes.md")
            transcript = readBody("transcript.md")
        }
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
                    Text("Recording. Press stop when the call ends, or it stops by itself when the call app releases the mic.")
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
struct MarkdownView: View {
    let text: String

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
    }

    @ViewBuilder private func lineView(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let indent = CGFloat(raw.prefix(while: { $0 == " " }).count / 2) * 18
        if line.isEmpty {
            Color.clear.frame(height: 2)
        } else if line.hasPrefix("### ") {
            Text(inline(String(line.dropFirst(4)))).font(.headline).padding(.top, 6)
        } else if line.hasPrefix("## ") {
            Text(inline(String(line.dropFirst(3)))).font(.title3.weight(.semibold)).padding(.top, 12)
        } else if line.hasPrefix("# ") {
            Text(inline(String(line.dropFirst(2)))).font(.title2.weight(.bold)).padding(.top, 12)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            let item = String(line.dropFirst(2))
            let task = item.hasPrefix("[ ] ") ? "☐" : (item.lowercased().hasPrefix("[x] ") ? "☑" : nil)   // task lists
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(task ?? "•").foregroundStyle(.secondary)
                Text(inline(task == nil ? item : String(item.dropFirst(4))))
            }
            .padding(.leading, indent)
        } else {
            Text(inline(line)).padding(.leading, indent)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
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
                    if provider == .claude {
                        TextField("Claude executable (optional)", text: $claudePath)
                    } else {
                        TextField("Codex executable (optional)", text: $codexPath)
                    }
                    Text(provider.loginHint).font(.caption).foregroundStyle(.secondary)
                    Text("The text transcript is sent to the selected provider. Audio stays on your Mac.")
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
                    check("\(provider.label) installed", provider.executable != nil)
                    HStack {
                        Button("Microphone permission…") { openPrivacy("Privacy_Microphone") }
                        Button("Screen & System Audio permission…") { openPrivacy("Privacy_ScreenCapture") }
                    }
                    NotificationRow()
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

