import Foundation
import AVFoundation

/// What AppModel needs from a capture: `Recorder` (mic + system audio) or `MicRecorder` (mic only).
protocol AudioCapture: AnyObject {
    /// Stops capture, closes the files and returns each track's start offset in seconds.
    func stop() async -> [String: Double]
}

extension Recorder: AudioCapture {}

/// Records only the microphone to `me.caf`. Used when the system audio capture can't run
/// (e.g. ScreenCaptureKit finds no display, or Screen Recording permission is off), so the
/// meeting still gets recorded in one track instead of stopping.
final class MicRecorder: AudioCapture {
    private let recorder: AVAudioRecorder

    init(folder: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        recorder = try AVAudioRecorder(url: folder.appendingPathComponent("me.caf"), settings: settings)
    }

    func start() throws {
        guard recorder.record() else {
            throw NSError(domain: "MeetingNotes", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The microphone couldn't be recorded"])
        }
    }

    func stop() async -> [String: Double] {
        recorder.stop()
        return ["me": 0]
    }
}
