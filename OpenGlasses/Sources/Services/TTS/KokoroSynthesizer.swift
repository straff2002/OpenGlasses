#if KOKORO_ENABLED
import Foundation
import SherpaOnnxWrapper

/// Wraps a sherpa-onnx `OfflineTts` for the Kokoro multilingual model and renders text to a WAV.
/// Created lazily and reused (loading the ~114 MB model is expensive). All C calls run on a private
/// serial queue, so it's safe to call from any thread. Compiled only when `KOKORO_ENABLED` links the
/// vendored sherpa-onnx binary (`Vendor/SherpaOnnx`).
final class KokoroSynthesizer: @unchecked Sendable {

    private let modelDirectory: URL
    private let queue = DispatchQueue(label: "com.openglasses.kokoro.synthesizer")
    private var tts: OpaquePointer?   // const SherpaOnnxOfflineTts *

    init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    deinit {
        if let tts { SherpaOnnxDestroyOfflineTts(tts) }
    }

    /// Synthesize `text` to a 16-bit PCM mono WAV. Blocking — call off the main thread.
    func synthesizeWAV(_ text: String, speakerId: Int32 = 0, speed: Float = 1.0) throws -> Data {
        try queue.sync {
            let engine = try ttsHandle()
            guard let audio = SherpaOnnxOfflineTtsGenerate(engine, text, speakerId, speed) else {
                throw KokoroError.inferenceFailed
            }
            defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
            let generated = audio.pointee
            guard generated.n > 0, let samples = generated.samples else {
                throw KokoroError.inferenceFailed
            }
            return Self.makeWAV(samples: samples, count: Int(generated.n), sampleRate: Int(generated.sample_rate))
        }
    }

    /// Build (once) and return the OfflineTts engine, configured for the multilingual Kokoro bundle.
    private func ttsHandle() throws -> OpaquePointer {
        if let tts { return tts }

        func path(_ name: String) -> String { modelDirectory.appendingPathComponent(name).path }
        let lexicon = ["lexicon-us-en.txt", "lexicon-gb-en.txt", "lexicon-zh.txt"]
            .map(path).joined(separator: ",")
        let ruleFsts = ["date-zh.fst", "number-zh.fst", "phone-zh.fst"]
            .map(path).joined(separator: ",")

        // sherpa-onnx copies the config strings, so they only need to outlive the create call —
        // hence the nested `withCString` scopes.
        let handle: OpaquePointer? = path("model.int8.onnx").withCString { model in
            path("voices.bin").withCString { voices in
                path("tokens.txt").withCString { tokens in
                    path("espeak-ng-data").withCString { dataDir in
                        path("dict").withCString { dictDir in
                            lexicon.withCString { lex in
                                ruleFsts.withCString { rules in
                                    "cpu".withCString { provider in
                                        var config = SherpaOnnxOfflineTtsConfig()
                                        config.model.kokoro.model = model
                                        config.model.kokoro.voices = voices
                                        config.model.kokoro.tokens = tokens
                                        config.model.kokoro.data_dir = dataDir
                                        config.model.kokoro.dict_dir = dictDir
                                        config.model.kokoro.lexicon = lex
                                        config.model.kokoro.length_scale = 1.0
                                        config.model.num_threads = 2
                                        config.model.provider = provider
                                        config.model.debug = 0
                                        config.rule_fsts = rules
                                        config.max_num_sentences = 1
                                        return SherpaOnnxCreateOfflineTts(&config)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        guard let handle else { throw KokoroError.modelLoadFailed }
        tts = handle
        return handle
    }

    /// Pack float samples in [-1, 1] into a 16-bit PCM mono WAV.
    private static func makeWAV(samples: UnsafePointer<Float>, count: Int, sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataSize = count * bytesPerSample
        var data = Data(capacity: 44 + dataSize)

        func appendLE<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: "RIFF".utf8)
        appendLE(UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLE(UInt32(16))                 // PCM chunk size
        appendLE(UInt16(1))                  // PCM
        appendLE(UInt16(1))                  // mono
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * bytesPerSample))  // byte rate
        appendLE(UInt16(bytesPerSample))     // block align
        appendLE(UInt16(16))                 // bits per sample
        data.append(contentsOf: "data".utf8)
        appendLE(UInt32(dataSize))

        for i in 0..<count {
            let clamped = max(-1.0, min(1.0, samples[i]))
            appendLE(Int16(clamped * 32767.0))
        }
        return data
    }
}
#endif
