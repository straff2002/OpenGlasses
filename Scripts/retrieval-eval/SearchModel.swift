import CoreML
import CryptoKit
import Foundation

// Plan KQ P1: the search-trained embedder in the Mac runner.
//
//   RETRIEVAL_EVAL_EMBEDDER=eg2[:<dimension>]          768 (default), 512, 256 or 128
//   RETRIEVAL_EVAL_EG2_MODEL=<path>.mlpackage           the int8 package from Scripts/kq-embedder
//   RETRIEVAL_EVAL_EG2_TOKENIZER=<model dir>            the model's repository (tokenizer files)
//   RETRIEVAL_EVAL_EG2_PYTHON=<python>                  a Python with `transformers` (the kq venv)
//   RETRIEVAL_EVAL_EG2_CACHE=<file>                     768-value vectors by text, shared across
//                                                       dimensions and runs; outside the repository
//
// The model runs on the CPU only, as on the phone. Tokens come from the reference tokenizer, run as
// a line server (`tokenize_server.py`), because this build can't link `swift-transformers`; P0
// measured the two identical. Vectors are cached at 768 values and cut to the dimension asked for,
// which is what the backend does on the phone.
enum SearchModelEval {

    private static let env = ProcessInfo.processInfo.environment

    /// The dimension asked for by `RETRIEVAL_EVAL_EMBEDDER=eg2[:n]`; nil for any other embedder.
    static var requestedDimension: Int? {
        guard let value = env["RETRIEVAL_EVAL_EMBEDDER"], value == "eg2" || value.hasPrefix("eg2:") else { return nil }
        guard value != "eg2" else { return 768 }
        guard let n = Int(value.dropFirst(4)), CoreMLEmbeddingBackend.supportedDimensions.contains(n) else {
            fatalError("RETRIEVAL_EVAL_EMBEDDER is eg2 or eg2:<768|512|256|128>")
        }
        return n
    }

    /// The runner's embedder: the search-trained model when asked for, else the app's default.
    static func embedder() -> Embedder {
        guard let dimension = requestedDimension else { return Embedder() }
        func need(_ name: String) -> String {
            guard let value = env[name], !value.isEmpty else { fatalError("\(name) is required with RETRIEVAL_EVAL_EMBEDDER=eg2") }
            return value
        }
        let package = URL(fileURLWithPath: need("RETRIEVAL_EVAL_EG2_MODEL"))
        let tokenizer = TokenizerServer(python: need("RETRIEVAL_EVAL_EG2_PYTHON"), modelDir: need("RETRIEVAL_EVAL_EG2_TOKENIZER"))
        let compiled: URL
        do { compiled = try MLModel.compileModel(at: package) } catch { fatalError("can't compile \(package.path): \(error)") }
        guard let full = CoreMLEmbeddingBackend(compiledModel: compiled, dimension: 768, tokenize: tokenizer.ids) else {
            fatalError("can't load \(package.path) on the CPU")
        }
        let cache = VectorCache(path: env["RETRIEVAL_EVAL_EG2_CACHE"])
        return Embedder(backend: CachedBackend(full: full, dimension: dimension, cache: cache))
    }

    /// The full model's vectors, cached, cut to `dimension`.
    final class CachedBackend: EmbeddingBackend {
        let full: CoreMLEmbeddingBackend
        let dimension: Int
        let cache: VectorCache
        var modelId: String { CoreMLEmbeddingBackend.modelId(dimension: dimension) }

        init(full: CoreMLEmbeddingBackend, dimension: Int, cache: VectorCache) {
            self.full = full
            self.dimension = dimension
            self.cache = cache
        }

        func embed(_ text: String) -> [Float]? { lookup("d", text) { full.embed(text) } }
        func embedQuery(_ text: String) -> [Float]? { lookup("q", text) { full.embedQuery(text) } }

        private func lookup(_ role: String, _ text: String, _ make: () -> [Float]?) -> [Float]? {
            let key = VectorCache.key(role: role, text: text)
            let vector = cache.vector(for: key) ?? make().map { cache.store($0, for: key); return $0 }
            return vector.flatMap { CoreMLEmbeddingBackend.truncated($0, to: dimension) }
        }
    }

    /// 768-value vectors keyed by a hash of role and text, appended to one file.
    final class VectorCache {
        private var vectors: [Data: [Float]] = [:]
        private let handle: FileHandle?
        static let width = 768

        static func key(role: String, text: String) -> Data { Data(SHA256.hash(data: Data((role + "\u{1}" + text).utf8))) }

        init(path: String?) {
            guard let path else { handle = nil; return }
            let url = URL(fileURLWithPath: path)
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            if let data = try? Data(contentsOf: url) {
                let record = 32 + Self.width * 4
                var offset = 0
                while offset + record <= data.count {
                    let key = data.subdata(in: offset..<(offset + 32))
                    let floats = data.subdata(in: (offset + 32)..<(offset + record)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                    vectors[key] = floats
                    offset += record
                }
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }

        func vector(for key: Data) -> [Float]? { vectors[key] }

        func store(_ vector: [Float], for key: Data) {
            guard vector.count == Self.width else { return }
            vectors[key] = vector
            var record = key
            vector.withUnsafeBufferPointer { record.append(Data(buffer: $0)) }
            try? handle?.write(contentsOf: record)
        }
    }

    /// `tokenize_server.py` as a child process: one JSON line out, one JSON line back.
    final class TokenizerServer {
        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private var buffer = Data()

        init(python: String, modelDir: String) {
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("kq-embedder/tokenize_server.py").path
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-I", script, modelDir]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { fatalError("can't start the tokenizer: \(error)") }
        }

        func ids(_ text: String) -> [Int] {
            guard let line = try? JSONEncoder().encode(text) else { return [] }
            input.fileHandleForWriting.write(line + Data("\n".utf8))
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let reply = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    return (try? JSONDecoder().decode([Int].self, from: reply)) ?? []
                }
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { fatalError("the tokenizer stopped") }
                buffer.append(chunk)
            }
        }
    }
}
