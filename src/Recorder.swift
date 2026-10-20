import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Records the computer's sound ("others") and the microphone ("me") as two
/// separate tracks using ScreenCaptureKit. No virtual audio driver needed.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let folder: URL
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "se.frinkle.meetingnotes.audio")
    private var files: [String: AVAudioFile] = [:]
    private var formats: [String: AVAudioFormat] = [:]
    private var firstPTS: [String: Double] = [:]
    private var converters: [String: AVAudioConverter] = [:]
    private var stopped = false   // only touched on `queue`

    init(folder: URL) {
        self.folder = folder
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "MeetingNotes", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for audio capture"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // Video is required by the API but unused, so keep it tiny and slow.
        config.width = 64
        config.height = 64
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.showsCursor = false

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    /// Stops capture, closes the files and returns each track's start offset in seconds.
    func stop() async -> [String: Double] {
        if let s = stream {
            try? await s.stopCapture()
        }
        stream = nil
        return await withCheckedContinuation { (cont: CheckedContinuation<[String: Double], Never>) in
            queue.async {
                self.stopped = true
                for f in self.files.values { f.close() }
                self.files.removeAll()
                var offsets: [String: Double] = [:]
                if let start = self.firstPTS.values.min() {
                    for (k, v) in self.firstPTS { offsets[k] = max(0, v - start) }
                }
                cont.resume(returning: offsets)
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let key: String
        switch type {
        case .audio: key = "others"
        case .microphone: key = "me"
        default: return
        }
        // A late buffer after stop() must not reopen (and truncate) the file.
        guard !stopped else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              let desc = sampleBuffer.formatDescription,
              var asbd = desc.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return }

        do {
            if files[key] == nil {
                let url = folder.appendingPathComponent("\(key).caf")
                files[key] = try AVAudioFile(forWriting: url, settings: format.settings,
                                             commonFormat: format.commonFormat,
                                             interleaved: format.isInterleaved)
                formats[key] = format
                firstPTS[key] = sampleBuffer.presentationTimeStamp.seconds
            }
            guard let file = files[key], let f0 = formats[key] else { return }
            try sampleBuffer.withAudioBufferList { abl, _ in
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: abl.unsafePointer) else { return }
                if format == f0 {
                    try file.write(from: pcm)
                    return
                }
                // The device changed format mid-call (e.g. headset switch): convert to the file's format.
                if converters[key]?.inputFormat != format {
                    converters[key] = AVAudioConverter(from: format, to: f0)
                }
                guard let conv = converters[key] else { return }
                let capacity = AVAudioFrameCount(Double(pcm.frameLength) * f0.sampleRate / format.sampleRate) + 1024
                guard let out = AVAudioPCMBuffer(pcmFormat: f0, frameCapacity: capacity) else { return }
                var fed = false
                var err: NSError?
                conv.convert(to: out, error: &err) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return pcm
                }
                if let err { throw err }
                if out.frameLength > 0 { try file.write(from: out) }
            }
        } catch {
            NSLog("MeetingNotes: audio write error: \(error)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error.localizedDescription)
    }
}
