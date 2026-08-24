import Foundation

/// Which microphone source should be feeding capture consumers (broadcast, video recording).
///
/// Capture audio has always ridden the always-on listener's shared tap, which means it stops dead
/// the moment the wearer turns listening off — a completely reasonable thing to do mid-stream. This
/// enum names the alternative: a self-contained engine that runs *only* while capture needs audio
/// and the shared tap is down.
enum CaptureAudioSource: String, Equatable, Sendable {
    /// Nothing needs mic audio — no engine, no tap, no consumers attached.
    case none
    /// The always-on listener's shared tap is running; ride it (never a second engine).
    case wakeTap
    /// The listener is off but capture is live; run our own engine for the duration.
    case standalone
}

/// The two facts the source decision is made from.
struct CaptureAudioConditions: Equatable, Sendable {
    /// The always-on wake-word listener is running, so its input tap exists.
    var wakeListening: Bool
    /// At least one capture consumer (a broadcast or a video recording) wants mic audio.
    var captureActive: Bool

    init(wakeListening: Bool = false, captureActive: Bool = false) {
        self.wakeListening = wakeListening
        self.captureActive = captureActive
    }
}

/// What a coordinator must actually do to move from one source to another.
///
/// The commands are emitted as a delta rather than as a "desired state" so a handover is explicit:
/// a mid-session listening toggle produces a detach followed by an attach, in that order, and the
/// consumers registered downstream never notice which source they are being fed from.
enum CaptureAudioCommand: Equatable, Sendable {
    case attachToWakeTap
    case detachFromWakeTap
    case startStandalone
    case stopStandalone
}

/// Pure state machine deciding which mic source feeds capture, and what to do on each change.
///
/// Two rules, and both are the whole point:
///  - **The shared tap wins whenever it is running.** Two `AVAudioEngine` input taps on the same
///    route is not a configuration iOS handles gracefully; whichever loses is silent or garbled, and
///    which one loses is not deterministic. So the standalone engine only ever runs in the gap.
///  - **Nothing runs when nothing is capturing.** A standalone engine that outlives its recording
///    holds the mic (and the orange indicator) for no reason.
///
/// No `AVAudioEngine` and no `AVAudioSession` in the signature — the whole decision is testable as a
/// table of `(conditions) → source, commands`.
struct AudioSourceArbiter: Equatable, Sendable {
    /// The source currently believed to be attached.
    private(set) var source: CaptureAudioSource

    init(source: CaptureAudioSource = .none) {
        self.source = source
    }

    /// The source that *should* be running for the given conditions.
    static func source(for conditions: CaptureAudioConditions) -> CaptureAudioSource {
        guard conditions.captureActive else { return .none }
        return conditions.wakeListening ? .wakeTap : .standalone
    }

    /// Apply new conditions, returning the commands needed to reach the new source.
    ///
    /// Idempotent: re-applying conditions that don't change the source returns no commands, so a
    /// noisy publisher can drive this directly without churning the audio graph.
    mutating func apply(_ conditions: CaptureAudioConditions) -> [CaptureAudioCommand] {
        let desired = Self.source(for: conditions)
        guard desired != source else { return [] }
        var commands: [CaptureAudioCommand] = []
        // Detach first, always: the old source must be gone before the new one comes up, or a
        // handover briefly runs two taps — the exact state this arbiter exists to prevent.
        if let detach = Self.detachCommand(for: source) { commands.append(detach) }
        if let attach = Self.attachCommand(for: desired) { commands.append(attach) }
        source = desired
        return commands
    }

    /// Tear everything down (app teardown, or a router losing its sources). Returns the detach
    /// command for whatever is currently attached.
    mutating func reset() -> [CaptureAudioCommand] {
        let commands = Self.detachCommand(for: source).map { [$0] } ?? []
        source = .none
        return commands
    }

    private static func detachCommand(for source: CaptureAudioSource) -> CaptureAudioCommand? {
        switch source {
        case .none: return nil
        case .wakeTap: return .detachFromWakeTap
        case .standalone: return .stopStandalone
        }
    }

    private static func attachCommand(for source: CaptureAudioSource) -> CaptureAudioCommand? {
        switch source {
        case .none: return nil
        case .wakeTap: return .attachToWakeTap
        case .standalone: return .startStandalone
        }
    }
}
