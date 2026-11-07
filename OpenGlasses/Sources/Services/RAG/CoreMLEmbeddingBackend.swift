import CoreML
import Foundation

/// The search-trained embedder (Plan KQ): EmbeddingGemma 2's text encoder as a Core ML package,
/// converted by `Scripts/kq-embedder/convert.py`. The package takes token ids (1 to 512) and a
/// mask, and returns one L2-normalised 768-value vector, mean-pooled over every token.
///
/// - **CPU only.** Never the GPU (Metal is forbidden in the background, where questions are
///   embedded with the phone locked) and never the Neural Engine (it computes in fp16, which moves
///   every vector of this model: Plan KQ P0, median cosine 0.978).
/// - **A question and a passage are read differently.** The model was trained with a prefix for
///   each, so `embedQuery` and `embed` add their own.
/// - **Shorter vectors** are the leading `dimension` values, re-normalised, as the model was
///   trained (768, 512, 256 or 128).
/// - **Long text** past the package's 512 tokens is split in two at a sentence (else a word), as
///   the contextual backend does, and the halves' vectors are averaged by token count.
///
/// The tokenizer is injected: `swift-transformers` in the app, a reference tokenizer in the Mac
/// runner. P0 measured them identical on every test text.
final class CoreMLEmbeddingBackend: EmbeddingBackend {

    static let queryPrefix = "task: search result | query: "
    static let documentPrefix = "title: none | text: "
    static let maxTokens = 512
    static let supportedDimensions = [768, 512, 256, 128]
    /// CPU only: never the GPU (forbidden in the background) or the Neural Engine (fp16). A test
    /// pins it.
    static let computeUnits: MLComputeUnits = .cpuOnly

    let modelId: String
    let dimension: Int
    private let model: MLModel
    private let tokenize: (String) -> [Int]

    /// A compiled model (`.mlmodelc`) on the CPU, or nil when it can't load or the dimension isn't
    /// one the model was trained for.
    init?(compiledModel url: URL, dimension: Int = 768, tokenize: @escaping (String) -> [Int]) {
        guard Self.supportedDimensions.contains(dimension) else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = Self.computeUnits
        guard let model = try? MLModel(contentsOf: url, configuration: configuration) else { return nil }
        self.model = model
        self.dimension = dimension
        self.tokenize = tokenize
        self.modelId = Self.modelId(dimension: dimension)
    }

    static func modelId(dimension: Int) -> String { "eg2-text.\(dimension)" }

    func embed(_ text: String) -> [Float]? { vector(Self.documentPrefix, text) }

    func embedQuery(_ text: String) -> [Float]? { vector(Self.queryPrefix, text) }

    // MARK: - Pure helpers

    /// The leading `dimension` values, re-normalised; nil for an empty or zero vector.
    static func truncated(_ vector: [Float], to dimension: Int) -> [Float]? {
        let head = Array(vector.prefix(dimension))
        let norm = head.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return head.map { $0 / norm }
    }

    /// The token-count-weighted mean of unit vectors, re-normalised: how a split text's halves
    /// become one vector. Nil when nothing is finite.
    static func pooled(_ parts: [(vector: [Float], tokens: Int)]) -> [Float]? {
        guard let width = parts.first?.vector.count, width > 0 else { return nil }
        var sum = [Float](repeating: 0, count: width)
        for part in parts where part.vector.count == width {
            for i in 0..<width { sum[i] += part.vector[i] * Float(part.tokens) }
        }
        return truncated(sum, to: width)
    }

    // MARK: - Running the model

    private func vector(_ prefix: String, _ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var parts: [(vector: [Float], tokens: Int)] = []
        accumulate(prefix, trimmed, into: &parts, depth: 0)
        guard let full = Self.pooled(parts) else { return nil }
        return Self.truncated(full, to: dimension)
    }

    private func accumulate(_ prefix: String, _ text: String, into parts: inout [(vector: [Float], tokens: Int)], depth: Int) {
        let ids = tokenize(prefix + text)
        guard !ids.isEmpty else { return }
        if ids.count > Self.maxTokens, depth < 6, let (first, second) = ContextualInput.halves(of: text) {
            accumulate(prefix, first, into: &parts, depth: depth + 1)
            accumulate(prefix, second, into: &parts, depth: depth + 1)
            return
        }
        let kept = Array(ids.prefix(Self.maxTokens))
        guard let vector = predict(kept), vector.allSatisfy({ $0.isFinite }) else { return }
        parts.append((vector, kept.count))
    }

    private func predict(_ ids: [Int]) -> [Float]? {
        let shape = [1, NSNumber(value: ids.count)] as [NSNumber]
        guard let input = try? MLMultiArray(shape: shape, dataType: .int32),
              let mask = try? MLMultiArray(shape: shape, dataType: .float32) else { return nil }
        let inputs = input.dataPointer.bindMemory(to: Int32.self, capacity: ids.count)
        let ones = mask.dataPointer.bindMemory(to: Float.self, capacity: ids.count)
        for (i, id) in ids.enumerated() {
            inputs[i] = Int32(truncatingIfNeeded: id)
            ones[i] = 1
        }
        guard let features = try? MLDictionaryFeatureProvider(dictionary: ["input_ids": input, "attention_mask": mask]),
              let output = try? model.prediction(from: features),
              let array = output.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        return (0..<array.count).map { array[$0].floatValue }
    }
}
