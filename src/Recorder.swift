import Foundation
import AVFoundation
import CoreAudio

/// Records the microphone ("me") and the computer's sound ("others") as two separate tracks.
/// The mic goes through AVAudioEngine and the system audio through a Core Audio process tap, so only the
/// Microphone and System Audio Recording permissions are needed (no screen recording, no virtual driver).
final class Recorder: NSObject {
    let folder: URL
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "se.frinkle.meetingnotes.audio")
    private var tracks: [String: TrackWriter] = [:]   // only touched on `queue`
    private var stopped = false   // only touched on `queue`
    private let engine = AVAudioEngine()
    private var micRunning = false
    private var tap: SystemAudioTap?

    init(folder: URL) {
        self.folder = folder
        super.init()
        for key in ["me", "others"] {
            tracks[key] = TrackWriter(url: folder.appendingPathComponent("\(key).caf"))
        }
    }

    func start() async throws {
        installMicTap()
        // The engine stops when the input device changes (e.g. a headset is plugged in): follow the new device.
        NotificationCenter.default.addObserver(self, selector: #selector(restartMic),
                                               name: .AVAudioEngineConfigurationChange, object: engine)
        micRunning = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopMic()
            throw error
        }
        // After the mic, so this process is known to Core Audio and can be left out of the tap.
        do {
            tap = try SystemAudioTap(queue: queue) { [weak self] buffer, hostTime in
                self?.write("others", buffer, hostTime: hostTime)
            }
        } catch {
            stopMic()
            throw error
        }
    }

    /// Stops capture, closes the files and returns each track's start offset in seconds.
    func stop() async -> [String: Double] {
        stopMic()
        tap?.stop()
        tap = nil
        return await withCheckedContinuation { (cont: CheckedContinuation<[String: Double], Never>) in
            queue.async {
                self.stopped = true
                var starts: [String: Double] = [:]
                for (key, track) in self.tracks {
                    track.close()
                    starts[key] = track.startTime
                }
                cont.resume(returning: Recorder.offsets(starts))
            }
        }
    }

    /// Each track's start relative to the earliest one, in seconds.
    static func offsets(_ starts: [String: Double]) -> [String: Double] {
        guard let first = starts.values.min() else { return [:] }
        return starts.mapValues { max(0, $0 - first) }
    }

    private func installMicTap() {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            let hostTime = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
            self.queue.sync { self.write("me", buffer, hostTime: hostTime) }
        }
    }

    @objc private func restartMic() {
        guard micRunning, !queue.sync(execute: { stopped }) else { return }
        installMicTap()
        do {
            try engine.start()
        } catch {
            onError?("The microphone stopped (\(error.localizedDescription))")
        }
    }

    private func stopMic() {
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
        micRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Called on `queue`.
    private func write(_ key: String, _ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        // A late buffer after stop() must not reopen (and truncate) the file.
        guard !stopped, buffer.frameLength > 0 else { return }
        do {
            try tracks[key]?.write(buffer, hostTime: hostTime)
        } catch {
            NSLog("MeetingNotes: audio write error: \(error)")
        }
    }
}

/// One `.caf` file, opened with the format of the first buffer. Only used on the recorder's queue.
private final class TrackWriter {
    let url: URL
    private(set) var startTime: Double?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?

    init(url: URL) {
        self.url = url
    }

    func write(_ pcm: AVAudioPCMBuffer, hostTime: UInt64) throws {
        let format = pcm.format
        if file == nil {
            file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            startTime = AVAudioTime.seconds(forHostTime: hostTime)
        }
        guard let file else { return }
        let f0 = file.processingFormat
        if format == f0 {
            try file.write(from: pcm)
            return
        }
        // The device changed format mid-call (e.g. headset switch): convert to the file's format.
        if converter?.inputFormat != format {
            converter = AVAudioConverter(from: format, to: f0)
        }
        guard let conv = converter else { return }
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

    func close() {
        file?.close()
        file = nil
    }
}

/// A Core Audio process tap (macOS 14.4+) on everything the Mac plays except this app,
/// read through a private aggregate device that contains only the tap.
private final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?   // only touched on `queue`
    private var formatAddress = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var formatListener: AudioObjectPropertyListenerBlock?
    private let queue: DispatchQueue

    init(queue: DispatchQueue, onBuffer: @escaping (AVAudioPCMBuffer, UInt64) -> Void) throws {
        self.queue = queue
        do {
            try create(onBuffer: onBuffer)
        } catch {
            stop()
            throw error
        }
    }

    private func create(onBuffer: @escaping (AVAudioPCMBuffer, UInt64) -> Void) throws {
        let own = Self.processObject(pid: getpid()).map { [$0] } ?? []
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: own)
        desc.uuid = UUID()
        desc.isPrivate = true
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "create the system audio tap")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Notes system audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "create the audio device")

        format = try readFormat()
        // The output device can change format mid-call (e.g. a headset switch); the writer converts it.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let f = try? self.readFormat() else { return }
            self.format = f
        }
        formatListener = listener
        AudioObjectAddPropertyListenerBlock(tapID, &formatAddress, queue, listener)

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, input, inputTime, _, _ in
            guard let self, let format = self.format else { return }
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let expected = format.isInterleaved ? 1 : Int(format.channelCount)
            guard abl.count == expected,
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input) else { return }
            let t = inputTime.pointee
            let hostTime = t.mFlags.contains(.hostTimeValid) ? t.mHostTime : mach_absolute_time()
            onBuffer(pcm, hostTime)
        }, "read system audio")
        try check(AudioDeviceStart(deviceID, procID), "start system audio capture")
    }

    func stop() {
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown {
            if let formatListener {
                AudioObjectRemovePropertyListenerBlock(tapID, &formatAddress, queue, formatListener)
            }
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        formatListener = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func readFormat() throws -> AVAudioFormat {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &asbd), "read the system audio format")
        guard let f = AVAudioFormat(streamDescription: &asbd) else {
            throw NSError(domain: "MeetingNotes", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported system audio format"])
        }
        return f
    }

    /// This process's Core Audio object, which exists once it has used audio (the mic is started first).
    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

private func check(_ status: OSStatus, _ what: String) throws {
    guard status != noErr else { return }
    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                  userInfo: [NSLocalizedDescriptionKey: "Couldn't \(what) (error \(status))"])
}
