import Foundation
import NaturalLanguage

/// On-device text embedding for semantic search over document chunks and memory.
///
/// A thin façade over a swappable [[EmbeddingBackend]]: it prefers the transformer
/// `NLContextualEmbedding` ([[NLContextualBackend]]) when enabled and its asset is on-device, and
/// otherwise falls back to `NLEmbedding` ([[NLEmbeddingBackend]] — sentence model preferred, word
/// average otherwise). The active backend is fixed at init, so every vector a given instance produces
/// shares one dimension and `modelId`: queries and stored vectors stay comparable, and a model swap is
/// caught by the version stamp ([[EmbeddingVersion]]) which triggers a re-embed.
struct Embedder {

    let language: NLLanguage
    /// The script whose text this instance reads (Plan JY P1). Every embedder is Latin except a
    /// script model's (`contextual(for:)`); a passage is compared only with a question vector from
    /// an embedder of its own document's script.
    let script: EmbeddingScript
    private let backend: EmbeddingBackend?

    init(language: NLLanguage = .english) {
        self.language = language
        self.script = .latin
        self.backend = Embedder.selectBackend(language: language)
    }

    /// Which model a caller wants, whatever the app-wide switch says (Plan IV P4).
    enum Preference: Equatable {
        /// The NLEmbedding model: sentence, else the word average.
        case standard
        /// The contextual model when its asset is on the device; the standard model otherwise.
        case contextual
    }

    init(language: NLLanguage = .english, preference: Preference) {
        self.language = language
        self.script = .latin
        switch preference {
        case .standard:
            self.backend = NLEmbeddingBackend(language: language)
        case .contextual:
            self.backend = NLContextualBackend.ready(for: language) ?? NLEmbeddingBackend(language: language)
        }
    }

    /// A given backend — the seam tests use to stand in two models with distinct versions.
    init(language: NLLanguage = .english, backend: EmbeddingBackend?) {
        self.language = language
        self.script = .latin
        self.backend = backend
    }

    /// A given backend standing in for `script`'s model — the seam tests use for a script model.
    init(script: EmbeddingScript, backend: EmbeddingBackend?) {
        self.language = script.contextualLanguage
        self.script = script
        self.backend = backend
    }

    /// The contextual model for a script other than Latin, when its asset is on the phone; nil
    /// otherwise, and for `.latin`, whose choice is the caller's (Plan JY P1). Never another
    /// script's model: a document with no model of its own is searched by its words.
    ///
    /// Not gated by "Smarter manual search" or `contextualEmbeddingEnabled`: those choose between
    /// two Latin models, and a script with no model of its own has no second one to fall back to
    /// (`NLEmbedding` has sentence models for en, fr, es and pt only).
    static func contextual(for script: EmbeddingScript) -> Embedder? {
        guard script != .latin, let backend = NLContextualBackend.ready(for: script.contextualLanguage) else { return nil }
        return Embedder(script: script, backend: backend)
    }

    /// Ask Apple for a script model's asset; true when it is on the phone afterwards. A failed or
    /// offline request returns false. Latin's asset is `prepareFieldAssistAssets`'.
    static func prepareAssets(for script: EmbeddingScript) async -> Bool {
        guard script != .latin else { return false }
        if NLContextualBackend.ready(for: script.contextualLanguage) != nil { return true }
        await NLContextualBackend.prepareAssets(for: script.contextualLanguage)
        return NLContextualBackend.ready(for: script.contextualLanguage) != nil
    }

    /// The embedder Field Assist indexes and searches a vault's manuals with: the contextual model
    /// while "Smarter manual search" is on (the default) and its asset is on the device, the
    /// standard model otherwise. Every other user of embeddings keeps `Embedder()`.
    static func fieldAssist(language: NLLanguage = .english) -> Embedder {
        Embedder(language: language, preference: Config.fieldAssistContextualSearchEnabled ? .contextual : .standard)
    }

    /// Whether the contextual model's asset is on the device.
    static var contextualModelAvailable: Bool { NLContextualBackend.ready(for: .english) != nil }

    /// The contextual model when enabled and its asset is present; otherwise the NLEmbedding baseline.
    private static func selectBackend(language: NLLanguage) -> EmbeddingBackend? {
        if Config.contextualEmbeddingEnabled, let contextual = NLContextualBackend.ready(for: language) {
            return contextual
        }
        return NLEmbeddingBackend(language: language)
    }

    /// True if some embedding model is available for the language.
    var isAvailable: Bool { backend != nil }

    /// True when the NLEmbedding **sentence** model backs this instance. False for the word-average
    /// fallback and for the contextual backend (which is better still).
    var usesSentenceModel: Bool { (backend as? NLEmbeddingBackend)?.usesSentenceModel ?? false }

    /// Vector dimension produced by this instance, or 0 if no model is available.
    var dimension: Int { backend?.dimension ?? 0 }

    /// Stable id for the active model — `nl-sentence.<lang>`, `nl-word.<lang>`, or
    /// `nl-contextual.<modelIdentifier>`. Stamps persisted vectors so a model swap re-embeds rather
    /// than silently comparing across embedding spaces. See [[EmbeddingVersion]].
    var modelId: String { backend?.modelId ?? "none.\(language.rawValue)" }

    /// The version stamp (model id + dimension) for vectors this instance produces.
    var version: EmbeddingVersion { EmbeddingVersion(modelId: modelId, dim: dimension) }

    /// Embed text into a vector, or nil if the model can't represent it (or none is available).
    func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return backend?.embed(trimmed)
    }

    /// Embed a question being searched with (Plan KQ). The same as `embed` for every model but one
    /// trained for retrieval, which reads a question with its own prefix.
    func embedQuery(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return backend?.embedQuery(trimmed)
    }

    /// Cosine similarity in [-1, 1]; 0 when dimensions differ or a vector is empty/zero.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    /// Kick off the contextual model's OTA asset download in the background when enabled, so it
    /// becomes the active backend on the next `Embedder()` once present. No-op when disabled or the
    /// asset is already local. Call once at launch.
    static func prepareContextualAssetsIfEnabled(language: NLLanguage = .english) async {
        guard Config.contextualEmbeddingEnabled else { return }
        await NLContextualBackend.prepareAssets(for: language)
    }

    /// Ask for the contextual model's asset for Field Assist's manual search, when it's switched
    /// on and the asset isn't here. Returns whether the asset is on the device afterwards; a failed
    /// or offline request returns false and the manuals stay on the standard model.
    @discardableResult
    static func prepareFieldAssistAssets(language: NLLanguage = .english) async -> Bool {
        guard Config.fieldAssistContextualSearchEnabled else { return false }
        if NLContextualBackend.ready(for: language) != nil { return true }
        await NLContextualBackend.prepareAssets(for: language)
        return NLContextualBackend.ready(for: language) != nil
    }
}
