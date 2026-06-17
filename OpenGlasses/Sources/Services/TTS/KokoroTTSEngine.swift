import Foundation

/// Failure modes of the Kokoro on-device engine.
enum KokoroError: LocalizedError, Equatable {
    /// The sherpa-onnx binary isn't compiled into this build (the `KOKORO_ENABLED` flag is off).
    case notCompiledIn
    /// The model files aren't present in Application Support yet.
    case modelUnavailable
    /// sherpa-onnx failed to load the model / build the OfflineTts engine.
    case modelLoadFailed
    /// Inference ran but produced no audio.
    case inferenceFailed

    var errorDescription: String? {
        switch self {
        case .notCompiledIn: return "Kokoro engine is not compiled into this build"
        case .modelUnavailable: return "Kokoro model is not downloaded"
        case .modelLoadFailed: return "Failed to load the Kokoro model"
        case .inferenceFailed: return "Kokoro speech synthesis failed"
        }
    }
}

/// On-device neural TTS via **sherpa-onnx** running `kokoro-int8-multi-lang-v1_1` (Additional
/// Capabilities #1 — the headline tier). The third voice between cloud ElevenLabs and the robotic
/// AVSpeechSynthesizer: offline, free, good quality — and, crucially, **CPU/ONNX not Metal/MLX, so it
/// runs while backgrounded** (unlike our on-device MLX models, which are foreground-only).
///
/// The real ONNX inference is compiled in behind the `KOKORO_ENABLED` flag, which links the vendored
/// sherpa-onnx + onnxruntime xcframeworks (`Vendor/SherpaOnnx`). When the flag is off the engine is an
/// inert no-op (`isCompiledIn == false`), so the selector never routes to it. Either way Kokoro stays
/// a no-op until the model bundle is downloaded.
@MainActor
final class KokoroTTSEngine {

    /// Source of truth for whether the model files are on disk.
    let modelStore: KokoroModelStore

    init(modelStore: KokoroModelStore = .shared) {
        self.modelStore = modelStore
    }

    /// Whether the sherpa-onnx binary is compiled into this build (the `KOKORO_ENABLED` flag, which
    /// links the vendored xcframeworks).
    static var isCompiledIn: Bool {
        #if KOKORO_ENABLED
        return true
        #else
        return false
        #endif
    }

    /// Ready to synthesize: the binary is compiled in **and** the model files are present. The single
    /// boolean the selector folds into `Availability.kokoroReady`.
    var isReady: Bool {
        Self.isCompiledIn && modelStore.isModelPresent
    }

    #if KOKORO_ENABLED
    /// Lazily-created sherpa-onnx engine (loading the ~114 MB model is expensive, so it's reused).
    private var synthesizer: KokoroSynthesizer?
    #endif

    /// Synthesize `text` to 16-bit PCM mono WAV `Data`, off the main actor, for the service to play
    /// via `AVAudioPlayer`.
    func synthesize(_ text: String) async throws -> Data {
        guard Self.isCompiledIn else { throw KokoroError.notCompiledIn }
        guard modelStore.isModelPresent else { throw KokoroError.modelUnavailable }
        #if KOKORO_ENABLED
        let synth = synthesizer ?? KokoroSynthesizer(modelDirectory: modelStore.directory)
        synthesizer = synth
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try synth.synthesizeWAV(text))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        #else
        throw KokoroError.notCompiledIn
        #endif
    }
}
