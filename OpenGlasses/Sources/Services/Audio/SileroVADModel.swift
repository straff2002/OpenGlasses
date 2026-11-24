import Foundation
import CoreML

/// Plan CU P2 PR2 — one utterance's streaming scoring state. The model is stateless; its LSTM
/// state is threaded through here, chunk by chunk, strictly in order.
protocol SpeechChunkScoringSession: AnyObject {
    /// Score one chunk (`SpeechHopChunker.chunkSamples` long: context, then the new hop) and carry
    /// the state into the next call. A speech probability, 0…1.
    func score(_ samples: [Float]) throws -> Float
    /// Forget the streaming state — a new utterance, or a format change mid-utterance.
    func resetState()
}

/// Something that can score chunks: the bundled model, or a scripted stand-in in tests.
protocol SpeechChunkScoring: AnyObject, Sendable {
    func makeSession() -> SpeechChunkScoringSession
}

/// Plan CU P2 PR2 — the bundled Silero VAD (MIT, Silero Team), as a Core ML conversion that takes
/// a 256 ms hop with 64 samples of context and returns a speech probability plus the LSTM state
/// to carry into the next hop.
///
/// **Bundled, compiled, and loaded from the app bundle only.** The model ships inside the app as
/// `silero-vad-unified-256ms-v6.2.1.mlmodelc`; nothing here reaches the network, and there is no
/// second place a model can come from. A model that is missing or will not load throws, and the
/// detector soft-fails: `isAvailable` stays false and the silence timer keeps the turn.
final class SileroVADModel: SpeechChunkScoring, @unchecked Sendable {

    static let resourceName = "silero-vad-unified-256ms-v6.2.1"
    static let stateSize = 128

    enum LoadError: Error, Equatable {
        case notBundled
        /// The model's inputs or outputs are not the ones this runner was written against.
        case unexpectedInterface(String)
        case unexpectedOutput(String)
    }

    /// The feature names, read from the model's own description: exact names first, a substring
    /// match as the fallback, so a re-export that renames a feature still loads or fails loudly.
    struct FeatureNames: Equatable {
        var audio: String
        var hidden: String
        var cell: String
        var probability: String
        var newHidden: String
        var newCell: String

        static func resolve(inputs: [String], outputs: [String]) throws -> FeatureNames {
            func pick(_ names: [String], exact: String, containing: String,
                      excluding: [String] = []) throws -> String {
                if names.contains(exact) { return exact }
                let match = names.filter { name in
                    let lower = name.lowercased()
                    return lower.contains(containing) && !excluding.contains { lower.contains($0) }
                }
                guard match.count == 1, let only = match.first else {
                    throw LoadError.unexpectedInterface(exact)
                }
                return only
            }
            return FeatureNames(
                audio: try pick(inputs, exact: "audio_input", containing: "audio"),
                hidden: try pick(inputs, exact: "hidden_state", containing: "hidden"),
                cell: try pick(inputs, exact: "cell_state", containing: "cell"),
                probability: try pick(outputs, exact: "vad_output", containing: "vad",
                                      excluding: ["hidden", "cell"]),
                newHidden: try pick(outputs, exact: "new_hidden_state", containing: "hidden"),
                newCell: try pick(outputs, exact: "new_cell_state", containing: "cell"))
        }
    }

    let model: MLModel
    let names: FeatureNames

    /// Where the bundled model lives, or nil when it is not in the bundle.
    static func bundledURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: resourceName, withExtension: "mlmodelc")
    }

    /// Load the bundled model. Blocking — call it off the main thread.
    static func loadBundled(from bundle: Bundle = .main) throws -> SileroVADModel {
        guard let url = bundledURL(in: bundle) else { throw LoadError.notBundled }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return try SileroVADModel(model: MLModel(contentsOf: url, configuration: configuration))
    }

    init(model: MLModel) throws {
        self.model = model
        let description = model.modelDescription
        names = try FeatureNames.resolve(inputs: Array(description.inputDescriptionsByName.keys),
                                         outputs: Array(description.outputDescriptionsByName.keys))
    }

    func makeSession() -> SpeechChunkScoringSession { SileroVADSession(model: self) }

    /// One prediction: the chunk and the carried state in, the probability and the next state out.
    func predict(audio: [Float], hidden: [Float], cell: [Float]) throws
        -> (probability: Float, hidden: [Float], cell: [Float]) {
        let inputs = try MLDictionaryFeatureProvider(dictionary: [
            names.audio: MLFeatureValue(multiArray: try Self.array(audio)),
            names.hidden: MLFeatureValue(multiArray: try Self.array(hidden)),
            names.cell: MLFeatureValue(multiArray: try Self.array(cell)),
        ])
        let result = try model.prediction(from: inputs)
        guard let probability = result.featureValue(for: names.probability)?.multiArrayValue,
              probability.count >= 1 else {
            throw LoadError.unexpectedOutput(names.probability)
        }
        let newHidden = try Self.state(result, names.newHidden)
        let newCell = try Self.state(result, names.newCell)
        let p = probability[0].floatValue
        return (p.isFinite ? min(max(p, 0), 1) : 0, newHidden, newCell)
    }

    private static func array(_ values: [Float]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .float32)
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        values.withUnsafeBufferPointer { source in
            pointer.update(from: source.baseAddress!, count: values.count)
        }
        return array
    }

    private static func state(_ result: MLFeatureProvider, _ name: String) throws -> [Float] {
        guard let array = result.featureValue(for: name)?.multiArrayValue,
              array.count == stateSize else {
            throw LoadError.unexpectedOutput(name)
        }
        // Subscripting reads through the array's own strides and data type (Float16 or Float32).
        return (0..<stateSize).map { array[$0].floatValue }
    }
}

/// The LSTM state for one utterance. Zeros at the start, and again after a format change.
final class SileroVADSession: SpeechChunkScoringSession {
    private let model: SileroVADModel
    private(set) var hidden: [Float]
    private(set) var cell: [Float]

    init(model: SileroVADModel) {
        self.model = model
        hidden = [Float](repeating: 0, count: SileroVADModel.stateSize)
        cell = [Float](repeating: 0, count: SileroVADModel.stateSize)
    }

    func score(_ samples: [Float]) throws -> Float {
        let result = try model.predict(audio: samples, hidden: hidden, cell: cell)
        hidden = result.hidden
        cell = result.cell
        return result.probability
    }

    func resetState() {
        for i in 0..<hidden.count { hidden[i] = 0 }
        for i in 0..<cell.count { cell[i] = 0 }
    }
}
