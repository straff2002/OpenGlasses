import Foundation
import NaturalLanguage

/// A pluggable text-embedding model behind the [[Embedder]] façade. Lets the active model be swapped
/// (NLEmbedding word/sentence → `NLContextualEmbedding` transformer → a future bundled model) without
/// touching the dozens of call sites that just say `Embedder()`. Each backend reports a stable
/// `modelId` so persisted vectors are stamped (see [[EmbeddingVersion]]) and re-embedded on a swap.
protocol EmbeddingBackend {
    var modelId: String { get }
    var dimension: Int { get }
    /// A passage, a note, a memory: anything stored and searched.
    func embed(_ text: String) -> [Float]?
    /// A question being searched with (Plan KQ). A model trained for retrieval reads a question and
    /// a passage with different prefixes; every other model embeds both the same way.
    func embedQuery(_ text: String) -> [Float]?
    /// Whether the store may embed with this backend off the main thread (Plan KQ P2). Apple's
    /// models keep running where they always have; a backend says yes only when it is safe and
    /// slow enough to matter.
    var isSafeOffMainThread: Bool { get }
}

extension EmbeddingBackend {
    func embedQuery(_ text: String) -> [Float]? { embed(text) }
    var isSafeOffMainThread: Bool { false }
}

/// The classic on-device path: `NLEmbedding.sentenceEmbedding` (preferred) with an averaged
/// `wordEmbedding` fallback. Lookup-based, non-contextual — the baseline the contextual model improves
/// on. This is the same logic the original `Embedder` shipped; it stays the universal fallback.
final class NLEmbeddingBackend: EmbeddingBackend {
    private let language: NLLanguage
    private let sentenceEmbedding: NLEmbedding?
    private let wordEmbedding: NLEmbedding?

    init?(language: NLLanguage) {
        let sentence = NLEmbedding.sentenceEmbedding(for: language)
        let word = NLEmbedding.wordEmbedding(for: language)
        guard sentence != nil || word != nil else { return nil }
        self.language = language
        self.sentenceEmbedding = sentence
        self.wordEmbedding = word
    }

    var usesSentenceModel: Bool { sentenceEmbedding != nil }
    var dimension: Int { sentenceEmbedding?.dimension ?? wordEmbedding?.dimension ?? 0 }
    var modelId: String { "\(usesSentenceModel ? "nl-sentence" : "nl-word").\(language.rawValue)" }

    func embed(_ text: String) -> [Float]? {
        if let sentence = sentenceEmbedding {
            guard let vec = sentence.vector(for: text) else { return nil }
            return vec.map { Float($0) }
        }
        return wordAverage(text)
    }

    private func wordAverage(_ text: String) -> [Float]? {
        guard let model = wordEmbedding else { return nil }
        let words = text.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        for word in words {
            guard let vec = model.vector(for: word) else { continue }
            for i in 0..<min(vec.count, sum.count) { sum[i] += vec[i] }
            count += 1
        }
        guard count > 0 else { return nil }
        return sum.map { Float($0 / Double(count)) }
    }
}

/// Transformer **contextual** embedding (`NLContextualEmbedding`, iOS 17+). Produces per-token vectors
/// which we mean-pool into one passage vector — markedly better than the lookup-based `NLEmbedding`
/// for retrieval, multilingual, with no SPM dependency.
///
/// The model loads an over-the-air asset on first use, so a backend is only `ready` once
/// `hasAvailableAssets` is true and `load()` succeeds. Loading is expensive, so a loaded model is
/// cached process-wide per language. `prepareAssets` triggers the download in the background; until it
/// lands, [[Embedder]] uses the `NLEmbedding` fallback.
final class NLContextualBackend: EmbeddingBackend {
    private let model: NLContextualEmbedding
    let modelId: String
    var dimension: Int { model.dimension }

    private init(model: NLContextualEmbedding) {
        self.model = model
        self.modelId = "nl-contextual.\(model.modelIdentifier)"
    }

    /// The mean of the token vectors. The model reads at most `maximumSequenceLength` tokens (256)
    /// and drops the rest silently; measured on two manuals, a sixth of the 200 longest chunks
    /// reached that limit (Plan IV P4). So a text the model would cut is split in two at a sentence (else a
    /// word) and each half embedded, recursively, and the token vectors of every piece are pooled
    /// together — nothing past the limit is lost, and a short text is embedded exactly as before.
    func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var sum = [Float](repeating: 0, count: model.dimension)
        var tokens = 0
        accumulate(trimmed, into: &sum, tokens: &tokens, depth: 0)
        guard tokens > 0 else { return nil }
        return sum.map { $0 / Float(tokens) }   // mean-pool the token vectors
    }

    private func accumulate(_ text: String, into sum: inout [Float], tokens: inout Int, depth: Int) {
        guard let result = try? model.embeddingResult(for: text, language: nil) else { return }
        if result.sequenceLength >= model.maximumSequenceLength, depth < 6,
           let (first, second) = ContextualInput.halves(of: text) {
            accumulate(first, into: &sum, tokens: &tokens, depth: depth + 1)
            accumulate(second, into: &sum, tokens: &tokens, depth: depth + 1)
            return
        }
        let dim = sum.count
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for i in 0..<min(vector.count, dim) { sum[i] += Float(vector[i]) }
            tokens += 1
            return true
        }
    }

    // MARK: - Process-wide cache + assets

    private static let lock = NSLock()
    private static var cache: [String: NLContextualBackend] = [:]
    /// When a load last failed with the asset present, per language. A search asks for a script's
    /// model once per call (Plan JY P1), so a model that cannot load is not retried — at a tenth
    /// of a second each — more than once a minute.
    private static var failedLoads: [String: Date] = [:]
    private static let loadRetryInterval: TimeInterval = 60

    /// A ready-to-use backend for the language, or nil if assets aren't on-device yet (caller falls
    /// back). Loads the model once and caches it; never blocks on a network download.
    static func ready(for language: NLLanguage) -> NLContextualBackend? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[language.rawValue] { return cached }
        if let failed = failedLoads[language.rawValue], Date().timeIntervalSince(failed) < loadRetryInterval { return nil }
        guard let model = NLContextualEmbedding(language: language), model.hasAvailableAssets else { return nil }
        do { try model.load() } catch {
            failedLoads[language.rawValue] = Date()
            return nil
        }
        failedLoads[language.rawValue] = nil
        let backend = NLContextualBackend(model: model)
        cache[language.rawValue] = backend
        return backend
    }

    /// Whether the language's asset is on the device, without loading the model — for a check
    /// that only reports or decides whether to download (Plan JY P1). Loading is `ready(for:)`'s.
    static func hasAssets(for language: NLLanguage) -> Bool {
        lock.lock()
        let cached = cache[language.rawValue] != nil
        lock.unlock()
        return cached || (NLContextualEmbedding(language: language)?.hasAvailableAssets ?? false)
    }

    /// Trigger an OTA asset download for the language if it isn't present. Best-effort; call at launch
    /// when contextual embeddings are enabled so the model becomes available without blocking a query.
    static func prepareAssets(for language: NLLanguage) async {
        guard let model = NLContextualEmbedding(language: language), !model.hasAvailableAssets else { return }
        _ = try? await model.requestAssets()
    }
}

/// Splitting a text the contextual model would cut (Plan IV P4). Pure, so the split is tested
/// without the model.
enum ContextualInput {

    /// The text in two parts at the sentence end nearest its middle, else at the space nearest
    /// it; nil for a single word. Neither part is empty, and together they hold every word.
    static func halves(of text: String) -> (String, String)? {
        let middle = text.count / 2
        var best: String.Index?
        var bestDistance = Int.max
        func consider(_ index: String.Index) {
            let distance = abs(text.distance(from: text.startIndex, to: index) - middle)
            if distance < bestDistance { best = index; bestDistance = distance }
        }
        var i = text.startIndex
        while i < text.endIndex {
            let next = text.index(after: i)
            if ".!?;\n".contains(text[i]), next < text.endIndex, text[next].isWhitespace { consider(next) }
            i = next
        }
        if best == nil {
            for index in text.indices where text[index] == " " { consider(index) }
        }
        guard let cut = best else { return nil }
        let first = text[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
        let second = text[cut...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty, !second.isEmpty else { return nil }
        return (first, second)
    }
}
