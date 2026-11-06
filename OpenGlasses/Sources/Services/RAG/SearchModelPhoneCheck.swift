import CoreML
import Foundation
import Tokenizers
import UIKit

/// The phone half of Plan KQ P0: does the search-trained embedder (EmbeddingGemma 2's text encoder,
/// converted by `Scripts/kq-embedder`) run on this iPhone fast enough, small enough, and give the
/// same vectors as the reference?
///
/// A developer check, not a feature. Nothing in the app embeds with this model yet. The files are
/// copied by hand into `Documents/search-model-check/` (see `Scripts/kq-embedder/README.md`):
/// - `eg2-text-int8.mlpackage`, the converted model;
/// - `tokenizer.json`, `tokenizer_config.json` and `config.json`, from the model's repository;
/// - `phone-check.json`, written by `parity.py`: invented sentences, their reference token ids and
///   reference vectors.
///
/// The model runs on the CPU only, never the GPU (Metal is forbidden in the background) and never
/// the Neural Engine (it computes in fp16, which the model card and the Mac check show degrades
/// every vector). The report holds counts and timings only, never a sentence.
enum SearchModelPhoneCheck {

    static let folderName = "search-model-check"
    static let packageName = "eg2-text-int8.mlpackage"
    static let maxTokens = 512

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// The files the check needs that aren't in the folder; empty when it can run.
    static func missingFiles(in folder: URL = folder) -> [String] {
        [packageName, "tokenizer.json", "tokenizer_config.json", "config.json", "phone-check.json"]
            .filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    // MARK: - Pure core

    struct Item: Decodable {
        let kind: String
        let text: String
        let ids: [Int]
        let reference: [Float]
    }

    struct Payload: Decodable {
        let dimension: Int
        let items: [Item]
    }

    /// Cosine of two vectors cut to their first `dimension` values (the model's shorter vectors are
    /// leading slices, re-normalised; cosine re-normalises by itself). 0 when either is empty.
    static func cosine(_ a: [Float], _ b: [Float], dimension: Int? = nil) -> Float {
        let n = min(dimension ?? a.count, a.count, b.count)
        guard n > 0 else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    static func isFinite(_ v: [Float]) -> Bool { !v.isEmpty && v.allSatisfy { $0.isFinite } }

    /// The value at a fraction of the sorted list (0.5 = median, 0.9 = p90); 0 for an empty list.
    static func quantile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * q).rounded())))
        return sorted[index]
    }

    /// Parity of produced vectors against the reference: NaN count, then min / median cosine and how
    /// many fall below 0.999, among the finite ones, at one dimension.
    struct Parity: Equatable {
        let nonFinite: Int
        let minimum: Float
        let median: Float
        let below999: Int
    }

    static func parity(reference: [[Float]], produced: [[Float]], dimension: Int) -> Parity {
        let pairs = zip(reference, produced)
        let nonFinite = produced.filter { !isFinite($0) }.count
        let sims = pairs.filter { isFinite($0.1) }.map { cosine($0.0, $0.1, dimension: dimension) }.sorted()
        guard !sims.isEmpty else { return Parity(nonFinite: nonFinite, minimum: 0, median: 0, below999: 0) }
        return Parity(nonFinite: nonFinite, minimum: sims[0], median: sims[sims.count / 2],
                      below999: sims.filter { $0 < 0.999 }.count)
    }

    static func megabytes(_ bytes: Int64) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }

    // MARK: - Running it

    enum CheckError: LocalizedError {
        case missing([String])
        case badOutput

        var errorDescription: String? {
            switch self {
            case .missing(let files): return "Missing in Documents/\(SearchModelPhoneCheck.folderName): \(files.joined(separator: ", "))"
            case .badOutput: return "The model returned no embedding."
            }
        }
    }

    /// A loaded model and tokenizer, CPU only.
    final class Encoder {
        let model: MLModel
        let tokenizer: Tokenizer

        init(model: MLModel, tokenizer: Tokenizer) {
            self.model = model
            self.tokenizer = tokenizer
        }

        static func load(from folder: URL) async throws -> (Encoder, compileSeconds: Double, tokenizerSeconds: Double) {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            var start = Date()
            let compiled = try await MLModel.compileModel(at: folder.appendingPathComponent(packageName))
            let model = try await MLModel.load(contentsOf: compiled, configuration: configuration)
            let compileSeconds = Date().timeIntervalSince(start)
            start = Date()
            let tokenizer = try await AutoTokenizer.from(modelFolder: folder)
            let tokenizerSeconds = Date().timeIntervalSince(start)
            return (Encoder(model: model, tokenizer: tokenizer), compileSeconds, tokenizerSeconds)
        }

        func ids(for text: String) -> [Int] {
            Array(tokenizer.encode(text: text, addSpecialTokens: true).prefix(maxTokens))
        }

        func embed(ids: [Int]) throws -> [Float] {
            let shape = [1, NSNumber(value: ids.count)] as [NSNumber]
            let input = try MLMultiArray(shape: shape, dataType: .int32)
            let mask = try MLMultiArray(shape: shape, dataType: .float32)
            for (i, id) in ids.enumerated() {
                input[i] = NSNumber(value: Int32(id))
                mask[i] = 1
            }
            let features = try MLDictionaryFeatureProvider(dictionary: ["input_ids": input, "attention_mask": mask])
            let output = try model.prediction(from: features)
            guard let vector = output.featureValue(for: "embedding")?.multiArrayValue else { throw CheckError.badOutput }
            return (0..<vector.count).map { vector[$0].floatValue }
        }
    }

    /// The full check: load, tokenizer parity, then every text embedded twice (the first pass is
    /// cold) with latency, memory and vector parity. Returns report lines.
    static func run(folder: URL = folder) async throws -> [String] {
        let missing = missingFiles(in: folder)
        guard missing.isEmpty else { throw CheckError.missing(missing) }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: folder.appendingPathComponent("phone-check.json")))

        let before = MemoryHeadroom.appFootprintBytes()
        let (encoder, compileSeconds, tokenizerSeconds) = try await Encoder.load(from: folder)
        let afterLoad = MemoryHeadroom.appFootprintBytes()

        var lines: [String] = []
        lines.append("device \(deviceModel()), iOS \(UIDevice.current.systemVersion), CPU only")
        lines.append(String(format: "model compile + load %.2f s, tokenizer load %.2f s", compileSeconds, tokenizerSeconds))
        lines.append("memory: before \(megabytes(before)), after load \(megabytes(afterLoad))")

        var mismatched = 0
        for item in payload.items where encoder.ids(for: item.text) != item.ids { mismatched += 1 }
        lines.append("tokenizer: \(mismatched) of \(payload.items.count) texts differ from the reference ids")

        var peak = afterLoad
        var produced: [[Float]] = []
        var cold: [Double] = []
        var warm: [Double] = []
        var questionWarm: [Double] = []
        var longest: (tokens: Int, seconds: Double) = (0, 0)
        for pass in 0..<2 {
            for item in payload.items {
                let start = Date()
                let vector = try encoder.embed(ids: encoder.ids(for: item.text))
                let seconds = Date().timeIntervalSince(start)
                peak = max(peak, MemoryHeadroom.appFootprintBytes())
                if pass == 0 {
                    cold.append(seconds)
                    produced.append(vector)
                } else {
                    warm.append(seconds)
                    if item.kind == "query" { questionWarm.append(seconds) }
                    if item.ids.count > longest.tokens { longest = (item.ids.count, seconds) }
                }
            }
        }
        let ms = { (s: Double) in String(format: "%.0f ms", s * 1000) }
        lines.append("first text \(ms(cold.first ?? 0)); first pass median \(ms(quantile(cold, 0.5)))")
        lines.append("warm: median \(ms(quantile(warm, 0.5))), p90 \(ms(quantile(warm, 0.9))), max \(ms(warm.max() ?? 0))")
        lines.append("warm questions: median \(ms(quantile(questionWarm, 0.5))), p90 \(ms(quantile(questionWarm, 0.9)))")
        lines.append("longest text \(longest.tokens) tokens: \(ms(longest.seconds))")
        lines.append("memory peak \(megabytes(peak)) (+\(megabytes(peak - before)) over before)")

        let reference = payload.items.map(\.reference)
        for dimension in [768, 256] {
            let p = parity(reference: reference, produced: produced, dimension: dimension)
            lines.append(String(format: "parity %d: NaN %d of %d, min %.5f, median %.5f, below 0.999 %d",
                                dimension, p.nonFinite, produced.count, p.minimum, p.median, p.below999))
        }
        return lines
    }

    /// One question embedded after `delay` seconds, inside a background task, so the wearer can lock
    /// the phone first. Reports the app's state at the moment of embedding and whether it worked.
    @MainActor
    static func runOneQuestionLater(delay: TimeInterval = 15, folder: URL = folder) async -> [String] {
        let task = UIApplication.shared.beginBackgroundTask(withName: "search-model-check")
        defer { UIApplication.shared.endBackgroundTask(task) }
        do {
            let missing = missingFiles(in: folder)
            guard missing.isEmpty else { throw CheckError.missing(missing) }
            let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: folder.appendingPathComponent("phone-check.json")))
            let questions = Array(payload.items.filter { $0.kind == "query" }.prefix(5))
            guard !questions.isEmpty else { return ["no question in phone-check.json"] }
            let (encoder, _, _) = try await Encoder.load(from: folder)
            // One warm-up while still in front, so the first locked embed isn't the model's first ever.
            _ = try encoder.embed(ids: encoder.ids(for: questions[0].text))
            let beforeSleep = MemoryHeadroom.appFootprintBytes()
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            let afterSleep = MemoryHeadroom.appFootprintBytes()
            let state = UIApplication.shared.applicationState
            let protectedData = UIApplication.shared.isProtectedDataAvailable
            let thermal = ProcessInfo.processInfo.thermalState
            var lines = [
                "app state at embedding: \(state == .background ? "background" : state == .inactive ? "inactive" : "active"); "
                    + "protected data \(protectedData ? "available" : "locked"); thermal \(thermal.rawValue); "
                    + "low power \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")",
                "memory before sleep \(megabytes(beforeSleep)), after \(megabytes(afterSleep))",
            ]
            for priority in [TaskPriority.userInitiated, .background] {
                var timings: [String] = []
                var worst: Float = 1
                for item in questions {
                    let start = Date()
                    let vector = try await Task.detached(priority: priority) { try encoder.embed(ids: encoder.ids(for: item.text)) }.value
                    timings.append(String(format: "%.0f", Date().timeIntervalSince(start) * 1000))
                    worst = min(worst, isFinite(vector) ? cosine(item.reference, vector) : 0)
                }
                lines.append("\(priority == .background ? "background" : "user-initiated") priority, ms each: "
                             + timings.joined(separator: ", ") + String(format: "; worst parity %.5f", worst))
            }
            lines.append("memory after embedding \(megabytes(MemoryHeadroom.appFootprintBytes()))")
            return lines
        } catch {
            return ["failed: \(String(describing: error))"]
        }
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
