import AVFoundation
import MeetingCore

/// Runs blocking native work off the Swift concurrency pool.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in
        DispatchQueue.global(qos: .userInitiated).async { c.resume(with: Result { try work() }) }
    }
}

/// What's happening, for the progress line: a phase and how far along it is (0 to 1) when known.
typealias Report = @Sendable (_ phase: String, _ fraction: Double?) -> Void

/// On-device transcription with whisper.cpp (Metal): KBLab's KB-Whisper for Swedish, OpenAI Whisper for English
/// and Danish, and Silero voice detection to skip silence. Models are downloaded the first time they're needed.
enum Transcriber {
    struct Output: Sendable {
        var transcript: String
        var language: MeetingLanguage
        var audioSeconds: Double
        /// The speech model used.
        var model: ModelFile
        /// Time spent transcribing, without downloads.
        var seconds: Double
    }

    static let sampleRate = 16_000

    static func transcribe(folder: URL, offsets: [String: Double], language: MeetingLanguage,
                           cancel: CancelFlag, report: @escaping Report) async throws -> Output {
        let files = MeetingStore.audioFiles(folder)
        guard !files.isEmpty else {
            throw EngineError.failed(MeetingStore.readMeta(folder)?.audioArchived != nil
                ? "The audio was deleted when the transcript was made, so the transcript can't be redone. To keep the audio of future meetings, turn on Keep audio recordings in Settings."
                : "There's no audio for this meeting, so the transcript can't be made.")
        }

        // The built-in models only download in development builds made without fetch-models.sh.
        try await ModelStore.ensure(Catalog.vad, cancel: cancel) { report("Downloading voice detection", $0) }
        var lang = language
        if lang == .automatic {
            try await ModelStore.ensure(Catalog.whisperSmall, cancel: cancel) { report("Downloading \(Catalog.whisperSmall.label)", $0) }
            report("Detecting the language", nil)
            let sample = try loudestWindow(files[0], seconds: 30)
            let code = try await runBlocking {
                try WhisperEngine(modelPath: ModelStore.url(Catalog.whisperSmall).path)
                    .detectLanguage(sample, candidates: ["sv", "da", "en"])
            }
            lang = MeetingLanguage(rawValue: code ?? "") ?? MeetingLanguage.guess(preferred: Locale.preferredLanguages)
        }

        let model = Catalog.speechModel(for: lang, isReady: ModelStore.isReady)
        try await ModelStore.ensure(model, cancel: cancel) { report("Downloading \(model.label)", $0) }
        if cancel.isCancelled { throw EngineError.cancelled }

        report("Loading the speech model", nil)
        let start = Date()
        let modelPath = ModelStore.url(model).path
        let vadPath = ModelStore.url(Catalog.vad).path
        let code = lang.rawValue
        let segments: [Segment] = try await runBlocking {
            let engine = try WhisperEngine(modelPath: modelPath)
            // Plan all blocks first so progress covers the whole meeting.
            var work: [(url: URL, offset: Double, range: Range<Int>)] = []
            for file in files {
                let offset = offsets[file.deletingPathExtension().lastPathComponent] ?? 0
                let total = try frameCount(file)
                let blocks = AudioBlocks.plan(total: total, target: 10 * 60 * sampleRate, window: 15 * sampleRate) { start, length in
                    rms((try? read(file, from: start, count: length)) ?? [])
                }
                work += blocks.map { (file, offset, $0) }
            }
            var all: [Segment] = []
            for (i, block) in work.enumerated() {
                if cancel.isCancelled { throw EngineError.cancelled }
                let samples = try read(block.url, from: block.range.lowerBound, count: block.range.count)
                let base = block.offset + Double(block.range.lowerBound) / Double(sampleRate)
                report("Transcribing", Double(i) / Double(work.count))
                let out = try engine.transcribe(samples, language: code, vadModelPath: vadPath, cancel: cancel) { p in
                    report("Transcribing", (Double(i) + p) / Double(work.count))
                }
                all += out.map { Segment(start: $0.start + base, end: $0.end + base, text: $0.text) }
            }
            return all
        }
        let seconds = try files.reduce(0.0) { $0 + Double(try frameCount($1)) / Double(sampleRate) }
        return Output(transcript: TranscriptFormatter.format(segments), language: lang, audioSeconds: seconds,
                      model: model, seconds: Date().timeIntervalSince(start))
    }

    // MARK: Audio

    /// The recordings are 16 kHz mono; AVAudioFile also converts the Mac app's WAV files.
    static func frameCount(_ url: URL) throws -> Int {
        let f = try AVAudioFile(forReading: url)
        return Int(Double(f.length) * Double(sampleRate) / f.fileFormat.sampleRate)
    }

    /// `count` samples at 16 kHz mono, starting at sample `from`.
    static func read(_ url: URL, from: Int, count: Int) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let format = f.processingFormat
        let ratio = format.sampleRate / Double(sampleRate)
        f.framePosition = AVAudioFramePosition(Double(from) * ratio)
        let frames = AVAudioFrameCount(Double(count) * ratio)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return [] }
        try f.read(into: buf, frameCount: frames)
        if format.sampleRate == Double(sampleRate), format.channelCount == 1, let ch = buf.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
        }
        // Resample and mix down.
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: format, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(count) + 1024) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    static func rms(_ s: [Float]) -> Double {
        guard !s.isEmpty else { return 0 }
        return sqrt(s.reduce(0) { $0 + Double($1 * $1) } / Double(s.count))
    }

    /// The loudest `seconds` of the first few minutes, for language detection (the start is often silence).
    static func loudestWindow(_ url: URL, seconds: Int) throws -> [Float] {
        let total = try frameCount(url)
        let length = min(total, seconds * sampleRate)
        var best = 0
        var bestEnergy = -1.0
        var at = 0
        while at + length <= min(total, 5 * 60 * sampleRate) {
            let e = rms(try read(url, from: at, count: length))
            if e > bestEnergy { bestEnergy = e; best = at }
            at += 10 * sampleRate
        }
        return try read(url, from: best, count: length)
    }
}
