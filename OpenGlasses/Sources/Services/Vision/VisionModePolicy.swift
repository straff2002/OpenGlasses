import Foundation

/// Vision as a spoken mode: entered and left by voice, with no wake word between questions while
/// it is on.
///
/// The suppression is the point rather than a convenience. It makes this a *conversational* state —
/// "we are looking at something together" — instead of a camera state, and a wearer who must
/// re-address the assistant before every question may as well take single photos. It is also what
/// keeps the wearer's hands free, which is the entire premise of the device.
///
/// The cost is an open mic for the mode's lifetime, which removes the one gesture that bounds
/// listening. So every rule below is about the mode's *edges*: it must be hard to enter by accident,
/// impossible to sit in forever, and it must announce every way it ends. A mode that stops quietly
/// leaves the wearer believing the glasses can still see, which is the worst failure available here.
enum VisionModePolicy {

    enum State: Equatable {
        case off
        /// Entered; the camera is starting. The wearer has been told, because this takes seconds.
        case warming
        case on
        /// Leaving — the notice is being delivered before the camera goes down.
        case ending(reason: ExitReason)
    }

    enum ExitReason: String, Equatable {
        case spokenStop
        case inactivity
        case sessionEnded
        case doffed
        case powerPressure
        case cameraFailed

        /// What the wearer is told. Every exit says something: silence here is indistinguishable
        /// from "nothing has changed", and the wearer would keep asking a camera that is off.
        var notice: String {
            switch self {
            case .spokenStop:    return "Vision off."
            case .inactivity:    return "Vision off — no questions for a while."
            case .sessionEnded:  return "Vision off — the session ended."
            case .doffed:        return "Vision off — the glasses came off."
            case .powerPressure: return "Vision off — the glasses need to cool down or charge."
            case .cameraFailed:  return "Vision off — the camera stopped."
            }
        }
    }

    /// Why entering was refused, when it was.
    enum Refusal: Equatable, Error {
        case noCamera(String)
        case powerPressure
        case alreadyOn

        var notice: String {
            switch self {
            case .noCamera(let reason): return reason
            case .powerPressure:        return "Not now — the glasses are low on power or too warm."
            case .alreadyOn:            return "Vision is already on."
            }
        }
    }

    /// What the wearer's glasses and battery allow, passed in rather than read from services so the
    /// rules are testable without either.
    struct Capability: Equatable {
        /// Nil when the device has a usable camera; otherwise the tier's own copy explaining why not.
        var cameraUnavailableReason: String?
        /// True under a conserving power posture, where starting a camera we will shortly have to
        /// stop is worse than declining now with a reason.
        var underPowerPressure: Bool
    }

    /// How long without a question before the mode closes itself. Long enough to think and look,
    /// short enough that a wearer who wandered off is not left with an open mic and a live camera.
    static let inactivityTimeout: TimeInterval = 120

    /// Decide an entry request.
    static func enter(from state: State, capability: Capability) -> Result<State, Refusal> {
        switch state {
        case .on, .warming:
            return .failure(.alreadyOn)
        case .off, .ending:
            if let reason = capability.cameraUnavailableReason { return .failure(.noCamera(reason)) }
            if capability.underPowerPressure { return .failure(.powerPressure) }
            return .success(.warming)
        }
    }

    /// Whether the wake word is suppressed in this state.
    ///
    /// True from `warming`, not from `on`: the camera takes seconds to come up and the wearer will
    /// start talking immediately. Requiring the wake word during the warm-up would lose exactly the
    /// question that prompted them to turn vision on.
    static func suppressesWakeWord(_ state: State) -> Bool {
        switch state {
        case .warming, .on:    return true
        case .off, .ending:    return false
        }
    }

    /// Whether a question this many seconds ago leaves the mode alive.
    static func hasTimedOut(sinceLastQuestion elapsed: TimeInterval) -> Bool {
        elapsed >= inactivityTimeout
    }

    /// Apply an exit. Always lands in `.ending` first so the notice is delivered before the camera
    /// goes down — never straight to `.off`, which is how an exit becomes silent.
    static func exit(from state: State, reason: ExitReason) -> State? {
        switch state {
        case .off, .ending: return nil   // already leaving or gone; do not announce twice
        case .warming, .on: return .ending(reason: reason)
        }
    }

    /// The mode has finished tearing down.
    static func settled(from state: State) -> State {
        if case .ending = state { return .off }
        return state
    }
}
