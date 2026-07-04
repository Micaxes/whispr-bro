import Foundation
import llama

/// Shared abort flag between Swift and the ggml compute thread. `llama_decode`
/// is a synchronous, uncancellable C call that occupies the engine actor's
/// executor, so a timeout can only be enforced from OUTSIDE via ggml's abort
/// callback: a detached task trips this flag after the deadline and the running
/// decode aborts (returns non-zero) instead of the actor wedging forever.
final class AbortFlag: @unchecked Sendable {
    private let p: UnsafeMutablePointer<Int32>
    init() { p = .allocate(capacity: 1); p.initialize(to: 0) }
    deinit { p.deallocate() }
    var raw: UnsafeMutableRawPointer { UnsafeMutableRawPointer(p) }
    func arm() { p.pointee = 0 }
    func trip() { p.pointee = 1 }
    var tripped: Bool { p.pointee != 0 }
}

/// C abort callback: returns true (abort) once the flag is tripped.
private let llamaAbortCallback: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { data in
    guard let data else { return false }
    return data.assumingMemoryBound(to: Int32.self).pointee != 0
}

/// In-process llama.cpp on Metal (spec §4 Formatter, §6). Loads a GGUF model,
/// fully offloads to the Apple GPU, and reformats a transcript with a
/// persistent KV-cached system-prompt prefix — only the new transcript is
/// prefilled per call. Greedy sampling for deterministic edits.
///
/// llama.cpp's context is single-threaded and not reentrant, so this is an
/// actor: all generation is serialized. Verified against llama.h at tag b9862.
public actor LlamaCppEngine {
    private let modelPath: URL
    private let promptBuilder: PromptBuilder
    private let contextTokens: UInt32

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var batch: llama_batch?
    private var prefixTokenCount: Int32 = 0
    private let abort = AbortFlag()
    private static var backendInitialized = false

    public init(modelPath: URL, promptBuilder: PromptBuilder, contextTokens: UInt32 = 2048) {
        self.modelPath = modelPath
        self.promptBuilder = promptBuilder
        self.contextTokens = contextTokens
    }

    public var isLoaded: Bool { ctx != nil }

    // MARK: - Load

    public func load() async throws {
        guard ctx == nil else { return }
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw WhisprError.modelsNotFound(modelPath)
        }
        if !Self.backendInitialized {
            llama_backend_init()
            Self.backendInitialized = true
        }

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 999 // fully offload to Metal
        guard let model = llama_model_load_from_file(modelPath.path, mparams) else {
            throw WhisprError.modelLoadFailed(modelPath)
        }
        self.model = model
        self.vocab = llama_model_get_vocab(model)

        // Any failure past here must leave the engine fully torn down, or
        // isLoaded would lie and format() would run on a half-built context
        // (garbage output). unload() frees + nils everything.
        var succeeded = false
        defer { if !succeeded { unload() } }

        var cparams = llama_context_default_params()
        cparams.n_ctx = contextTokens
        cparams.n_batch = contextTokens
        let threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        cparams.n_threads = threads
        cparams.n_threads_batch = threads
        guard let ctx = llama_init_from_model(model, cparams) else {
            throw WhisprError.modelLoadFailed(modelPath)
        }
        self.ctx = ctx
        llama_set_abort_callback(ctx, llamaAbortCallback, abort.raw)
        self.batch = llama_batch_init(Int32(contextTokens), 0, 1)

        // Greedy chain (deterministic; the chain owns and frees the leaf).
        guard let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw WhisprError.modelLoadFailed(modelPath)
        }
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        self.sampler = chain

        // Prime the KV cache with the (stable) system-prompt prefix once.
        let prefixTokens = tokenizeScaffolding(promptBuilder.prefix())
        prefixTokenCount = Int32(prefixTokens.count)
        guard decode(prefixTokens, startPos: 0) else {
            throw WhisprError.modelLoadFailed(modelPath)
        }
        succeeded = true
    }

    public func unload() {
        if let sampler { llama_sampler_free(sampler) }
        if let batch { llama_batch_free(batch) }
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        sampler = nil; batch = nil; ctx = nil; model = nil; vocab = nil
        prefixTokenCount = 0
    }

    /// Restore a clean state after a hung/failed/aborted generation (spec §4
    /// EngineSupervisor): wipe the KV cache, reset the sampler, and re-prime
    /// the system-prompt prefix — no full model reload needed.
    public func recover() {
        guard let ctx, let sampler else { return }
        // recover() is called right after a timeout, when the abort flag is
        // still tripped — reset it or the re-prime decode aborts immediately
        // and the prefix is never restored.
        abort.arm()
        let memory = llama_get_memory(ctx)
        llama_memory_clear(memory, true)
        llama_sampler_reset(sampler)
        let prefixTokens = tokenizeScaffolding(promptBuilder.prefix())
        prefixTokenCount = Int32(prefixTokens.count)
        _ = decode(prefixTokens, startPos: 0)
    }

    // MARK: - Format

    /// Reformat `transcript`. Generation is capped at `maxTokens` (≈2× input)
    /// and bounded by `timeout` via the abort callback. Reuses the cached
    /// prefix. Throws `formattingTimedOut` if the abort fired.
    public func format(_ transcript: String, maxTokens: Int, timeout: Duration) throws -> String {
        guard let ctx, let vocab, let sampler else {
            throw WhisprError.modelsNotFound(modelPath)
        }

        // Drop everything after the cached prefix so only the new turn is
        // prefilled; positions resume at prefixTokenCount.
        let memory = llama_get_memory(ctx)
        llama_memory_seq_rm(memory, 0, prefixTokenCount, -1)
        llama_sampler_reset(sampler)

        // Arm the deadline: a detached task trips the abort flag after
        // `timeout` even while this actor is blocked in llama_decode.
        abort.arm()
        let flag = abort
        let ms = Int(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        let deadline = Task.detached {
            // On cancellation (format finished in time) `sleep` throws — return
            // WITHOUT tripping. A bare `try?` would fall through and trip anyway.
            do { try await Task.sleep(for: .milliseconds(max(1, ms))) } catch { return }
            flag.trip()
        }
        defer { deadline.cancel() }

        // The user transcript is tokenized as LITERAL text (parse_special=false)
        // so dictated markup like "<|im_end|>" can't inject control tokens; the
        // scaffolding halves keep parse_special=true.
        let (before, after) = promptBuilder.userTurn()
        let suffixTokens = tokenizeScaffolding(before)
            + tokenizeLiteral(transcript)
            + tokenizeScaffolding(after)
        guard !suffixTokens.isEmpty, decode(suffixTokens, startPos: prefixTokenCount) else {
            if abort.tripped { throw WhisprError.formattingTimedOut }
            throw WhisprError.formattingFailed
        }

        var nPast = prefixTokenCount + Int32(suffixTokens.count)
        var output = [UInt8]()
        var pieceBuf = [CChar](repeating: 0, count: 256)

        for _ in 0..<maxTokens {
            let id = llama_sampler_sample(sampler, ctx, -1) // also accepts internally
            if llama_vocab_is_eog(vocab, id) { break }

            var written = llama_token_to_piece(vocab, id, &pieceBuf, Int32(pieceBuf.count), 0, false)
            if written < 0 {
                pieceBuf = [CChar](repeating: 0, count: Int(-written))
                written = llama_token_to_piece(vocab, id, &pieceBuf, Int32(pieceBuf.count), 0, false)
            }
            if written > 0 {
                pieceBuf.prefix(Int(written)).forEach { output.append(UInt8(bitPattern: $0)) }
            }

            guard decode([id], startPos: nPast) else {
                if abort.tripped { throw WhisprError.formattingTimedOut }
                break
            }
            nPast += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: - Tokenize

    private func tokenizeScaffolding(_ text: String) -> [llama_token] {
        tokenize(text, parseSpecial: true)
    }

    private func tokenizeLiteral(_ text: String) -> [llama_token] {
        tokenize(text, parseSpecial: false)
    }

    private func tokenize(_ text: String, parseSpecial: Bool) -> [llama_token] {
        guard let vocab, !text.isEmpty else { return [] }
        let utf8 = Array(text.utf8)
        let byteCount = Int32(utf8.count)

        // One call, resizing once if the buffer was too small (negative return
        // = required size). add_special is always false — BOS/scaffolding is in
        // the prompt text itself.
        func run(into tokens: inout [llama_token]) -> Int32 {
            utf8.withUnsafeBufferPointer { bytes in
                tokens.withUnsafeMutableBufferPointer { out in
                    bytes.baseAddress!.withMemoryRebound(to: CChar.self, capacity: utf8.count) { cstr in
                        llama_tokenize(vocab, cstr, byteCount, out.baseAddress, Int32(out.count), false, parseSpecial)
                    }
                }
            }
        }

        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        var n = run(into: &tokens)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = run(into: &tokens)
        }
        return n <= 0 ? [] : Array(tokens.prefix(Int(n)))
    }

    // MARK: - Decode

    /// Decode `tokens` at sequence 0 starting at `startPos`, requesting logits
    /// only for the last token. Reuses the persistent batch. False on error.
    private func decode(_ tokens: [llama_token], startPos: Int32) -> Bool {
        guard let ctx, var batch, !tokens.isEmpty, tokens.count <= Int(contextTokens) else { return false }
        let n = Int32(tokens.count)
        batch.n_tokens = n
        for i in 0..<Int(n) {
            batch.token[i] = tokens[i]
            batch.pos[i] = startPos + Int32(i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = (i == Int(n) - 1) ? 1 : 0
        }
        return llama_decode(ctx, batch) == 0
    }
}
