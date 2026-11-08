import MeetingCore
import SwiftUI
import UIKit

enum Keys {
    static let name = "myName"
    static let language = "language"
    static let keepAudio = "keepAudio"
    static let notesInstructions = "notesInstructions"
    static let notesEngine = "notesEngine"
    static let onboarded = "onboarded"
}

@MainActor
@Observable
final class AppModel {
    var meetings: [Meeting] = []
    /// The meeting being recorded.
    private(set) var recorder: Recorder?
    /// What's happening to each meeting being processed, by meeting id.
    private(set) var progress: [String: String] = [:]
    var alert: String?
    /// The text of each meeting's notes and transcript, for search.
    private var searchText: [String: [String]] = [:]

    let store: MeetingStore

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        store = MeetingStore(root: docs)
        UserDefaults.standard.register(defaults: [Keys.keepAudio: false, Keys.language: MeetingLanguage.automatic.rawValue])
        if ProcessInfo.processInfo.arguments.contains("-demo") { DemoData.seed(in: store) }
        recoverInterrupted()
        reload()
        DispatchQueue.global(qos: .utility).async { ModelStore.removeDownloadedCopiesOfBundled() }
        // Device testing: process the newest meeting without notes (only the notes when it has a transcript).
        if Benchmark.enabled, let m = meetings.first(where: { MeetingStore.readBody($0.folder, MeetingStore.notesFile).isEmpty }) {
            process(m.folder, notesOnly: !MeetingStore.readBody(m.folder, MeetingStore.transcriptFile).isEmpty)
        }
    }

    var isRecording: Bool { recorder != nil }

    func reload() {
        meetings = store.loadAll()
        searchText = Dictionary(uniqueKeysWithValues: meetings.map { m in
            (m.id, [m.title, MeetingStore.readBody(m.folder, MeetingStore.notesFile), MeetingStore.readBody(m.folder, MeetingStore.transcriptFile)])
        })
    }

    func filtered(_ query: String) -> [Meeting] {
        meetings.filter { matches(query, in: searchText[$0.id] ?? [$0.title]) }
    }

    func meeting(id: String) -> Meeting? { meetings.first { $0.id == id } }

    /// A meeting left "recording" or "transcribing" means the app was closed or killed meanwhile.
    /// Its audio is safe on disk (CAF), so offer to carry on.
    private func recoverInterrupted() {
        for m in store.loadAll() where m.isBusy {
            MeetingStore.update(m.folder) {
                $0.status = "failed"
                $0.error = m.status == "recording"
                    ? "The recording stopped when the app closed. The audio up to that point is saved: tap Make transcript."
                    : "The app closed before this was finished. Tap Try again."
            }
        }
    }

    // MARK: Recording

    func startRecording(language: MeetingLanguage) async {
        guard recorder == nil else { return }
        guard await Recorder.requestPermission() else { alert = RecorderError.noPermission.localizedDescription; return }
        do {
            let now = Date()
            let folder = try store.newFolder(title: "Meeting", date: now)
            MeetingStore.writeMeta(Meta(title: "Meeting", created: now, status: "recording",
                                        lang: language == .automatic ? nil : language.rawValue), to: folder)
            let r = Recorder(folder: folder)
            r.onChange = { [weak self] in self?.recorderChanged() }
            try r.begin()
            recorder = r
            UIApplication.shared.isIdleTimerDisabled = true
            reload()
        } catch {
            alert = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    /// Bumped to redraw the recording screen when the recorder pauses or resumes.
    private(set) var recorderState = 0
    private func recorderChanged() { recorderState += 1 }

    func resumeRecording() {
        do { try recorder?.resume() } catch { alert = "Couldn't resume recording: \(error.localizedDescription)" }
    }

    func stopRecording() {
        guard let r = recorder else { return }
        let offsets = r.finish()
        recorder = nil
        UIApplication.shared.isIdleTimerDisabled = false
        MeetingStore.update(r.folder) {
            $0.offsets = offsets
            $0.duration = Date().timeIntervalSince(r.start)
            $0.status = "transcribing"
        }
        reload()
        process(r.folder)
    }

    // MARK: Transcript and notes

    /// Stops the processing of a meeting (download, transcript or notes).
    func cancelProcessing(_ id: String) { cancelFlags[id]?.cancel() }
    private var cancelFlags: [String: CancelFlag] = [:]
    /// Meetings whose processing was paused because the app left the screen, to resume when it's back.
    private var pausedInBackground: Set<String> = []

    /// iOS doesn't let apps use the GPU in the background, and whisper.cpp/llama.cpp would stall there,
    /// so processing pauses when the app leaves the screen (e.g. the phone locks) and resumes when it's back.
    func appDidEnterBackground() {
        for (id, flag) in cancelFlags {
            pausedInBackground.insert(id)
            flag.cancel()
        }
    }

    func appDidBecomeActive() {
        let ids = pausedInBackground
        pausedInBackground = []
        // Keep the screen on while recording or working (set again here: setting it during launch doesn't stick).
        UIApplication.shared.isIdleTimerDisabled = isRecording || !progress.isEmpty || !ids.isEmpty
        for id in ids {
            let folder = URL(fileURLWithPath: id)
            Task {
                // Let the cancelled run finish cleaning up first.
                while progress[id] != nil { try? await Task.sleep(for: .milliseconds(200)) }
                process(folder, notesOnly: !MeetingStore.readBody(folder, MeetingStore.transcriptFile).isEmpty)
            }
        }
    }

    /// Makes the transcript (unless `notesOnly`) and then the notes, all on the phone.
    func process(_ folder: URL, notesOnly: Bool = false, language: MeetingLanguage? = nil) {
        let id = folder.path
        guard progress[id] == nil else { return }
        let d = UserDefaults.standard
        let name = d.string(forKey: Keys.name) ?? ""
        let instructions = NotesPrompt.effectiveInstructions(d.string(forKey: Keys.notesInstructions))
        let keepAudio = d.bool(forKey: Keys.keepAudio)
        let engine = NotesEngine.current
        let cancel = CancelFlag()
        cancelFlags[id] = cancel
        progress[id] = notesOnly ? "Writing notes" : "Transcribing"
        // Whisper and Gemma use the GPU, which iOS only allows while the app is on screen.
        UIApplication.shared.isIdleTimerDisabled = true

        Task {
            defer {
                progress[id] = nil
                cancelFlags[id] = nil
                UIApplication.shared.isIdleTimerDisabled = isRecording
                reload()
            }
            var meta = MeetingStore.readMeta(folder) ?? Meta(title: folder.lastPathComponent)
            let setting = MeetingLanguage(rawValue: d.string(forKey: Keys.language) ?? "") ?? .automatic
            var lang = language ?? meta.lang.flatMap(MeetingLanguage.init(rawValue:)) ?? setting
            let report: Report = { [weak self] phase, fraction in
                let text = fraction.map { "\(phase) · \(Int(($0 * 100).rounded()))%" } ?? phase
                Task { @MainActor in self?.progress[id] = text }
            }
            let bench = Benchmark()

            var transcript = MeetingStore.readBody(folder, MeetingStore.transcriptFile)
            if !notesOnly || transcript.isEmpty {
                MeetingStore.update(folder) { $0.status = "transcribing"; $0.error = nil }
                reload()
                do {
                    let out = try await Transcriber.transcribe(folder: folder, offsets: meta.offsets ?? [:], language: lang,
                                                               cancel: cancel, report: report)
                    bench.transcribe(seconds: out.seconds, audio: out.audioSeconds, model: out.model.id)
                    guard !out.transcript.isEmpty else {
                        throw EngineError.failed("No speech was recognized. Check that the microphone isn't covered and the phone is near the people talking.")
                    }
                    transcript = out.transcript
                    lang = out.language
                    meta = MeetingStore.readMeta(folder) ?? meta
                    try MeetingStore.writeTranscript(transcript, title: meta.title, to: folder)
                    MeetingStore.update(folder) { $0.lang = lang.rawValue }
                    // The transcript is safe, so the audio can go (unless the user keeps recordings).
                    if !keepAudio {
                        for f in MeetingStore.audioFiles(folder) { try? FileManager.default.removeItem(at: f) }
                        MeetingStore.update(folder) { $0.audioArchived = Date() }
                    }
                } catch {
                    fail(folder, error)
                    bench.write(to: folder, error: error)
                    return
                }
            }

            MeetingStore.update(folder) { $0.status = "summarizing"; $0.error = nil }
            reload()
            report("Writing notes", nil)
            do {
                let title = MeetingStore.readMeta(folder)?.title ?? meta.title
                if let gemma = engine.gemma {
                    try await ModelStore.ensure(gemma, cancel: cancel) { report("Downloading \(gemma.label)", $0) }
                }
                let start = Date()
                let notes = try await NotesWriter.write(transcript: transcript, title: title, language: lang, name: name,
                                                        instructions: instructions, engine: engine, cancel: cancel, report: report,
                                                        onFallback: { message in Task { @MainActor in self.alert = message } })
                bench.notes(seconds: Date().timeIntervalSince(start), engine: engine.gemma?.id ?? engine.rawValue)
                guard !notes.isEmpty else { throw EngineError.failed("The notes model returned nothing. The transcript is kept: tap Write notes.") }
                try MeetingStore.writeNotes(notes, title: title, to: folder)
                MeetingStore.update(folder) { $0.status = "done"; $0.error = nil }
                bench.write(to: folder, error: nil)
            } catch {
                fail(folder, error)
                bench.write(to: folder, error: error)
            }
        }
    }

    private func fail(_ folder: URL, _ error: Error) {
        let message: String
        if case EngineError.cancelled = error, pausedInBackground.contains(folder.path) {
            message = "Paused while the app was in the background. It continues when you open the app."
        } else if case EngineError.cancelled = error {
            message = "Stopped. Tap Try again to continue."
        } else if UIApplication.shared.applicationState != .active {
            message = "This stopped when the app left the screen (iOS only lets apps use the GPU while they're open). Keep the app open and tap Try again."
        } else {
            message = error.localizedDescription
        }
        MeetingStore.update(folder) { $0.status = "failed"; $0.error = message }
    }

    // MARK: Model downloads

    /// Optional models being downloaded, by model id, with progress from 0 to 1.
    private(set) var downloads: [String: Double] = [:]
    private var downloadFlags: [String: CancelFlag] = [:]
    /// Bumped when a model is downloaded or deleted, so lists refresh.
    private(set) var modelsChanged = 0

    func download(_ m: ModelFile) {
        guard downloads[m.id] == nil, !ModelStore.isReady(m) else { return }
        let flag = CancelFlag()
        downloadFlags[m.id] = flag
        downloads[m.id] = 0
        Task {
            defer { downloads[m.id] = nil; downloadFlags[m.id] = nil; modelsChanged += 1 }
            do {
                try await ModelStore.ensure(m, cancel: flag) { [weak self] p in
                    Task { @MainActor in if self?.downloads[m.id] != nil { self?.downloads[m.id] = p } }
                }
            } catch {
                if case EngineError.cancelled = error { return }
                alert = error.localizedDescription
            }
        }
    }

    func cancelDownload(_ m: ModelFile) { downloadFlags[m.id]?.cancel() }

    func deleteModel(_ m: ModelFile) {
        ModelStore.delete(m)
        modelsChanged += 1
    }

    // MARK: Editing

    func rename(_ m: Meeting, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != m.title else { return }
        MeetingStore.rename(m.folder, to: t)
        reload()
    }

    func delete(_ m: Meeting) {
        if recorder?.folder == m.folder { return }
        try? FileManager.default.removeItem(at: m.folder)
        reload()
    }

    func deleteAudio(_ m: Meeting) {
        for f in MeetingStore.audioFiles(m.folder) { try? FileManager.default.removeItem(at: f) }
        MeetingStore.update(m.folder) { $0.audioArchived = Date() }
        reload()
    }
}
