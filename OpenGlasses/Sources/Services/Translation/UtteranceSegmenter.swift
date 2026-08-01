import Foundation

/// Plan BY P3 — pure energy-based utterance segmentation for the on-device tier.
///
/// SenseVoice is an *offline* recognizer (whole utterances in, text out), so the provider needs
/// utterance boundaries the cloud tier gets from server VAD. This state machine buffers mono
/// samples while speech is present and emits the utterance once silence has held for
/// `silenceHold` (or the buffer hits `maxUtterance`, so a monologue still produces output and
/// memory stays bounded). Energy detection reuses `TranscriptGuard`'s RMS gate — one threshold
/// for "is this silence" across the ASR stack.
struct UtteranceSegmenter {

    enum Event: Equatable {
        case none
        case ended([Float])
    }

    /// Silence must hold this long to end an utterance (the same idea as `EndpointDebouncer`,
    /// but ahead of recognition instead of behind it).
    let silenceHold: TimeInterval
    /// Force-emit ceiling: a monologue emits a segment and keeps going.
    let maxUtterance: TimeInterval
    let rmsThreshold: Float

    private var buffer: [Float] = []
    private var buffered: TimeInterval = 0
    private var speaking = false
    private var silence: TimeInterval = 0

    init(silenceHold: TimeInterval = 0.8, maxUtterance: TimeInterval = 12,
         rmsThreshold: Float = TranscriptGuard.defaultRMSThreshold) {
        self.silenceHold = silenceHold
        self.maxUtterance = maxUtterance
        self.rmsThreshold = rmsThreshold
    }

    mutating func accept(_ chunk: [Float], duration: TimeInterval) -> Event {
        let hasSpeech = TranscriptGuard.passesEnergyGate(samples: chunk, rmsThreshold: rmsThreshold)

        guard speaking else {
            if hasSpeech {
                speaking = true
                buffer = chunk
                buffered = duration
                silence = 0
            }
            return .none
        }

        buffer.append(contentsOf: chunk)
        buffered += duration

        if hasSpeech {
            silence = 0
        } else {
            silence += duration
            if silence >= silenceHold {
                return emit(continueSpeaking: false)
            }
        }
        if buffered >= maxUtterance {
            // Mid-speech force-emit: stay in the speaking state so the continuation is captured.
            return emit(continueSpeaking: true)
        }
        return .none
    }

    /// Session teardown: hand back whatever was buffered rather than dropping trailing speech.
    mutating func flush() -> [Float]? {
        defer { self = UtteranceSegmenter(silenceHold: silenceHold, maxUtterance: maxUtterance,
                                          rmsThreshold: rmsThreshold) }
        return speaking && !buffer.isEmpty ? buffer : nil
    }

    private mutating func emit(continueSpeaking: Bool) -> Event {
        let samples = buffer
        buffer = []
        buffered = 0
        silence = 0
        speaking = continueSpeaking
        return .ended(samples)
    }
}
