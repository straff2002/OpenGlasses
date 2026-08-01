import AVFoundation
import Foundation
import NaturalLanguage

/// Plan BY P3 — the offline/HIPAA translation tier: SenseVoice ASR (multilingual, on-device) →
/// Apple Translation. Zero cloud egress, so it needs no per-buffer HIPAA gate — that gate exists
/// to stop egress, and there is none here.
///
/// Pipeline per utterance: shared-engine buffers → `UtteranceSegmenter` (pure, unit-tested) →
/// `OnDeviceASREngine.transcribe` (expected locale "auto" — foreign scripts are the point) →
/// `NLLanguageRecognizer` for the source language → `TranslationDirectionPolicy` picks the leg →
/// `AppleTranslationEngine`. Finals only — there are no interims to show while an offline
/// recognizer waits for the utterance to end, and an honest gap beats a fake one. Translation
/// failures fall back to emitting the untranslated transcript, never a dropped caption.
@MainActor
final class OnDeviceTranslationProvider: TranslationCaptionProvider {

    var onSegment: ((TranslationSegment) -> Void)?

    private let asr: OnDeviceASREngine
    private let engine: AppleTranslationEngine
    private var segmenter: UtteranceSegmenter
    private var direction: TranslationDirectionPolicy = .oneWay(target: "en")
    private var running = false

    init(asr: OnDeviceASREngine, engine: AppleTranslationEngine,
         segmenter: UtteranceSegmenter = UtteranceSegmenter()) {
        self.asr = asr
        self.engine = engine
        self.segmenter = segmenter
    }

    /// Whether this tier can run at all: sherpa-onnx compiled in + SenseVoice model downloaded.
    /// (Apple Translation pair availability surfaces as a download prompt on first use.)
    var isReady: Bool { asr.isReady }

    // MARK: - TranslationCaptionProvider

    func start(direction: TranslationDirectionPolicy) throws {
        guard isReady else { throw TranslationProviderError.notConfigured }
        self.direction = direction
        segmenter = UtteranceSegmenter()
        running = true
    }

    func stop() {
        running = false
        _ = segmenter.flush()
    }

    // MARK: - Audio

    func sendAudio(_ buffer: AVAudioPCMBuffer) {
        guard running else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0, let floatChannels = buffer.floatChannelData else { return }
        let channels: [[Float]] = (0..<Int(buffer.format.channelCount)).map { ch in
            Array(UnsafeBufferPointer(start: floatChannels[ch], count: frames))
        }
        let mono = PCMConverter.downmixToMono(channels)
        let sampleRate = buffer.format.sampleRate
        if case .ended(let samples) = segmenter.accept(mono, duration: Double(frames) / sampleRate) {
            Task { await self.process(samples, sampleRate: sampleRate) }
        }
    }

    // MARK: - Pipeline

    private func process(_ samples: [Float], sampleRate: Double) async {
        let transcript: String
        do {
            transcript = try await asr.transcribe(samples: samples, sampleRate: sampleRate,
                                                  expectedLocaleIdentifier: "auto")
        } catch {
            NSLog("[Translation] on-device ASR failed: %@", error.localizedDescription)
            return
        }
        guard !transcript.isEmpty, running else { return }

        let detected = Self.detectLanguage(transcript)
        guard let target = direction.renderLanguage(forDetected: detected) else {
            // Two-way with an undetectable language: show the transcript rather than nothing.
            onSegment?(TranslationSegment(text: transcript, isFinal: true, language: detected))
            return
        }
        if let detected, detected.hasPrefix(target) || target.hasPrefix(detected) {
            // Already in the render language — transcription is the caption.
            onSegment?(TranslationSegment(text: transcript, isFinal: true, language: detected))
            return
        }

        do {
            let translated = try await engine.translate(transcript, from: detected, to: target)
            guard running else { return }
            onSegment?(TranslationSegment(text: translated, isFinal: true, language: detected,
                                          original: transcript))
        } catch {
            // Fail open: the untranslated transcript is still a caption (and says so via
            // `language`), a silent drop is a lost utterance.
            NSLog("[Translation] on-device translate failed: %@", error.localizedDescription)
            guard running else { return }
            onSegment?(TranslationSegment(text: transcript, isFinal: true, language: detected))
        }
    }

    static func detectLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }
}
