import Foundation
import AVFoundation

/// Plan CU P2 — the seam an acoustic end-of-turn detector plugs into.
///
/// The protocol exists before any real detector does, and that is the point: with no detector
/// installed `EndOfTurnPolicy` takes rule 1 and voice input is byte-for-byte what it is today, so
/// the wiring can land, be tested, and be reasoned about without a model, a new dependency, or a
/// device. The backend (on-device Silero on the Neural Engine, per the plan's dependency decision)
/// arrives behind this protocol, along with the resampling, hop chunking and threshold tuning that
/// only make sense with something to score.
///
/// **Where an implementation taps: nowhere new.** `TranscriptionService` already installs a tap and
/// accumulates samples for the on-device ASR path; the detector is fed from those same buffers. A
/// second tap would be wrong twice over — `WakeWordService` owns the shared engine, and CJ's
/// tap-format audit and AO's audio-session work exist precisely because taps and route changes are
/// where this subsystem breaks.
///
/// **`feed` runs on the Core Audio render thread**, ~45×/sec. Implementations must not block, must
/// not allocate unpredictably, and must not hop to the main actor there: convert and accumulate
/// under a lock, hand full hops to a consumer, and **drop the oldest** under backpressure rather
/// than queueing — a growing backlog reports speech-end later and later, which leaks straight into
/// the latency this plan removes. `onEvent` is the only main-actor delivery, and it fires a few
/// times per turn.
@MainActor
protocol SpeechActivityDetecting: AnyObject {

    /// Whether the detector is installed **and** loaded. Soft-fail is the contract: a model that
    /// will not load leaves this false, emits nothing, and the timer keeps the turn.
    var isAvailable: Bool { get }

    /// Transitions only — never per-hop. Delivered on the main actor.
    var onEvent: ((SpeechActivityGate.Event) -> Void)? { get set }

    /// A new utterance is starting. No state survives from the last one.
    func begin()

    /// The utterance is over (committed, abandoned, or errored). Implementations release scoring
    /// state here; `begin()` is what starts the next one.
    func end()

    /// One captured buffer, on the render thread. `route` is passed per buffer rather than held,
    /// because the route can change mid-utterance and the level estimate that normalises the signal
    /// is per route.
    nonisolated func feed(_ buffer: AVAudioPCMBuffer, route: MicRoute)
}

/// The shipped default: no detector. Present so that "no acoustic endpointing" is an explicit,
/// named state in the code rather than an optional that happens to be nil, and so the wiring has
/// something to hold in tests that assert today's behaviour is unchanged.
@MainActor
final class NoSpeechActivityDetector: SpeechActivityDetecting {
    var isAvailable: Bool { false }
    var onEvent: ((SpeechActivityGate.Event) -> Void)?
    func begin() {}
    func end() {}
    nonisolated func feed(_ buffer: AVAudioPCMBuffer, route: MicRoute) {}
}
