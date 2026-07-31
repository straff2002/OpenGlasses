import Foundation

/// Plan CC — duplex live audio: echo cancellation that degrades instead of failing.
///
/// # The problem
///
/// In phone mode the user could not interrupt the assistant: every captured mic buffer was dropped
/// for the entire time the model spoke, so the Live API's server-side VAD never heard the user and
/// the interruption handling it already provides was unreachable. The mute existed for a real
/// reason — a loudspeaker beside an unprocessed mic feeds the model its own voice — but the cost
/// was barge-in itself.
///
/// # The three-outcome landscape
///
/// - **Mute while the model speaks** (the old behaviour): deaf during its own speech.
/// - **Enable voice processing on a long-lived engine**: capture silenced *entirely* on recent iOS
///   betas — deaf always, strictly worse. This is the trap: the IO-unit swap only behaves when its
///   ordering is deterministic, i.e. VP enabled on a **fresh** engine **before** any wiring or
///   format read.
/// - **Fresh engine per capture start, VP first, dead-IO detected**: echo cancellation when the OS
///   delivers it, and an automatic, detectable fall back to the mute when it doesn't.
///
/// If residual echo makes the model interrupt itself, the lever is server-side start-of-speech
/// sensitivity — **not** re-muting, which throws away barge-in to fix a tuning problem.

/// What the audio engine actually achieved at capture start. Derived from the probe below — never
/// inferred from an OS version.
enum DuplexAudioCapability: String {
    /// Voice-processing IO is active: the mic stays open while the model speaks, the canceller has
    /// the exact reference signal, and barge-in works via server VAD.
    case echoCancelled
    /// No voice processing: the co-located speaker would feed the model its own voice, so captured
    /// buffers are dropped while it speaks (today's behaviour, no regression).
    case halfDuplex
}

/// Pure verdict on whether a just-built voice-processing engine is actually alive (Plan CC P1).
///
/// A zero sample rate on the input format is the **dead-IO signature** — the exact condition that
/// silenced capture entirely when VP was enabled in the wrong order or on an OS build where the
/// swap misbehaves. Treating it as an error is what turns "deaf always" into "fall back to
/// half-duplex".
enum VoiceProcessingProbe {

    enum Verdict: Equatable {
        case usable
        case deadIO(reason: String)
    }

    static func verdict(sampleRate: Double, channelCount: UInt32) -> Verdict {
        if sampleRate <= 0 {
            return .deadIO(reason: "input format reports \(sampleRate) Hz — the dead-IO signature")
        }
        if channelCount == 0 {
            return .deadIO(reason: "input format reports zero channels")
        }
        return .usable
    }
}

/// The mute gate as a pure truth table (Plan CC P1) — previously an inline condition duplicated in
/// both session managers, which is how the two paths drift.
enum EchoSuppressionPolicy {

    /// Whether a captured mic buffer must be dropped instead of sent.
    ///
    /// - Glasses mode: never drop — the mic is on the remote device, there is no co-located
    ///   speaker, and the model must hear the user at all times.
    /// - iPhone + echo-cancelled: never drop — the canceller owns echo, the server VAD owns
    ///   turn-taking, and dropping would reintroduce the deaf-during-speech defect.
    /// - iPhone + half-duplex: drop **only while the model speaks** — the surviving legitimate use
    ///   of the mute, as the fallback tier.
    static func shouldDropCapturedBuffer(
        capability: DuplexAudioCapability,
        iPhoneMode: Bool,
        modelSpeaking: Bool
    ) -> Bool {
        guard iPhoneMode else { return false }
        guard capability == .halfDuplex else { return false }
        return modelSpeaking
    }
}
