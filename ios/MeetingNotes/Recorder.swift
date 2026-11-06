import AVFoundation
import MeetingCore

/// Records the iPhone microphone into the meeting folder as 16 kHz mono PCM in CAF files, which stay
/// readable up to the last written sample even if the app is killed. A phone call or Siri ends the current
/// segment (audio.caf) cleanly; when the interruption is over a new one starts (audio-1.caf, audio-2.caf…).
@MainActor
final class Recorder: NSObject {
    let folder: URL
    /// When the first segment started recording; the meeting's clock.
    private(set) var start = Date()
    private(set) var interrupted = false
    private(set) var segment = 0
    private(set) var offsets: [String: Double] = [:]
    private var recorder: AVAudioRecorder?
    /// Called when recording pauses for an interruption or resumes after it.
    var onChange: (() -> Void)?

    static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    init(folder: URL) {
        self.folder = folder
        super.init()
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func begin() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(interruption(_:)), name: AVAudioSession.interruptionNotification, object: session)
        nc.addObserver(self, selector: #selector(mediaReset(_:)), name: AVAudioSession.mediaServicesWereResetNotification, object: session)
        try startSegment()
    }

    /// Stops recording and returns the start offset of each segment, keyed by its file name.
    func finish() -> [String: Double] {
        NotificationCenter.default.removeObserver(self)
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return offsets
    }

    /// Starts a new segment after an interruption the system didn't resume from by itself.
    func resume() throws {
        guard interrupted else { return }
        try AVAudioSession.sharedInstance().setActive(true)
        try startSegment()
        onChange?()
    }

    /// The input level, 0 to 1.
    func level() -> Float {
        guard let r = recorder, r.isRecording else { return 0 }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)
        return max(0, min(1, (db + 55) / 55))
    }

    private func startSegment() throws {
        let name = MeetingStore.segmentName(segment)
        let url = folder.appendingPathComponent("\(name).caf")
        let r = try AVAudioRecorder(url: url, settings: Self.settings)
        r.isMeteringEnabled = true
        guard r.record() else { throw RecorderError.couldNotStart }
        recorder = r
        if segment == 0 { start = Date() }
        offsets[name] = Date().timeIntervalSince(start)
        MeetingStore.update(folder) { $0.offsets = self.offsets }
        interrupted = false
    }

    /// Closes the current segment so its file is complete, and remembers to start the next one.
    private func endSegment() {
        guard !interrupted else { return }
        recorder?.stop()
        recorder = nil
        interrupted = true
        segment += 1
        onChange?()
    }

    @objc private nonisolated func interruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        Task { @MainActor in
            switch type {
            case .began:
                self.endSegment()
            case .ended:
                // Carry on even without .shouldResume; if the system refuses, the screen offers Resume.
                try? self.resume()
            @unknown default:
                break
            }
        }
    }

    @objc private nonisolated func mediaReset(_ note: Notification) {
        Task { @MainActor in
            self.endSegment()
            try? AVAudioSession.sharedInstance().setCategory(.record, mode: .default, options: [])
            try? self.resume()
        }
    }
}

enum RecorderError: LocalizedError {
    case couldNotStart
    case noPermission

    var errorDescription: String? {
        switch self {
        case .couldNotStart: return "The microphone couldn't start recording."
        case .noPermission: return "Meeting Notes needs the microphone. Allow it in Settings > Privacy & Security > Microphone."
        }
    }
}
