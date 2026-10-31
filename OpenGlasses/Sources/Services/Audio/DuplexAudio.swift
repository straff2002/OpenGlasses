import AVFoundation
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
/// What a realtime session's audio is set up for.
///
/// `.interpreter` is the route the spoken interpreter needs: output on the glasses over A2DP and
/// input on the phone's mic, with the speaker borrowed one line at a time. Overriding output to the
/// speaker takes input to the built-in mic anyway, so the phone's mic is the only one that survives
/// a flip, and leaving HFP out keeps the glasses from pulling input back.
enum RealtimeAudioRoute: Equatable {
    case standard
    case interpreter

    func sessionOptions() -> AVAudioSession.CategoryOptions {
        switch self {
        case .standard: return [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        // No `.defaultToSpeaker`: with the glasses gone, output falls to the earpiece. A wearer who
        // loses the glasses mid-sentence must not have their private line play to the room.
        case .interpreter: return [.allowBluetoothA2DP]
        }
    }

    /// `.voiceChat` and `.videoChat` both imply Bluetooth HFP, which is why this isn't either.
    func sessionMode(useIPhoneMode: Bool) -> AVAudioSession.Mode {
        switch self {
        case .standard: return useIPhoneMode ? .voiceChat : .videoChat
        case .interpreter: return .default
        }
    }
}

/// Whether audio handed to the player has yet to play.
///
/// `PendingPlaybackMirror` can't answer that: a response boundary retires it while the tail is still
/// draining, and a realtime server sends audio ahead of real time, so a turn can complete with
/// seconds left to play. This counts buffers until they report played. A stop or a rebuild starts a
/// new epoch, so a callback from a buffer that was discarded can't count against the new ones.
struct PlaybackDrainTracker: Equatable {
    private(set) var epoch: UInt64 = 0
    private var outstanding = 0

    var isPending: Bool { outstanding > 0 }

    mutating func scheduled() -> UInt64 {
        outstanding += 1
        return epoch
    }

    mutating func played(epoch: UInt64) {
        guard epoch == self.epoch, outstanding > 0 else { return }
        outstanding -= 1
    }

    mutating func reset() {
        epoch &+= 1
        outstanding = 0
    }
}

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

    /// Whether a captured mic buffer goes to the model at all (Plan GJ P3). The wearer's own mute
    /// (a temple tap mid-session) wins over everything: capture keeps running so unmuting is
    /// instant, the session stays connected, and not one buffer is sent while muted.
    static func shouldForwardCapturedBuffer(
        wearerMuted: Bool,
        capability: DuplexAudioCapability,
        iPhoneMode: Bool,
        modelSpeaking: Bool
    ) -> Bool {
        guard !wearerMuted else { return false }
        return !shouldDropCapturedBuffer(capability: capability, iPhoneMode: iPhoneMode,
                                         modelSpeaking: modelSpeaking)
    }
}
