import Foundation

/// A clench, as one or two in quick succession (Plan MZ §8). Pure.
///
/// The ring's clench event carries no strength or direction and an ordinary hand movement can fire
/// it, so a second clench within `doubleWindow` reads as a deliberate double. After a double the
/// classifier starts again, so three quick clenches are one double and one single, never two
/// doubles.
struct RingClenchClassifier: Equatable, Sendable {

    enum Clench: Equatable, Sendable {
        case single
        case double
    }

    static let doubleWindow: TimeInterval = 1.2

    private(set) var lastSingle: Date?

    mutating func classify(at now: Date) -> Clench {
        if let lastSingle, now >= lastSingle, now.timeIntervalSince(lastSingle) <= Self.doubleWindow {
            self.lastSingle = nil
            return .double
        }
        lastSingle = now
        return .single
    }

    mutating func reset() {
        lastSingle = nil
    }
}

/// What a clench does: on or off, and the action, from the same list temple taps use.
struct RingTriggerSetting: Equatable, Sendable {
    var enabled: Bool
    var action: TempleAction

    /// Decision 8: on once a ring is paired, and a clench starts the assistant listening.
    static let recommended = RingTriggerSetting(enabled: true, action: .startTalking)

    /// An action that takes a picture or starts a recording needs a double clench, so a stray hand
    /// movement never takes one; everything else takes a single.
    static func needsDoubleClench(_ action: TempleAction) -> Bool {
        switch action {
        case .photoDescribe, .photoToCameraRoll, .toggleRecording: return true
        default: return false
        }
    }

    var needsDoubleClench: Bool { Self.needsDoubleClench(action) }
}

/// From a clench to an action, or to the reason nothing happens (Plan MZ §8). Pure.
///
/// The order: the trigger must be on; a photo action waits for a double; then the alternative
/// triggers' `TriggerGate` with its 2 s debounce and suppression while the assistant is listening,
/// speaking or in a live session. What it returns is resolved by `TempleActionResolver` and carried
/// out by the same performer the temple taps use.
struct RingTriggerEngine: Equatable, Sendable {

    enum Decision: Equatable, Sendable {
        case fire(TempleAction)
        case ignored(Reason)
    }

    enum Reason: String, Equatable, Sendable {
        /// The trigger is off.
        case off
        /// A single clench for an action that needs a double. Silent: it may be the first half.
        case awaitingDouble
        /// Within the debounce window of the last fire.
        case debounced
        /// The assistant is listening, speaking or in a live session.
        case suppressed
    }

    static let debounceInterval: TimeInterval = 2

    private(set) var classifier = RingClenchClassifier()
    private(set) var gate = TriggerGate(debounceInterval: RingTriggerEngine.debounceInterval,
                                        minimumConfidence: 0)

    /// Whether the assistant's state keeps a clench from firing.
    static func isSuppressed(_ activity: TempleContext.Activity) -> Bool {
        switch activity {
        case .listening, .speaking, .liveSession: return true
        case .standby, .thinking, .busy: return false
        }
    }

    mutating func handleClench(at now: Date, setting: RingTriggerSetting,
                               activity: TempleContext.Activity) -> Decision {
        guard setting.enabled else { return .ignored(.off) }
        let clench = classifier.classify(at: now)
        if setting.needsDoubleClench, clench != .double { return .ignored(.awaitingDouble) }
        let suppressed = Self.isSuppressed(activity)
        if suppressed { return .ignored(.suppressed) }
        guard gate.shouldFire(at: now.timeIntervalSinceReferenceDate, suppressed: false) else {
            return .ignored(.debounced)
        }
        return .fire(setting.action)
    }

    mutating func reset() {
        classifier.reset()
        gate.reset()
    }
}

/// What became of a clench the engine let through.
enum RingTriggerResult: Equatable {
    /// Resolved and carried out as a temple tap would be.
    case carriedOut(TempleOutcome)
    /// It needed the microphone, and iOS won't start one from the background. `noticePosted` is
    /// whether this one posted the notification (`RingBackgroundListenGate`).
    case refusedInBackground(noticePosted: Bool)
}

/// A clench the engine let through, carried out exactly as a temple tap with the same action
/// would be: resolved against what the app is doing, confirmed with the temple tap's earcon, then
/// performed (`TempleGestureDispatcher.carryOut`). A photo goes through the glasses camera's own
/// capture, so the capture light and the photo ledger apply as for any other photo.
///
/// One check comes first: a turn that needs the microphone while the app can't open it
/// (`RingMicrophoneFacts`) is not started at all. There is no earcon, because no audio can play
/// either. The wearer gets a notification instead, at most once per cooldown.
@MainActor
enum RingTriggerRunner {

    /// The notice cooldown, kept for the life of the process.
    static var backgroundGate = RingBackgroundListenGate()

    @discardableResult
    static func run(_ action: TempleAction, performer: TempleActionPerforming,
                    microphone: RingMicrophoneFacts = .foreground, now: Date = Date(),
                    postNotice: () -> Void = {}) async -> RingTriggerResult {
        let outcome = TempleActionResolver.resolve(action: action, context: performer.templeContext())
        if case .run(let effect) = outcome,
           case .refuse(let notify) = backgroundGate.decide(effect, facts: microphone, now: now) {
            PrivacyLog.device(.ring, .ringTrigger, state: PrivacyToken("refused"),
                              reason: PrivacyToken("backgroundMicrophone"), success: notify)
            if notify { postNotice() }
            return .refusedInBackground(noticePosted: notify)
        }
        PrivacyLog.device(.ring, .commandHandled, state: PrivacyToken(TempleGestureDispatcher.logToken(outcome)))
        await TempleGestureDispatcher.carryOut(outcome, with: performer)
        return .carriedOut(outcome)
    }
}
