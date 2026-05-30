import Foundation
import NaturalLanguage

/// On-device text embedding for semantic search over document chunks.
///
/// Prefers `NLEmbedding.sentenceEmbedding` (markedly better for multi-sentence passages) and
/// falls back to averaged word vectors only when no sentence model exists for the language.
/// The mode is fixed at init, so every vector a given instance produces has the same dimension —
/// queries and stored chunks are always comparable.
///
/// Kept separate from `SemanticMemoryStore`'s word-average embedding on purpose: documents live
/// in their own store with their own vectors, so this can use the better sentence model without a
/// re-embed migration of existing memory vectors.
struct Embedder {

    let language: NLLanguage
    private let sentenceEmbedding: NLEmbedding?
    private let wordEmbedding: NLEmbedding?

    init(language: NLLanguage = .english) {
        self.language = language
        self.sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: language)
        self.wordEmbedding = NLEmbedding.wordEmbedding(for: language)
    }

    /// True if some embedding model is available for the language.
    var isAvailable: Bool { sentenceEmbedding != nil || wordEmbedding != nil }

    /// True when the (better) sentence model backs this instance.
    var usesSentenceModel: Bool { sentenceEmbedding != nil }

    /// Vector dimension produced by this instance, or 0 if no model is available.
    var dimension: Int { sentenceEmbedding?.dimension ?? wordEmbedding?.dimension ?? 0 }

    /// Embed text into a vector, or nil if the model can't represent it (or none is available).
    /// Never mixes models: sentence-backed instances return sentence vectors (or nil), word-backed
    /// instances return word-average vectors (or nil).
    func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let sentence = sentenceEmbedding {
            guard let vec = sentence.vector(for: trimmed) else { return nil }
            return vec.map { Float($0) }
        }
        return wordAverage(trimmed)
    }

    private func wordAverage(_ text: String) -> [Float]? {
        guard let model = wordEmbedding else { return nil }
        let words = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
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
}
