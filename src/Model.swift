import Foundation
import AppKit
import AVFoundation
import UserNotifications

// MARK: Settings

enum Keys {
    static let myName = "myName"
    static let language = "language"
    static let autoDetect = "autoDetect"
    static let autoStart = "autoStart"
    static let autoStop = "autoStop"
    static let keepAudio = "keepAudio"
    static let outputDir = "outputDir"
    static let ignoredApps = "ignoredApps"
    static let claudePath = "claudePath"
    static let codexPath = "codexPath"
    static let notesProvider = "notesProvider"
    static let notesInstructions = "notesInstructions"
    static let promptStyle = "promptStyle"     // "notification" or "panel"
}

func registerDefaults() {
    // New menu bar items are added at the far left, which on a Mac with a notch is often hidden behind it.
    // Start next to the system icons instead; macOS updates this when the user Command-drags the icon.
    let position = "NSStatusItem Preferred Position Item-0"
    if UserDefaults.standard.object(forKey: position) == nil {
        UserDefaults.standard.set(300.0, forKey: position)
    }
    let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me"
    UserDefaults.standard.register(defaults: [
        Keys.notesProvider: NotesProvider.claude.rawValue,
        Keys.myName: first,
        Keys.language: "auto",
        Keys.autoDetect: true,
        Keys.autoStart: false,
        Keys.autoStop: true,
        Keys.keepAudio: true,
        Keys.outputDir: (NSHomeDirectory() as NSString).appendingPathComponent("Documents/Meetings"),
        Keys.ignoredApps: [String](),
        Keys.promptStyle: "notification",
    ])
}

struct SettingsSnapshot {
    let myName: String
    let language: String
    let keepAudio: Bool
    let notesProvider: NotesProvider

    static func current() -> SettingsSnapshot {
        let d = UserDefaults.standard
        return SettingsSnapshot(
            myName: d.string(forKey: Keys.myName) ?? "Me",
            language: d.string(forKey: Keys.language) ?? "auto",
            keepAudio: d.bool(forKey: Keys.keepAudio),
            notesProvider: NotesProvider(rawValue: d.string(forKey: Keys.notesProvider) ?? "") ?? .claude
        )
    }
}

func formatDuration(_ seconds: Double) -> String {
    let t = max(0, Int(seconds))
    if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) }
    return String(format: "%d:%02d", t / 60, t % 60)
}

// MARK: Search

enum TextSearch {
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// True when every word of the query appears somewhere in the text (in any order).
    static func matches(_ query: String, in text: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { text.range(of: $0, options: options) != nil }
    }

    /// Every occurrence of the query in the text, for find-in-note highlighting.
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex, let r = text.range(of: query, options: options, range: from..<text.endIndex) {
            result.append(r)
            from = r.upperBound
        }
        return result
    }
}

// MARK: Storage

struct Meta: Codable, Hashable {
    var title: String
    var created: Date?
    var status: String?      // recording, transcribing, summarizing, done, failed
    var error: String?
    var app: String?
    var lang: String?
    var offsets: [String: Double]?
    var duration: Double?
    var audioArchived: Date?   // when the audio files were deleted with "Archive audio files"
}

struct Meeting: Identifiable, Hashable {
    let folder: URL
    var meta: Meta
    var created: Date
    var status: String
    var hasAudio = false

    var id: String { folder.path }
    var title: String { meta.title }
    var isBusy: Bool { ["recording", "transcribing", "summarizing"].contains(status) }
    /// The audio is gone (archived, or not kept), so the transcript can't be redone.
    var isArchived: Bool { !hasAudio && !isBusy }
}

enum Store {
    static var root: URL {
        let path = UserDefaults.standard.string(forKey: Keys.outputDir) ?? "~/Documents/Meetings"
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static func readMeta(_ folder: URL) -> Meta? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(Meta.self, from: data)
    }

    static func writeMeta(_ meta: Meta, to folder: URL) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? e.encode(meta) {
            try? data.write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
        }
    }

    static func update(_ folder: URL, _ change: (inout Meta) -> Void) {
        var m = readMeta(folder) ?? Meta(title: folder.lastPathComponent)
        change(&m)
        writeMeta(m, to: folder)
    }

    static func loadAll() -> [Meeting] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        let meetings: [Meeting] = dirs.compactMap { dir in
            guard let meta = readMeta(dir) else { return nil }
            let created = meta.created
                ?? (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                ?? .distantPast
            var status = meta.status ?? ""
            if status.isEmpty {
                status = fm.fileExists(atPath: dir.appendingPathComponent("notes.md").path) ? "done" : "failed"
            }
            return Meeting(folder: dir, meta: meta, created: created, status: status, hasAudio: !audioFiles(dir).isEmpty)
        }
        return meetings.sorted { $0.created > $1.created }
    }

    /// The meeting's recordings (me/others as .caf while recording, .wav after transcription).
    static func audioFiles(_ folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["caf", "wav"].contains($0.pathExtension.lowercased()) }
    }

    /// Deletes the recordings but keeps the transcript, notes and meta.json.
    static func archiveAudio(_ folder: URL) {
        for f in audioFiles(folder) { try? FileManager.default.removeItem(at: f) }
        update(folder) { $0.audioArchived = Date() }
    }

    /// Ends a recording segment when capture has to restart mid-meeting: renames its tracks to me-N/others-N
    /// so the next segment can write me/others again, and returns their offsets from the meeting start.
    static func closeSegment(_ folder: URL, number: Int, offsets: [String: Double], start: Double) -> [String: Double] {
        var result: [String: Double] = [:]
        for (track, offset) in offsets {
            let name = "\(track)-\(number)"
            do {
                try FileManager.default.moveItem(at: folder.appendingPathComponent("\(track).caf"),
                                                 to: folder.appendingPathComponent("\(name).caf"))
                result[name] = start + offset
            } catch {
                NSLog("MeetingNotes: couldn't keep segment \(name): \(error)")
            }
        }
        return result
    }

    static func newFolder(title: String, date: Date) throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = f.string(from: date)
        var safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined()
        safe = safe.trimmingCharacters(in: .whitespaces)
        if safe.isEmpty { safe = "Meeting" }
        var url = root.appendingPathComponent("\(stamp) \(safe)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(stamp) \(safe) \(n)")
            n += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: App state

struct ActiveRecording {
    let folder: URL
    var title: String
    let start: Date
    var triggerKey: String?
    var lastSeen: Date       // last time the call app had the mic open
    var lastAudio: Date      // last time it had the mic open or was playing sound
    var stopsAt: Date?       // set while the call looks over and auto-stop is counting down
    var segments = 0         // earlier segments, when capture failed and was restarted mid-meeting
    var segmentStart = 0.0   // seconds from `start` to the current segment
    var micOnly = false      // recording only the microphone because system audio capture failed
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var meetings: [Meeting] = []
    @Published var selection: String?
    @Published var recording: ActiveRecording?
    @Published var starting = false
    @Published var banner: String?
    @Published var findRequest = 0     // bumped by Edit > Find (⌘F) to open the find bar in the open meeting
    @Published var searchRequest = 0   // bumped by Edit > Search Meetings (⌥⌘F) to focus the sidebar search
    var openMainWindow: (() -> Void)?   // set by the menu bar label, which has SwiftUI's openWindow
    @Published var now = Date()   // ticks every second while recording, for the menu bar clock

    private var recorder: AudioCapture?
    private var switching = false        // replacing a failed capture; stop() waits for it
    private var stopAfterSwitch = false
    private var timer: Timer?
    private var clock: Timer?
    private let prompt = PromptPanel()
    private var candidate: MicUser?
    private var candidateSince = Date()
    private var dismissedKey: String?
    private var promptUser: MicUser?   // the call being asked about (panel or notification)
    private var names: [String: String?] = [:]   // meeting name per call app key, from its call tab
    private var searchCache: [String: String] = [:]   // title, notes and transcript per meeting, for the sidebar search

    func launch() {
        Notifier.shared.setUp()
        markInterrupted()
        reload()
        if selection == nil { selection = meetings.first?.id }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if let self, self.recording != nil { self.now = Date() }
            }
        }
        Task {
            // Ask for permissions up front so the prompts don't appear in the middle of a call.
            // System Audio Recording is asked for by macOS when the first recording starts.
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    func reload() {
        meetings = Store.loadAll()
        searchCache = [:]
    }

    /// Meetings whose title, notes or transcript contain every word of the query.
    func meetings(matching query: String) -> [Meeting] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return meetings }
        return meetings.filter { m in
            let text = searchCache[m.id] ?? {
                let body = ["notes.md", "transcript.md"].compactMap {
                    try? String(contentsOf: m.folder.appendingPathComponent($0), encoding: .utf8)
                }
                let t = ([m.title] + body).joined(separator: "\n")
                searchCache[m.id] = t
                return t
            }()
            return TextSearch.matches(q, in: text)
        }
    }

    private func markInterrupted() {
        for m in Store.loadAll() where m.isBusy {
            Store.update(m.folder) {
                $0.status = "failed"
                $0.error = "Interrupted because the app was closed. Press Retry."
            }
        }
    }

    // MARK: Recording

    func start(title: String? = nil, trigger: MicUser? = nil) {
        guard recording == nil, !starting else { return }
        starting = true
        hidePrompt()
        // Don't offer or auto-start again for this app until it releases the mic
        // (prevents a retry loop if starting fails, e.g. missing permission).
        if let k = trigger?.key { dismissedKey = k }
        Task {
            defer { starting = false }
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                banner = "Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone."
                return
            }
            let now = Date()
            // The meeting name is looked up when the call is detected, so starting isn't delayed.
            let callName = trigger.flatMap { names[$0.key] ?? nil }
            let name = title ?? callName ?? trigger.map { "\($0.name) call" } ?? "Meeting"
            let folder: URL
            do {
                folder = try Store.newFolder(title: name, date: now)
            } catch {
                banner = "Couldn't create the meeting folder: \(error.localizedDescription)"
                return
            }
            Store.writeMeta(
                Meta(title: name, created: now, status: "recording", app: trigger?.name,
                     lang: SettingsSnapshot.current().language),
                to: folder
            )
            let rec = makeRecorder(folder)
            var micOnly = false
            do {
                try await rec.start()
                recorder = rec
            } catch {
                // The other people's audio can't be captured: record the microphone alone rather than nothing.
                guard let mic = startMicOnly(folder) else {
                    try? FileManager.default.removeItem(at: folder)
                    banner = "Couldn't start recording (\(error.localizedDescription)). Check that Meeting Notes is allowed under System Settings > Privacy & Security > Microphone."
                    reload()
                    return
                }
                recorder = mic
                micOnly = true
                banner = "Recording only your microphone, because the call audio couldn't be captured (\(error.localizedDescription)). To record the other people too, allow Meeting Notes under System Settings > Privacy & Security > Screen & System Audio Recording > System Audio Recording Only."
            }
            recording = ActiveRecording(folder: folder, title: name, start: now,
                                        triggerKey: trigger?.key, lastSeen: now, lastAudio: now, micOnly: micOnly)
            reload()
            selection = folder.path
            // Not looked up yet (e.g. auto-start): fill in the meeting name when it arrives.
            if title == nil, callName == nil, let t = trigger, let n = await CallInfo.meetingName(for: t),
               recording?.folder == folder {
                Store.update(folder) { $0.title = n }
                recording?.title = n
                reload()
            }
        }
    }

    func stop() {
        guard let active = recording else { return }
        if switching {
            stopAfterSwitch = true
            return
        }
        let rec = recorder
        recorder = nil
        recording = nil
        // If the call app still has the mic (manual stop), don't immediately prompt/auto-start again.
        if let k = active.triggerKey { dismissedKey = k }
        Task {
            let offsets = await finishSegment(rec, active)
            Store.update(active.folder) {
                $0.offsets = offsets
                $0.duration = Date().timeIntervalSince(active.start)
                $0.status = "transcribing"
            }
            reload()
            await Pipeline.run(folder: active.folder) { [weak self] in self?.reload() }
            notifyFinished(active.folder)
        }
    }

    func stopForQuit() async {
        guard let active = recording else { return }
        let rec = recorder
        recorder = nil
        recording = nil
        let offsets = await finishSegment(rec, active)
        Store.update(active.folder) {
            $0.offsets = offsets
            $0.duration = Date().timeIntervalSince(active.start)
            $0.status = "failed"
            $0.error = "The app was closed before the notes were written. Press Retry."
        }
    }

    private func makeRecorder(_ folder: URL) -> Recorder {
        let rec = Recorder(folder: folder)
        rec.onError = { [weak self, weak rec] message in
            Task { @MainActor in self?.recordingFailed(message, from: rec) }
        }
        return rec
    }

    private func startMicOnly(_ folder: URL) -> MicRecorder? {
        guard let mic = try? MicRecorder(folder: folder), (try? mic.start()) != nil else { return nil }
        return mic
    }

    /// Stops the current capture and returns the offsets of every track recorded in this meeting.
    private func finishSegment(_ rec: AudioCapture?, _ active: ActiveRecording) async -> [String: Double] {
        let current = await rec?.stop() ?? [:]
        let earlier = Store.readMeta(active.folder)?.offsets ?? [:]
        return earlier.merging(current.mapValues { $0 + active.segmentStart }) { $1 }
    }

    /// Capture stopped mid-meeting (e.g. the microphone couldn't be restarted after an input device change). Keep what was recorded as a segment and carry on: with full capture again if it
    /// starts, otherwise with the microphone alone. Only if neither works does the recording stop.
    private func recordingFailed(_ message: String, from failed: Recorder?) {
        guard let failed, recorder === failed, let active = recording, !switching else { return }
        NSLog("MeetingNotes: capture stopped: \(message)")
        switching = true
        Task {
            let offsets = await failed.stop()
            let number = active.segments + 1
            let kept = Store.closeSegment(active.folder, number: number, offsets: offsets, start: active.segmentStart)
            Store.update(active.folder) { $0.offsets = ($0.offsets ?? [:]).merging(kept) { $1 } }
            let segmentStart = Date().timeIntervalSince(active.start)
            // Try full capture again, unless it only just failed (then it would likely keep failing).
            let next = makeRecorder(active.folder)
            if segmentStart - active.segmentStart > 30, (try? await next.start()) != nil {
                recorder = next
            } else if let mic = startMicOnly(active.folder) {
                recorder = mic
                recording?.micOnly = true
                banner = "The call audio stopped being captured (\(message)). Recording continues with only your microphone."
            } else {
                recorder = nil
                banner = "Recording stopped: \(message)"
                stopAfterSwitch = true
            }
            recording?.segments = number
            recording?.segmentStart = segmentStart
            switching = false
            if stopAfterSwitch {
                stopAfterSwitch = false
                stop()
            }
        }
    }

    /// Shows the call prompt with sample text (used for the README screenshots).
    func showDemoPrompt() {
        prompt.show(appName: "Google Chrome", meetingName: "Product roadmap Q1",
                    onStart: { [weak self] in self?.prompt.hide() },
                    onDismiss: { [weak self] in self?.prompt.hide() },
                    onNever: { [weak self] in self?.prompt.hide() })
    }

    private func notifyFinished(_ folder: URL) {
        guard let meta = Store.readMeta(folder) else { return }
        if meta.status == "done" {
            Notifier.shared.post(title: "Notes ready: \(meta.title)",
                                 body: Notifier.summary(folder) ?? "Your meeting notes are ready.", folder: folder)
        } else if meta.status == "failed" {
            Notifier.shared.post(title: "Couldn't finish \(meta.title)",
                                 body: meta.error ?? "Open Meeting Notes and press Retry.", folder: folder)
        }
    }

    // MARK: Meeting actions

    func retry(_ m: Meeting, notesOnly: Bool) {
        Store.update(m.folder) {
            $0.status = notesOnly ? "summarizing" : "transcribing"
            $0.error = nil
        }
        reload()
        Task {
            await Pipeline.run(folder: m.folder, notesOnly: notesOnly) { [weak self] in self?.reload() }
            notifyFinished(m.folder)
        }
    }

    func rename(_ m: Meeting, to newTitle: String) {
        let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != m.title else { return }
        Store.update(m.folder) { $0.title = t }
        reload()
    }

    func archiveAudio(_ m: Meeting) {
        guard !m.isBusy else { return }
        Store.archiveAudio(m.folder)
        reload()
    }

    func trash(_ m: Meeting) {
        try? FileManager.default.trashItem(at: m.folder, resultingItemURL: nil)
        if selection == m.id { selection = nil }
        reload()
    }

    // MARK: Meeting detection

    private func tick() {
        let d = UserDefaults.standard
        guard d.string(forKey: "captureScreenshots") == nil else { return }   // keep the demo prompt up for screenshots
        let ignored = Set(d.stringArray(forKey: Keys.ignoredApps) ?? [])
        let users = MicMonitor.users().filter { !$0.isSystem && !ignored.contains($0.key) }
        let now = Date()

        if var active = recording {
            guard d.bool(forKey: Keys.autoStop) else { return }
            if active.triggerKey == nil, let u = users.first { active.triggerKey = u.key }
            guard let key = active.triggerKey else { return }
            // Stop 5 s after the call app goes quiet (mic closed and no sound playing). Sound playing keeps it
            // going for apps that close the mic on mute, but at most 60 s, so a call app left open still stops.
            if users.contains(where: { $0.key == key }) {
                active.lastSeen = now
                active.lastAudio = now
            } else if MicMonitor.users(orPlaying: true).contains(where: { $0.key == key }) {
                active.lastAudio = now
            }
            let stopAt = min(active.lastAudio.addingTimeInterval(5), active.lastSeen.addingTimeInterval(60))
            if now >= stopAt {
                stop()
                return
            }
            active.stopsAt = now.timeIntervalSince(active.lastSeen) > 3 ? stopAt : nil
            recording = active
            return
        }

        guard d.bool(forKey: Keys.autoDetect), !starting else {
            hidePrompt()
            return
        }
        guard let u = users.first else {
            candidate = nil
            dismissedKey = nil
            hidePrompt()
            return
        }
        if let k = dismissedKey, !users.contains(where: { $0.key == k }) { dismissedKey = nil }
        if let p = promptUser, !users.contains(where: { $0.key == p.key }) { hidePrompt() }
        if candidate?.key != u.key {
            candidate = u
            candidateSince = now
            names[u.key] = nil
            Task { names[u.key] = .some(await CallInfo.meetingName(for: u)) }
            return
        }
        guard u.key != dismissedKey, now.timeIntervalSince(candidateSince) >= 4, promptUser == nil else { return }

        if d.bool(forKey: Keys.autoStart) {
            start(trigger: u)
        } else {
            showPrompt(u)
        }
    }

    // MARK: Call prompt

    /// Asks with a notification when allowed (and chosen in Settings), otherwise with the floating panel.
    private func showPrompt(_ u: MicUser) {
        promptUser = u
        let meetingName = names[u.key] ?? nil
        guard UserDefaults.standard.string(forKey: Keys.promptStyle) != "panel" else {
            showPanel(u, meetingName: meetingName)
            return
        }
        Notifier.shared.postCallPrompt(appName: u.name, meetingName: meetingName, key: u.key) { [weak self] ok in
            Task { @MainActor in
                // Not allowed (e.g. ad hoc signed build): a Script Editor notification can't start a recording.
                if !ok, let self, self.promptUser?.key == u.key { self.showPanel(u, meetingName: meetingName) }
            }
        }
    }

    private func showPanel(_ u: MicUser, meetingName: String?) {
        prompt.show(
            appName: u.name,
            meetingName: meetingName,
            onStart: { [weak self] in self?.promptAction(.start, key: u.key) },
            onDismiss: { [weak self] in self?.promptAction(.notNow, key: u.key) },
            onNever: { [weak self] in self?.promptAction(.never, key: u.key) }
        )
    }

    private func hidePrompt() {
        prompt.hide()
        if promptUser != nil { Notifier.shared.removeCallPrompt() }
        promptUser = nil
    }

    enum PromptAction { case start, notNow, never }

    /// Answer from the panel or the notification. Ignored if that call is no longer being asked about.
    func promptAction(_ action: PromptAction, key: String) {
        guard let u = promptUser, u.key == key else { return }
        switch action {
        case .start:
            start(trigger: u)
        case .notNow:
            dismissedKey = u.key
            hidePrompt()
        case .never:
            var list = UserDefaults.standard.stringArray(forKey: Keys.ignoredApps) ?? []
            if !list.contains(u.key) { list.append(u.key) }
            UserDefaults.standard.set(list, forKey: Keys.ignoredApps)
            hidePrompt()
        }
    }
}

// MARK: Notifications

/// "Notes ready" notifications (clicking one opens the window on that meeting) and the "Meeting detected" prompt.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    static let callCategory = "callDetected"
    static let callPromptID = "callDetected"   // one fixed id, so a new prompt replaces the old one
    static let startAction = "start"
    static let notNowAction = "notNow"
    static let neverAction = "never"

    /// Last notification error, shown in Settings (UserDefaults, so it survives relaunches).
    static let errorKey = "notificationError"

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Notifier.callCategory,
            actions: [
                UNNotificationAction(identifier: Notifier.startAction, title: "Start notes"),
                UNNotificationAction(identifier: Notifier.notNowAction, title: "Not now"),
                UNNotificationAction(identifier: Notifier.neverAction, title: "Never for this app", options: .destructive),
            ],
            intentIdentifiers: [],
            options: .customDismissAction   // clearing it counts as "Not now"
        )])
        requestPermission { _ in }
        removeCallPrompt()   // left over from a previous run
    }

    /// Posts the "Meeting detected" notification. `done(false)` when notifications aren't allowed.
    func postCallPrompt(appName: String, meetingName: String?, key: String, done: @escaping @Sendable (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                done(false)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = meetingName ?? "Meeting detected"
            content.body = "\(appName) is using the microphone. Start notes?"
            content.sound = UNNotificationSound(named: UNNotificationSoundName("Glass"))
            content.categoryIdentifier = Notifier.callCategory
            content.userInfo = ["callKey": key]
            let request = UNNotificationRequest(identifier: Notifier.callPromptID, content: content, trigger: nil)
            center.add(request) { error in
                if let error { NSLog("MeetingNotes: call notification error: \(error)") }
                done(error == nil)
            }
        }
    }

    func removeCallPrompt() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Notifier.callPromptID])
        center.removePendingNotificationRequests(withIdentifiers: [Notifier.callPromptID])
    }

    func requestPermission(_ done: @escaping @Sendable (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, error in
            Notifier.record(error)
            done(ok)
        }
    }

    func post(title: String, body: String, folder: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let folder { content.userInfo = ["folder": folder.path] }
        let request = UNNotificationRequest(identifier: folder?.path ?? UUID().uuidString, content: content, trigger: nil)
        // Ask again if needed (e.g. the first request at launch was missed), then post.
        requestPermission { _ in
            UNUserNotificationCenter.current().add(request) { error in
                Notifier.record(error)
                // macOS refuses notification permission for ad-hoc signed apps, so fall back to an
                // AppleScript notification (shown by Script Editor; clicking it doesn't open the meeting).
                if error != nil { Task { await Notifier.scriptNotification(title: title, body: body) } }
            }
        }
    }

    static func scriptNotification(title: String, body: String) async {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        _ = await runProcess("/usr/bin/osascript", ["-e",
            "display notification \(quoted(body)) with title \(quoted(title)) sound name \"Glass\""])
    }

    private static func record(_ error: Error?) {
        if let error {
            NSLog("MeetingNotes: notification error: \(error)")
            UserDefaults.standard.set(error.localizedDescription, forKey: errorKey)
        } else {
            UserDefaults.standard.removeObject(forKey: errorKey)
        }
    }

    /// First paragraph of the notes (the summary), shortened for the notification.
    static func summary(_ folder: URL) -> String? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8) else { return nil }
        let line = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
        guard var line else { return nil }
        if line.hasPrefix("- ") || line.hasPrefix("* ") { line.removeFirst(2) }
        return line.count > 180 ? String(line.prefix(179)) + "…" : line
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let key = info["callKey"] as? String {
            let action: AppModel.PromptAction? = switch response.actionIdentifier {
            case Notifier.startAction, UNNotificationDefaultActionIdentifier: .start   // clicking it starts too
            case Notifier.notNowAction, UNNotificationDismissActionIdentifier: .notNow
            case Notifier.neverAction: .never
            default: nil
            }
            Task { @MainActor in if let action { AppModel.shared.promptAction(action, key: key) } }
            completionHandler()
            return
        }
        let path = response.notification.request.content.userInfo["folder"] as? String
        Task { @MainActor in
            let model = AppModel.shared
            model.reload()
            if let path { model.selection = path }
            model.openMainWindow?()
        }
        completionHandler()
    }
}
