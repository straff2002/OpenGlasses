import AVFoundation
import Foundation

enum TranslationProviderError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Translation is not configured (needs the opt-in, a Gemini API key, and HIPAA mode off)."
        }
    }
}

/// Plan BY P2 — the cloud translation tier, riding the existing Gemini Live wire: one websocket
/// does STT + language detection + translation in a TEXT-modality session with a translator
/// system instruction. Reuses `GeminiLiveService` wholesale, so reconnect backoff, the
/// stale-callback generation gate, and off-main parsing come for free.
///
/// The deterministic parts — prompt contract (`TranslationPromptBuilder`), stream folding
/// (`TranslationStreamAccumulator`), resampling (`PCMConverter.resample`) — are unit-tested.
/// This class is the live transport around them and is device-pending, matching how
/// `DeepgramSTTService` shipped.
@MainActor
final class GeminiTranslationProvider: ObservableObject, TranslationCaptionProvider {

    var onSegment: ((TranslationSegment) -> Void)?

    /// Runtime gate for cloud egress, re-checked on **every** audio buffer, not just `start()` —
    /// a mid-session HIPAA flip (or revoked opt-in) must stop audio leaving the device
    /// immediately (the AQ lesson). Injectable for tests.
    var isConfigured: () -> Bool = { Config.isTranslationCloudConfigured }

    private let service = GeminiLiveService()
    private var accumulator = TranslationStreamAccumulator()
    private var wantsSession = false

    // MARK: - TranslationCaptionProvider

    func start(direction: TranslationDirectionPolicy) throws {
        guard isConfigured() else { throw TranslationProviderError.notConfigured }
        wantsSession = true
        accumulator.reset()

        service.configure(
            systemInstruction: TranslationPromptBuilder.instruction(direction: direction),
            toolDeclarations: [],
            responseModalities: ["TEXT"]
        )
        service.onTextOutput = { [weak self] chunk in
            guard let self, self.wantsSession else { return }
            if let interim = self.accumulator.acceptDelta(chunk) {
                self.onSegment?(interim)
            }
        }
        service.onTurnComplete = { [weak self] in
            guard let self, self.wantsSession else { return }
            if let final = self.accumulator.turnCompleted() {
                self.onSegment?(final)
            }
        }
        service.onInputTranscription = { [weak self] chunk in
            guard let self, self.wantsSession else { return }
            self.accumulator.acceptInputTranscription(chunk)
        }

        // Connect in the background; audio is dropped (not queued) until `.ready`, and the
        // service owns reconnect backoff from here.
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.service.connect()
            if !ok { NSLog("[Translation] Gemini session failed to connect") }
        }
    }

    func stop() {
        wantsSession = false
        service.disconnect()
        accumulator.reset()
    }

    // MARK: - Audio

    /// Feed a shared-engine buffer. Resampled to the wire's fixed 16 kHz. Drop-don't-queue:
    /// buffers before `.ready` (or during a reconnect) are discarded, never buffered — captions
    /// are a live surface and stale audio is worse than a gap.
    func sendAudio(_ buffer: AVAudioPCMBuffer) {
        guard isConfigured() else {
            if wantsSession { stop() }
            return
        }
        guard wantsSession else { return }
        let data = PCMConverter.linear16Mono(from: buffer, resampledTo: Config.geminiLiveInputSampleRate)
        guard !data.isEmpty else { return }
        service.sendAudio(data: data)
    }
}
