import AVFoundation
import CoreMedia
import MeetingCore
import NaturalLanguage
import Speech

/// On-device speech recognition with Apple's SpeechAnalyzer (iOS 26). English uses SpeechTranscriber;
/// Swedish and Danish aren't among its locales, so they use DictationTranscriber, which runs in the same
/// analyzer and is also on device. The language model is downloaded once through AssetInventory.
/// SFSpeechRecognizer is the last resort, and only when it can run on device.
enum Transcriber {
    struct Output {
        var transcript: String
        var language: MeetingLanguage
    }

    static func transcribe(folder: URL, offsets: [String: Double], language: MeetingLanguage,
                           progress: @escaping @MainActor (String) -> Void) async throws -> Output {
        let files = MeetingStore.audioFiles(folder)
        guard !files.isEmpty else { throw TranscriberError.noAudio }

        let first = language == .automatic ? MeetingLanguage.guess(preferred: Locale.preferredLanguages) : language
        var segments = try await run(files: files, offsets: offsets, language: first, progress: progress)

        // Automatic: check what language the text is in, and redo it once if it isn't the guess.
        if language == .automatic, let detected = detect(segments), detected != first {
            await progress("Transcribing again in \(detected.label)")
            segments = try await run(files: files, offsets: offsets, language: detected, progress: progress)
            return Output(transcript: TranscriptFormatter.format(segments), language: detected)
        }
        return Output(transcript: TranscriptFormatter.format(segments), language: first)
    }

    static func detect(_ segments: [Segment]) -> MeetingLanguage? {
        let text = segments.map(\.text).joined(separator: " ")
        guard text.count > 80 else { return nil }
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.swedish, .danish, .english, .norwegian]
        r.processString(text)
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p > 0.75 else { return nil }
        switch lang {
        case .swedish: return .swedish
        case .danish: return .danish
        case .english: return .english
        default: return nil
        }
    }

    private static func run(files: [URL], offsets: [String: Double], language: MeetingLanguage,
                            progress: @escaping @MainActor (String) -> Void) async throws -> [Segment] {
        let locale = Locale(identifier: language.localeIdentifier ?? "en-US")
        var all: [Segment] = []
        for (i, file) in files.enumerated() {
            let offset = offsets[file.deletingPathExtension().lastPathComponent] ?? 0
            await progress(files.count > 1 ? "Transcribing part \(i + 1) of \(files.count)" : "Transcribing")
            all += try await transcribe(file: file, locale: locale, progress: progress)
                .map { Segment(start: $0.start + offset, end: $0.end + offset, text: $0.text) }
        }
        return all
    }

    private static func transcribe(file: URL, locale: Locale, progress: @escaping @MainActor (String) -> Void) async throws -> [Segment] {
        if let l = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let module = SpeechTranscriber(locale: l, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            try await installAssets(for: [module], locale: l, progress: progress)
            return try await analyze(file: file, modules: [module], results: module.results.map { ($0.range, String($0.text.characters)) })
        }
        if let l = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let module = DictationTranscriber(locale: l, contentHints: [.farField], transcriptionOptions: [.punctuation],
                                              reportingOptions: [], attributeOptions: [.audioTimeRange])
            try await installAssets(for: [module], locale: l, progress: progress)
            return try await analyze(file: file, modules: [module], results: module.results.map { ($0.range, String($0.text.characters)) })
        }
        return try await legacy(file: file, locale: locale)
    }

    /// Downloads the on-device speech model for the locale the first time it's used.
    private static func installAssets(for modules: [any SpeechModule], locale: Locale, progress: @escaping @MainActor (String) -> Void) async throws {
        let status = await AssetInventory.status(forModules: modules)
        if status == .unsupported { throw TranscriberError.unsupported(locale) }
        if status == .installed { return }
        // Make room: the system only keeps a few speech languages reserved per app.
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier == locale.identifier }), reserved.count >= AssetInventory.maximumReservedLocales,
           let oldest = reserved.first {
            _ = await AssetInventory.release(reservedLocale: oldest)
        }
        _ = try? await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            await progress("Downloading the speech model for \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)")
            try await request.downloadAndInstall()
        }
    }

    private static func analyze<S: AsyncSequence & Sendable>(file: URL, modules: [any SpeechModule], results: S) async throws -> [Segment]
    where S.Element == (CMTimeRange, String) {
        let audio = try AVAudioFile(forReading: file)
        guard audio.length > 0 else { return [] }
        let collect = Task {
            var out: [Segment] = []
            for try await (range, text) in results {
                out.append(Segment(start: range.start.seconds, end: range.end.seconds, text: text))
            }
            return out
        }
        let analyzer = SpeechAnalyzer(modules: modules)
        do {
            if let last = try await analyzer.analyzeSequence(from: audio) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collect.cancel()
            throw error
        }
        return try await collect.value
    }

    /// SFSpeechRecognizer, on device only (nothing is sent to Apple's servers).
    private static func legacy(file: URL, locale: Locale) async throws -> [Segment] {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw TranscriberError.unsupported(locale)
        }
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
            guard status == .authorized else { throw TranscriberError.noPermission }
        }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let result: SFSpeechRecognitionResult = try await withCheckedThrowingContinuation { c in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let error { done = true; c.resume(throwing: error) }
                else if let result, result.isFinal { done = true; c.resume(returning: result) }
            }
        }
        // Group words into sentences, with each sentence's start time.
        var out: [Segment] = []
        var current: Segment?
        for s in result.bestTranscription.segments {
            if current == nil { current = Segment(start: s.timestamp, end: s.timestamp + s.duration, text: s.substring) }
            else { current!.text += " " + s.substring; current!.end = s.timestamp + s.duration }
            if let last = s.substring.last, ".?!".contains(last) { out.append(current!); current = nil }
        }
        if let current { out.append(current) }
        return out
    }
}

enum TranscriberError: LocalizedError {
    case noAudio
    case unsupported(Locale)
    case noPermission

    var errorDescription: String? {
        switch self {
        case .noAudio:
            return "The audio for this meeting wasn't kept, so the transcript can't be made."
        case .unsupported(let l):
            return "On-device speech recognition for \(Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier) isn't available on this iPhone."
        case .noPermission:
            return "Allow Speech Recognition for Meeting Notes in Settings > Privacy & Security."
        }
    }
}
