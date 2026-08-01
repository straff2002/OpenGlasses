import Foundation

/// Failure modes of the on-device ASR engine.
enum ASRError: LocalizedError, Equatable {
    /// The sherpa-onnx binary isn't compiled into this build (`SHERPA_ONNX_ENABLED` off).
    case notCompiledIn
    /// The SenseVoice model files aren't present in Application Support yet.
    case modelUnavailable
    /// sherpa-onnx failed to build the OfflineRecognizer from the model.
    case modelLoadFailed
    /// Recognition ran but produced no result.
    case recognitionFailed

    var errorDescription: String? {
        switch self {
        case .notCompiledIn: return "On-device ASR is not compiled into this build"
        case .modelUnavailable: return "SenseVoice model is not downloaded"
        case .modelLoadFailed: return "Failed to load the SenseVoice model"
        case .recognitionFailed: return "On-device recognition failed"
        }
    }
}

/// On-device speech recognition via **SenseVoice** on sherpa-onnx (Additional Capabilities #8) — the
/// offline, private alternative to Apple `SFSpeechRecognizer`. CPU/ONNX (not Metal/MLX), so it runs
/// backgrounded, and it reuses the sherpa-onnx binary already vendored for Kokoro TTS.
///
/// Gated behind `SHERPA_ONNX_ENABLED` (the same vendored binary as Kokoro). When off, the engine is an
/// inert no-op (`isCompiledIn == false`) so the selector never routes to it. Either way it's a no-op
/// until the SenseVoice model is downloaded.
@MainActor
final class OnDeviceASREngine {

    let modelStore: ASRModelStore

    init(modelStore: ASRModelStore = ASRModelStore()) {
        self.modelStore = modelStore
    }

    /// Whether the sherpa-onnx binary is compiled in (`SHERPA_ONNX_ENABLED`).
    static var isCompiledIn: Bool {
        #if SHERPA_ONNX_ENABLED
        return true
        #else
        return false
        #endif
    }

    /// Ready to transcribe: binary compiled in **and** the model present. The single boolean the
    /// selector folds into `Availability.onDeviceReady`.
    var isReady: Bool {
        Self.isCompiledIn && modelStore.isModelPresent
    }

    #if SHERPA_ONNX_ENABLED
    private var recognizer: SenseVoiceRecognizer?
    #endif

    /// Transcribe mono float samples (any sample rate — resampled to 16 kHz internally), off the main
    /// actor. Returns the recognized text. `expectedLocaleIdentifier` feeds the artifact filter's
    /// script-mismatch rule; translation callers pass `"auto"` (BY P3) because foreign-language
    /// speech is exactly what they expect — the device STT locale would drop a CJK transcript as
    /// a hallucination before it could be translated.
    func transcribe(samples: [Float], sampleRate: Double,
                    expectedLocaleIdentifier: String = Config.speechRecognitionLocale) async throws -> String {
        guard Self.isCompiledIn else { throw ASRError.notCompiledIn }
        guard modelStore.isModelPresent else { throw ASRError.modelUnavailable }
        // BS P1: effectively-silent audio must not reach the recognizer — this model
        // family decodes silence as training-corpus boilerplate (and skipping saves the
        // inference cost).
        guard TranscriptGuard.passesEnergyGate(samples: samples) else {
            NSLog("[ASR] Energy gate: buffer is silence — skipping recognition")
            return ""
        }
        #if SHERPA_ONNX_ENABLED
        let recog = recognizer ?? SenseVoiceRecognizer(modelDirectory: modelStore.directory)
        recognizer = recog
        let raw: String = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try recog.transcribe(samples: samples, sampleRate: sampleRate))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        // BS P1: drop unmistakable artifact shapes (boilerplate, degenerate repetition,
        // script mismatch vs the caller's expected locale).
        guard let kept = TranscriptGuard.filter(raw, expectedLocaleIdentifier: expectedLocaleIdentifier) else {
            NSLog("[ASR] Artifact filter dropped transcript: %@", String(raw.prefix(60)))
            return ""
        }
        return kept
        #else
        throw ASRError.notCompiledIn
        #endif
    }
}
