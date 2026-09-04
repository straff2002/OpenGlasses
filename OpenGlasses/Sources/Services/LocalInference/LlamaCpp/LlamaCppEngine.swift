import Foundation
import LlamaCppWrapper

/// `LlamaEngine` over the vendored C ABI. The only file in the app that calls `og_llama_*`.
///
/// It contains no policy: no clamping, no admission, no template choice, no stop handling. Every
/// decision lives in `LlamaCppLocalInferenceBackend` and its pure helpers, so that the decisions
/// are testable and this file stays a transcription of the header.
///
/// ### Buffer convention
/// The ABI fills caller-owned buffers and answers with the count *written*, the negative count
/// *needed*, or `OG_LLAMA_NOT_FOUND` for a key that does not exist. `fetchString` and `fetchTokens`
/// are the two places that convention is decoded; everything else consumes their results.
final class LlamaCppEngine: LlamaEngine, @unchecked Sendable {

    /// Initial buffer for a metadata or template read. Sized so the common case is one call and a
    /// long Jinja template is two.
    private static let initialTextCapacity: Int32 = 4096

    /// The header's `OG_LLAMA_NOT_FOUND`, restated. It is `#define OG_LLAMA_NOT_FOUND INT32_MIN`,
    /// and a macro defined in terms of another macro's arithmetic does not survive the Clang
    /// importer — so the value is written out here, pinned to the header's text by
    /// `LlamaCppRuntimeTests`.
    static let notFound: Int32 = Int32.min

    /// Constructing this type touches nothing native, deliberately: the app registers a GGUF
    /// backend whether or not `Config.ggufModelsEnabled` is on, and "linked is not enabled" has to
    /// stay true. The wrapper initializes the ggml backends lazily inside `og_llama_model_load` and
    /// `og_llama_context_create`, and its engine logging — which would otherwise write model paths
    /// and tensor names to the device log — is off unless a developer turns it on.
    init() {}

    // MARK: - Handle bridging

    private func model(_ handle: LlamaModelHandle) -> OpaquePointer? {
        OpaquePointer(bitPattern: handle.bits)
    }

    private func context(_ handle: LlamaContextHandle) -> OpaquePointer? {
        OpaquePointer(bitPattern: handle.bits)
    }

    private func sampler(_ handle: LlamaSamplerHandle) -> OpaquePointer? {
        OpaquePointer(bitPattern: handle.bits)
    }

    // MARK: - Model lifecycle

    func loadModel(atPath path: String, options: LlamaModelOptions) throws -> LlamaModelHandle {
        var native = og_llama_model_options_default()
        native.n_gpu_layers = options.gpuLayers
        native.load_mode = options.useMemoryMapping ? OGLlamaLoadModeMmap : OGLlamaLoadModeNone
        native.vocab_only = options.vocabularyOnly
        native.check_tensors = options.checkTensors

        var handle: OpaquePointer?
        let status = path.withCString { cPath in
            withUnsafePointer(to: &native) { optionsPointer in
                og_llama_model_load(cPath, optionsPointer, nil, nil, &handle)
            }
        }
        guard status == OGLlamaStatusOK, let handle else {
            throw LlamaEngineError(status: Int32(truncatingIfNeeded: status.rawValue))
        }
        return LlamaModelHandle(bits: UInt(bitPattern: handle))
    }

    func freeModel(_ model: LlamaModelHandle) {
        og_llama_model_free(self.model(model))
    }

    // MARK: - Metadata

    func metadataValue(_ model: LlamaModelHandle, key: String) -> String? {
        let handle = self.model(model)
        return key.withCString { cKey in
            Self.fetchString { buffer, capacity in
                og_llama_model_metadata_value(handle, cKey, buffer, capacity)
            }
        }
    }

    func chatTemplate(_ model: LlamaModelHandle, named name: String?) -> String? {
        let handle = self.model(model)
        guard let name else {
            return Self.fetchString { buffer, capacity in
                og_llama_model_chat_template(handle, nil, buffer, capacity)
            }
        }
        return name.withCString { cName in
            Self.fetchString { buffer, capacity in
                og_llama_model_chat_template(handle, cName, buffer, capacity)
            }
        }
    }

    func trainingContextTokens(_ model: LlamaModelHandle) -> Int {
        Int(og_llama_model_train_context_length(self.model(model)))
    }

    func vocabularyAddsBOS(_ model: LlamaModelHandle) -> Bool {
        og_llama_vocab_adds_bos(self.model(model))
    }

    func beginningOfSequencePiece(_ model: LlamaModelHandle) -> String? {
        let handle = self.model(model)
        let token = og_llama_token_bos(handle)
        guard token >= 0 else { return nil }
        let bytes = tokenBytes(model, token: token, renderSpecial: true)
        guard !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    func isEndOfGeneration(_ model: LlamaModelHandle, token: LlamaToken) -> Bool {
        og_llama_token_is_eog(self.model(model), token)
    }

    // MARK: - Template and tokenization

    func applyChatTemplate(_ template: String,
                           turns: [LlamaChatTurn],
                           addAssistantHeader: Bool) throws -> String {
        // Each role/content pair must outlive the whole call, and a pointer taken inside a
        // `withUnsafeBufferPointer` would not — so the strings are copied onto the heap here and
        // released on the way out. Nesting scoped accessors per message is the bug this avoids.
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }

        var messages: [OGLlamaChatMessage] = []
        messages.reserveCapacity(turns.count)
        for turn in turns {
            guard let role = strdup(turn.role), let content = strdup(turn.content) else {
                throw LlamaEngineError.allocationFailed
            }
            owned.append(role)
            owned.append(content)
            messages.append(OGLlamaChatMessage(role: UnsafePointer(role),
                                               content: UnsafePointer(content)))
        }

        let rendered = template.withCString { cTemplate -> String? in
            messages.withUnsafeBufferPointer { messagePointer in
                Self.fetchString { buffer, capacity in
                    og_llama_chat_apply_template(cTemplate,
                                                 messagePointer.baseAddress,
                                                 size_t(messagePointer.count),
                                                 addAssistantHeader,
                                                 buffer, capacity)
                }
            }
        }
        guard let rendered else { throw LlamaEngineError.templateFailed }
        return rendered
    }

    func tokenize(_ model: LlamaModelHandle,
                  text: String,
                  addSpecial: Bool,
                  parseSpecial: Bool) throws -> [LlamaToken] {
        let handle = self.model(model)
        let utf8 = Array(text.utf8)
        // An empty prompt is a caller bug, not a tokenizer fault, and the ABI rejects a NULL text
        // pointer — so it is answered here rather than sent down.
        guard !utf8.isEmpty else { return [] }
        let tokens: [LlamaToken]? = text.withCString { cText in
            // The length is the UTF-8 byte count, not the C string's: the ABI takes an explicit
            // length precisely so an embedded NUL cannot truncate a prompt.
            Self.fetchTokens { buffer, capacity in
                og_llama_tokenize(handle, cText, Int32(utf8.count),
                                  addSpecial, parseSpecial, buffer, capacity)
            }
        }
        guard let tokens else { throw LlamaEngineError.tokenizeFailed }
        return tokens
    }

    func tokenBytes(_ model: LlamaModelHandle, token: LlamaToken) -> [UInt8] {
        tokenBytes(model, token: token, renderSpecial: false)
    }

    /// Special tokens are rendered only when the caller is *inspecting* the vocabulary (the BOS
    /// probe). Streamed output never renders them: a control token printed into an assistant reply
    /// is text the wearer did not write and the model did not mean.
    private func tokenBytes(_ model: LlamaModelHandle,
                            token: LlamaToken,
                            renderSpecial: Bool) -> [UInt8] {
        let handle = self.model(model)
        var buffer = [CChar](repeating: 0, count: 64)
        var written = buffer.withUnsafeMutableBufferPointer { pointer in
            og_llama_token_to_piece(handle, token, pointer.baseAddress, Int32(pointer.count),
                                    renderSpecial)
        }
        if written == Self.notFound { return [] }
        if written < 0 {
            buffer = [CChar](repeating: 0, count: Int(-written))
            written = buffer.withUnsafeMutableBufferPointer { pointer in
                og_llama_token_to_piece(handle, token, pointer.baseAddress, Int32(pointer.count),
                                        renderSpecial)
            }
            if written < 0 { return [] }
        }
        return buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }
    }

    // MARK: - Context lifecycle

    func createContext(_ model: LlamaModelHandle,
                       options: LlamaContextOptions) throws -> LlamaContextHandle {
        var native = og_llama_context_options_default()
        native.n_ctx = UInt32(max(0, options.contextTokens))
        native.n_batch = UInt32(max(1, options.batchTokens))
        // The physical batch never exceeds the logical one; a larger ubatch would allocate compute
        // buffers for work that can never arrive.
        native.n_ubatch = min(native.n_ubatch, native.n_batch)
        native.offload_kqv = options.offloadKVCache

        var handle: OpaquePointer?
        let status = withUnsafePointer(to: &native) { optionsPointer in
            og_llama_context_create(self.model(model), optionsPointer, &handle)
        }
        guard status == OGLlamaStatusOK, let handle else {
            throw LlamaEngineError(status: Int32(truncatingIfNeeded: status.rawValue))
        }
        return LlamaContextHandle(bits: UInt(bitPattern: handle))
    }

    func freeContext(_ context: LlamaContextHandle) {
        og_llama_context_free(self.context(context))
    }

    func contextTokens(_ context: LlamaContextHandle) -> Int {
        Int(og_llama_context_length(self.context(context)))
    }

    func batchTokens(_ context: LlamaContextHandle) -> Int {
        Int(og_llama_context_batch_size(self.context(context)))
    }

    func clearMemory(_ context: LlamaContextHandle) {
        og_llama_context_clear_memory(self.context(context))
    }

    func setCancelled(_ context: LlamaContextHandle, _ cancelled: Bool) {
        og_llama_context_set_cancelled(self.context(context), cancelled)
    }

    func synchronize(_ context: LlamaContextHandle) {
        og_llama_context_synchronize(self.context(context))
    }

    func decode(_ context: LlamaContextHandle,
                tokens: [LlamaToken],
                position: Int,
                wantsLogitsForLast: Bool) throws {
        let status = tokens.withUnsafeBufferPointer { pointer in
            og_llama_decode(self.context(context), pointer.baseAddress, Int32(pointer.count),
                            Int32(position), wantsLogitsForLast)
        }
        guard status == OGLlamaStatusOK else { throw LlamaEngineError(status: Int32(truncatingIfNeeded: status.rawValue)) }
    }

    // MARK: - Sampling

    func createSampler(_ model: LlamaModelHandle,
                       options: LlamaSamplerOptions) throws -> LlamaSamplerHandle {
        var native = og_llama_sampler_options_default()
        native.seed = options.seed
        native.temperature = options.temperature
        native.top_k = options.topK
        native.top_p = options.topP
        native.min_p = options.minP
        native.penalty_last_n = options.penaltyWindow
        native.penalty_repeat = options.penaltyRepeat

        var handle: OpaquePointer?
        let status = withUnsafePointer(to: &native) { optionsPointer in
            og_llama_sampler_create(self.model(model), optionsPointer, &handle)
        }
        guard status == OGLlamaStatusOK, let handle else {
            throw LlamaEngineError(status: Int32(truncatingIfNeeded: status.rawValue))
        }
        return LlamaSamplerHandle(bits: UInt(bitPattern: handle))
    }

    func freeSampler(_ sampler: LlamaSamplerHandle) {
        og_llama_sampler_free(self.sampler(sampler))
    }

    func resetSampler(_ sampler: LlamaSamplerHandle) {
        og_llama_sampler_reset(self.sampler(sampler))
    }

    func sample(_ sampler: LlamaSamplerHandle, context: LlamaContextHandle) throws -> LlamaToken {
        var token: LlamaToken = 0
        let status = og_llama_sampler_sample(self.sampler(sampler), self.context(context), -1, &token)
        guard status == OGLlamaStatusOK else { throw LlamaEngineError(status: Int32(truncatingIfNeeded: status.rawValue)) }
        return token
    }

    // MARK: - Buffer convention

    /// Runs a buffer-filling call, growing once if the first attempt was short. `nil` means the
    /// key or template is absent — which is a different answer from an empty string, and callers
    /// depend on the difference.
    private static func fetchString(
        _ fill: (UnsafeMutablePointer<CChar>?, Int32) -> Int32
    ) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(initialTextCapacity))
        var written = buffer.withUnsafeMutableBufferPointer { fill($0.baseAddress, Int32($0.count)) }
        if written == Self.notFound { return nil }
        if written < 0 {
            buffer = [CChar](repeating: 0, count: Int(-written))
            written = buffer.withUnsafeMutableBufferPointer { fill($0.baseAddress, Int32($0.count)) }
            if written < 0 { return nil }
        }
        return String(decoding: buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) },
                      as: UTF8.self)
    }

    private static func fetchTokens(
        _ fill: (UnsafeMutablePointer<LlamaToken>?, Int32) -> Int32
    ) -> [LlamaToken]? {
        var buffer = [LlamaToken](repeating: 0, count: Int(initialTextCapacity))
        var written = buffer.withUnsafeMutableBufferPointer { fill($0.baseAddress, Int32($0.count)) }
        if written == Self.notFound { return nil }
        if written < 0 {
            buffer = [LlamaToken](repeating: 0, count: Int(-written))
            written = buffer.withUnsafeMutableBufferPointer { fill($0.baseAddress, Int32($0.count)) }
            if written < 0 { return nil }
        }
        return Array(buffer.prefix(Int(written)))
    }
}
