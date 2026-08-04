import CoreML
import Foundation

/// Core ML wrapper for the converted fingerspelling CTC model (Plan CK P2): a fixed
/// `(1, 768, 1629)` feature window plus a `(1, 768)` validity mask in, `(1, 384, 62)` CTC
/// logits out. Compiles the downloaded `.mlpackage` on first use (Core ML loads only
/// compiled `.mlmodelc` bundles) and caches the result next to it, keyed by the package's
/// modification date so a re-downloaded artefact recompiles.
///
/// `logits(for:)` matches `FingerspellingLiveDecoder.Inference`, so the engine drops
/// straight into the live decode loop; tests stub the closure instead of loading a model.
final class FingerspellingInferenceEngine {

    enum EngineError: LocalizedError {
        case unexpectedOutput(String)

        var errorDescription: String? {
            switch self {
            case .unexpectedOutput(let detail):
                return "Fingerspelling model returned unexpected output (\(detail))"
            }
        }
    }

    private let model: MLModel

    /// Loads (compiling if necessary) the model package downloaded by
    /// `FingerspellingModelDownloader`.
    init(modelPackageURL: URL,
         configuration: MLModelConfiguration = MLModelConfiguration(),
         fileManager: FileManager = .default) throws {
        let compiledURL = try Self.compiledModelURL(for: modelPackageURL, fileManager: fileManager)
        self.model = try MLModel(contentsOf: compiledURL, configuration: configuration)
    }

    /// Compile-and-cache: `<package dir>/<name>.mlmodelc`, invalidated when the package is
    /// newer than the cached compile.
    static func compiledModelURL(for packageURL: URL,
                                 fileManager: FileManager = .default) throws -> URL {
        let cachedURL = packageURL.deletingPathExtension().appendingPathExtension("mlmodelc")

        func modificationDate(_ url: URL) -> Date? {
            (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        }
        if fileManager.fileExists(atPath: cachedURL.path),
           let cached = modificationDate(cachedURL), let source = modificationDate(packageURL),
           cached >= source {
            return cachedURL
        }

        let compiled = try MLModel.compileModel(at: packageURL)
        try? fileManager.removeItem(at: cachedURL)
        try fileManager.moveItem(at: compiled, to: cachedURL)
        return cachedURL
    }

    /// Run one window. Returns all 384 logit rows as `[row][class]`.
    func logits(for input: HolisticWindower.ModelInput) throws -> [[Float]] {
        let features = try MLMultiArray(shape: [1,
                                                NSNumber(value: HolisticWindower.windowLength),
                                                NSNumber(value: HolisticLayout.featuresPerFrame)],
                                        dataType: .float32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: HolisticWindower.windowLength)],
                                    dataType: .float32)
        precondition(input.features.count == features.count && input.mask.count == mask.count,
                     "ModelInput buffers must match the fixed window shape")
        input.features.withUnsafeBufferPointer { buffer in
            features.dataPointer.assumingMemoryBound(to: Float.self)
                .update(from: buffer.baseAddress!, count: buffer.count)
        }
        input.mask.withUnsafeBufferPointer { buffer in
            mask.dataPointer.assumingMemoryBound(to: Float.self)
                .update(from: buffer.baseAddress!, count: buffer.count)
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "features": MLFeatureValue(multiArray: features),
            "mask": MLFeatureValue(multiArray: mask),
        ])
        let prediction = try model.prediction(from: provider)

        guard let outputName = prediction.featureNames.first,
              let output = prediction.featureValue(for: outputName)?.multiArrayValue else {
            throw EngineError.unexpectedOutput("no multi-array output")
        }
        guard output.shape.count == 3, output.shape[0] == 1 else {
            throw EngineError.unexpectedOutput("shape \(output.shape)")
        }
        let rowCount = output.shape[1].intValue
        let classCount = output.shape[2].intValue

        var rows = [[Float]]()
        rows.reserveCapacity(rowCount)
        if output.dataType == .float32 {
            let base = output.dataPointer.assumingMemoryBound(to: Float.self)
            for row in 0..<rowCount {
                rows.append(Array(UnsafeBufferPointer(start: base + row * classCount,
                                                      count: classCount)))
            }
        } else {
            // Defensive slow path for other output dtypes (e.g. float16).
            for row in 0..<rowCount {
                var values = [Float]()
                values.reserveCapacity(classCount)
                for cls in 0..<classCount {
                    values.append(output[[0, row as NSNumber, cls as NSNumber]].floatValue)
                }
                rows.append(values)
            }
        }
        return rows
    }
}
