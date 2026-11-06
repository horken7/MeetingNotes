import MeetingCore
import SwiftUI
import UIKit

enum Keys {
    static let name = "myName"
    static let language = "language"
    static let keepAudio = "keepAudio"
    static let notesInstructions = "notesInstructions"
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
        UserDefaults.standard.register(defaults: [Keys.keepAudio: true, Keys.language: MeetingLanguage.automatic.rawValue])
        if ProcessInfo.processInfo.arguments.contains("-demo") { DemoData.seed(in: store) }
        recoverInterrupted()
        reload()
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

    /// Makes the transcript (unless `notesOnly`) and then the notes, all on the phone.
    func process(_ folder: URL, notesOnly: Bool = false, language: MeetingLanguage? = nil) {
        let id = folder.path
        guard progress[id] == nil else { return }
        let d = UserDefaults.standard
        let name = d.string(forKey: Keys.name) ?? ""
        let instructions = NotesPrompt.effectiveInstructions(d.string(forKey: Keys.notesInstructions))
        let keepAudio = d.bool(forKey: Keys.keepAudio)
        progress[id] = notesOnly ? "Writing notes" : "Transcribing"
        UIApplication.shared.isIdleTimerDisabled = true
        // Gives the work a little time to finish if the app goes to the background.
        let task = UIApplication.shared.beginBackgroundTask(withName: "Meeting notes")

        Task {
            defer {
                progress[id] = nil
                UIApplication.shared.isIdleTimerDisabled = isRecording
                UIApplication.shared.endBackgroundTask(task)
                reload()
            }
            var meta = MeetingStore.readMeta(folder) ?? Meta(title: folder.lastPathComponent)
            let setting = MeetingLanguage(rawValue: d.string(forKey: Keys.language) ?? "") ?? .automatic
            var lang = language ?? meta.lang.flatMap(MeetingLanguage.init(rawValue:)) ?? setting
            let report: @MainActor (String) -> Void = { [weak self] in self?.progress[id] = $0 }

            var transcript = MeetingStore.readBody(folder, MeetingStore.transcriptFile)
            if !notesOnly || transcript.isEmpty {
                MeetingStore.update(folder) { $0.status = "transcribing"; $0.error = nil }
                reload()
                do {
                    let out = try await Transcriber.transcribe(folder: folder, offsets: meta.offsets ?? [:], language: lang, progress: report)
                    guard !out.transcript.isEmpty else {
                        throw NotesError.failed("No speech was recognized in the recording.")
                    }
                    transcript = out.transcript
                    lang = out.language
                    meta = MeetingStore.readMeta(folder) ?? meta
                    try MeetingStore.writeTranscript(transcript, title: meta.title, to: folder)
                    MeetingStore.update(folder) { $0.lang = lang.rawValue }
                } catch {
                    MeetingStore.update(folder) { $0.status = "failed"; $0.error = error.localizedDescription }
                    return
                }
            }

            MeetingStore.update(folder) { $0.status = "summarizing"; $0.error = nil }
            reload()
            report("Writing notes")
            do {
                let title = MeetingStore.readMeta(folder)?.title ?? meta.title
                let notes = try await NotesWriter.write(transcript: transcript, title: title, language: lang, name: name,
                                                        instructions: instructions) { message in
                    Task { @MainActor in report(message) }
                }
                try MeetingStore.writeNotes(notes, title: title, to: folder)
                if !keepAudio {
                    for f in MeetingStore.audioFiles(folder) { try? FileManager.default.removeItem(at: f) }
                    MeetingStore.update(folder) { $0.audioArchived = Date() }
                }
                MeetingStore.update(folder) { $0.status = "done"; $0.error = nil }
            } catch {
                MeetingStore.update(folder) { $0.status = "failed"; $0.error = error.localizedDescription }
            }
        }
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
