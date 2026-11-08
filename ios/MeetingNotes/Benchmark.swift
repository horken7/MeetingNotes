import Foundation
import MeetingCore

/// Timings and peak memory for testing on a real iPhone: launched with `-benchmark`, the app writes
/// `timings.json` into each meeting folder it processes.
final class Benchmark: @unchecked Sendable {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-benchmark")

    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var peak: Int64 = 0
    private var timer: DispatchSourceTimer?

    init() {
        guard Self.enabled else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: 0.2)
        t.setEventHandler { [weak self] in
            let now = memoryFootprint()
            self?.lock.withLock { self?.peak = max(self?.peak ?? 0, now) }
        }
        t.resume()
        timer = t
        values["memoryLimitMB"] = NotesWriter.memoryLimit / 1_000_000
        values["device"] = deviceModel()
    }

    deinit { timer?.cancel() }

    func transcribe(seconds: Double, audio: Double, model: String) {
        lock.withLock {
            values["transcribeSeconds"] = (seconds * 10).rounded() / 10
            values["audioSeconds"] = (audio * 10).rounded() / 10
            values["transcribeSecondsPerAudioMinute"] = audio > 0 ? (seconds / audio * 60 * 10).rounded() / 10 : 0
            values["speechModel"] = model
            values["peakAfterTranscribeMB"] = peak / 1_000_000
        }
    }

    func notes(seconds: Double, engine: String) {
        lock.withLock {
            values["notesSeconds"] = (seconds * 10).rounded() / 10
            values["notesEngine"] = engine
        }
    }

    func write(to folder: URL, error: Error?) {
        guard Self.enabled else { return }
        timer?.cancel()
        lock.withLock {
            values["peakMemoryMB"] = peak / 1_000_000
            if let error { values["error"] = error.localizedDescription }
            if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("timings.json"))
            }
        }
    }

    private func deviceModel() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
