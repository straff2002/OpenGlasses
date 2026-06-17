import Foundation

/// Failure modes of the Kokoro on-device engine.
enum KokoroError: LocalizedError, Equatable {
    /// The sherpa-onnx binary isn't compiled into this build (the `KOKORO_ENABLED` flag is off —
    /// the `.xcframework` is vendored separately; deferred).
    case notCompiledIn
    /// The model files aren't present in Application Support yet.
    case modelUnavailable
    /// The binary is compiled in and the model is present, but real ONNX inference hasn't landed
    /// yet (deferred — see `synthesize`).
    case inferenceNotImplemented

    var errorDescription: String? {
        switch self {
        case .notCompiledIn: return "Kokoro engine is not compiled into this build"
        case .modelUnavailable: return "Kokoro model is not downloaded"
        case .inferenceNotImplemented: return "Kokoro inference is not yet available"
        }
    }
}

/// On-device neural TTS via **sherpa-onnx** running `kokoro-int8-en-v0_19` (Additional Capabilities
/// #1 — the headline tier). It's the third voice between cloud ElevenLabs and the robotic
/// AVSpeechSynthesizer: offline, free, good quality — and, crucially, **CPU/ONNX not Metal/MLX, so it
/// runs while backgrounded** (unlike our on-device MLX models, which are foreground-only). That
/// backgroundability is the reason it's worth the dependency.
///
/// This PR ships the *selection + wiring* end of the tier. The engine is gated behind the
/// `KOKORO_ENABLED` compile flag and its inference path is a guarded stub, so the whole engine
/// selection cascade compiles and is exercised **without** the binary on disk. The vendored
/// `.xcframework` + bridging header, the real `OfflineTts.generate` inference, and model hosting are
/// the deferred follow-up (they're blocked on confirming the Kokoro weights' redistribution terms).
@MainActor
final class KokoroTTSEngine {

    /// Source of truth for whether the model files are on disk.
    let modelStore: KokoroModelStore

    init(modelStore: KokoroModelStore = .shared) {
        self.modelStore = modelStore
    }

    /// Whether the sherpa-onnx binary is compiled into this build. Only `true` under the
    /// `KOKORO_ENABLED` flag — which requires the vendored `.xcframework` (deferred). In the shipped
    /// build this is `false`, so the selector never routes to a non-functional engine.
    static var isCompiledIn: Bool {
        #if KOKORO_ENABLED
        return true
        #else
        return false
        #endif
    }

    /// Ready to synthesize: the binary is compiled in **and** the model files are present. This is
    /// the single boolean the selector folds into `Availability.kokoroReady`. Because
    /// `isCompiledIn` is `false` without the vendored binary, this is always `false` in the shipped
    /// build — Kokoro stays a clean no-op (the model presence alone never makes it selectable).
    var isReady: Bool {
        Self.isCompiledIn && modelStore.isModelPresent
    }

    /// Synthesize `text` to 16-bit PCM WAV `Data` on background CPU threads, for the service to play
    /// via `AVAudioPlayer`.
    ///
    /// Deferred: the real sherpa-onnx `OfflineTts.generate` call lands with the vendored binary. The
    /// path is compiled but inert (throws) so the flag and the selection/wiring are exercisable
    /// end-to-end without the binary.
    func synthesize(_ text: String) async throws -> Data {
        guard Self.isCompiledIn else { throw KokoroError.notCompiledIn }
        guard modelStore.isModelPresent else { throw KokoroError.modelUnavailable }
        #if KOKORO_ENABLED
        // DEFERRED: load OfflineTts from `modelStore.fileURL(...)` once and reuse it; call
        // `generate(text:sid:speed:)` off the main actor; wrap the float samples in a WAV header
        // (see `TextToSpeechService.generateToneData` for the in-memory WAV layout).
        throw KokoroError.inferenceNotImplemented
        #else
        throw KokoroError.notCompiledIn
        #endif
    }
}
