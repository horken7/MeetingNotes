import Foundation
import MeetingCore
import MeetingNative

enum EngineError: LocalizedError {
    case loadFailed(String)
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .loadFailed(let s), .failed(let s): return s
        case .cancelled: return "Stopped."
        }
    }
}

/// Lets a long native job be stopped from another thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

/// The CPU threads for whisper.cpp and llama.cpp: the performance cores (Metal does most of the work).
let engineThreads: Int32 = {
    var p: Int32 = 0
    var size = MemoryLayout<Int32>.size
    if sysctlbyname("hw.perflevel0.physicalcpu", &p, &size, nil, 0) == 0, p > 0 { return max(2, p) }
    return 2
}()

// MARK: Speech

/// whisper.cpp with Metal. Not thread-safe: use one instance from one task at a time.
final class WhisperEngine: @unchecked Sendable {
    private let ctx: OpaquePointer

    init(modelPath: String) throws {
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            throw EngineError.loadFailed("The speech model couldn't be loaded. Delete it in Settings and download it again.")
        }
        self.ctx = ctx
    }

    deinit { whisper_free(ctx) }

    /// The most likely of `candidates` (whisper language codes such as "sv") in up to 30 s of audio.
    func detectLanguage(_ samples: [Float], candidates: [String]) -> String? {
        let n = min(samples.count, 16_000 * 30)
        guard n > 16_000, samples.withUnsafeBufferPointer({ whisper_pcm_to_mel(ctx, $0.baseAddress, Int32(n), engineThreads) }) == 0
        else { return nil }
        var probs = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        guard whisper_lang_auto_detect(ctx, 0, engineThreads, &probs) >= 0 else { return nil }
        return candidates.max { probs[Int(whisper_lang_id($0))] < probs[Int(whisper_lang_id($1))] }
    }

    /// Transcribes 16 kHz mono samples. Times in the result are seconds from the start of `samples`.
    func transcribe(_ samples: [Float], language: String, vadModelPath: String, cancel: CancelFlag,
                    progress: @escaping (Double) -> Void) throws -> [Segment] {
        final class Box { let progress: (Double) -> Void; let cancel: CancelFlag
            init(_ p: @escaping (Double) -> Void, _ c: CancelFlag) { progress = p; cancel = c } }
        let box = Box(progress, cancel)
        let user = Unmanaged.passUnretained(box).toOpaque()

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = engineThreads
        params.translate = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.suppress_nst = true
        params.progress_callback = { _, _, pct, user in
            Unmanaged<Box>.fromOpaque(user!).takeUnretainedValue().progress(Double(pct) / 100)
        }
        params.progress_callback_user_data = user
        params.abort_callback = { user in Unmanaged<Box>.fromOpaque(user!).takeUnretainedValue().cancel.isCancelled }
        params.abort_callback_user_data = user
        params.vad = true

        let status: Int32 = language.withCString { lang in
            vadModelPath.withCString { vad in
                params.language = lang
                params.vad_model_path = vad
                return withExtendedLifetime(box) {
                    samples.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
                }
            }
        }
        if cancel.isCancelled { throw EngineError.cancelled }
        guard status == 0 else { throw EngineError.failed("Transcription failed (error \(status)). Tap Try again.") }
        if Benchmark.enabled { whisper_print_timings(ctx) }

        return (0..<whisper_full_n_segments(ctx)).map { i in
            Segment(start: Double(whisper_full_get_segment_t0(ctx, i)) / 100,
                    end: Double(whisper_full_get_segment_t1(ctx, i)) / 100,
                    text: String(cString: whisper_full_get_segment_text(ctx, i)))
        }
    }
}

// MARK: Notes

/// llama.cpp with Metal, for a chat model such as Gemma 3. Not thread-safe.
final class LlamaEngine: @unchecked Sendable {
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    let contextTokens: Int

    private static let backend: Void = {
        llama_log_set({ level, text, _ in
            if level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue || Benchmark.enabled, let text { NSLog("llama: %@", String(cString: text)) }
        }, nil)
        llama_backend_init()
    }()

    init(modelPath: String, contextTokens: Int) throws {
        _ = Self.backend
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(modelPath, mp) else {
            throw EngineError.loadFailed("The notes model couldn't be loaded, probably because there isn't enough free memory.")
        }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(contextTokens)
        cp.n_batch = 512
        cp.n_ubatch = 512
        cp.n_threads = engineThreads
        cp.n_threads_batch = engineThreads
        guard let ctx = llama_init_from_model(model, cp) else {
            llama_model_free(model)
            throw EngineError.loadFailed("The notes model couldn't start, probably because there isn't enough free memory.")
        }
        self.model = model
        self.ctx = ctx
        self.vocab = llama_model_get_vocab(model)
        self.contextTokens = contextTokens
    }

    deinit {
        llama_free(ctx)
        llama_model_free(model)
    }

    /// One chat turn: the system and user messages in, the model's answer out.
    /// `prefix` is the start of the answer, written for the model, which continues from it.
    func generate(system: String, user: String, prefix: String = "", maxTokens: Int, cancel: CancelFlag) throws -> String {
        llama_memory_clear(llama_get_memory(ctx), true)
        let prompt = try chatPrompt(system: system, user: user) + prefix
        var tokens = tokenize(prompt)
        if Benchmark.enabled {
            NSLog("notes prompt: %d tokens, %d characters:\n%@", tokens.count, prompt.count, prompt)
        }
        if tokens.count + maxTokens > contextTokens { throw NotesError.contextExceeded }

        // The prompt, in batches.
        var i = 0
        while i < tokens.count {
            if cancel.isCancelled { throw EngineError.cancelled }
            let n = min(512, tokens.count - i)
            let rc = tokens.withUnsafeMutableBufferPointer { buf in
                llama_decode(ctx, llama_batch_get_one(buf.baseAddress! + i, Int32(n)))
            }
            guard rc == 0 else { throw EngineError.failed("The notes model failed while reading the transcript (error \(rc)).") }
            i += n
        }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), NotesSampling.repeatLastN, NotesSampling.repeatPenalty, 0, 0))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(NotesSampling.topK))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(NotesSampling.topP, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(NotesSampling.temperature))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

        var out = Data()
        var piece = [CChar](repeating: 0, count: 256)
        for _ in 0..<maxTokens {
            if cancel.isCancelled { throw EngineError.cancelled }
            var token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if n > 0 { out.append(contentsOf: piece[0..<Int(n)].map { UInt8(bitPattern: $0) }) }
            let rc = llama_decode(ctx, llama_batch_get_one(&token, 1))
            guard rc == 0 else { break }   // out of context: return what we have
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func chatPrompt(system: String, user: String) throws -> String {
        let template = llama_model_chat_template(model, nil)
        return try system.withCString { sys in
            try user.withCString { usr in
                try "system".withCString { roleSystem in
                    try "user".withCString { roleUser in
                        var messages = [llama_chat_message(role: roleSystem, content: sys),
                                        llama_chat_message(role: roleUser, content: usr)]
                        var buf = [CChar](repeating: 0, count: system.utf8.count + user.utf8.count + 1024)
                        var n = llama_chat_apply_template(template, &messages, 2, true, &buf, Int32(buf.count))
                        if n > buf.count {
                            buf = [CChar](repeating: 0, count: Int(n) + 1)
                            n = llama_chat_apply_template(template, &messages, 2, true, &buf, Int32(buf.count))
                        }
                        guard n > 0 else { throw EngineError.failed("The notes model has no chat template.") }
                        return String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    }
                }
            }
        }
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 16)
        var n = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), true, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), true, true)
        }
        return Array(tokens.prefix(Int(max(0, n))))
    }
}

/// The app's current memory footprint, as iOS counts it against the app's limit.
func memoryFootprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
}
