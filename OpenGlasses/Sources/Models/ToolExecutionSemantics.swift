import Foundation

// MARK: - Effect

/// What running a tool does to the world.
///
/// This is the axis that decides whether a lost race against the timeout is an authoritative
/// "nothing happened" or an honest "we don't know". Every other use of it — the coherence check
/// against the composition floor, future per-family rollouts — reads the same value.
enum ToolEffect: String, Sendable, Equatable, CaseIterable {
    /// Reads only: sensors, local stores, a network lookup, arithmetic. Running it twice changes
    /// nothing and abandoning it leaves nothing behind.
    case readOnly
    /// Writes state that lives on this device or in the user's own system stores — notes, vaults,
    /// saved locations, calendar and reminder entries, timers, settings.
    case localMutation
    /// Sends data off the device or changes something on a third-party service — a message, an
    /// email, a gateway task, an export, a call placed.
    case externalMutation
    /// Changes physical device or real-world state — the torch, screen brightness, a lock or light,
    /// the camera, a recording, playback, a vehicle.
    case physicalActuation

    /// Whether an abandoned execution can have left something behind.
    var hasSideEffect: Bool { self != .readOnly }
}

// MARK: - Cancellation

/// What asking a running tool to stop is actually worth.
enum ToolCancellation: String, Sendable, Equatable, CaseIterable {
    /// Pure Swift concurrency awaiting things that honour cancellation, so cancelling stops it.
    case cooperative
    /// Async, but part of the work may already be committed when cancellation lands — a launched
    /// URL scheme, an AVFoundation call, a publisher already fired.
    case bestEffort
    /// Synchronous or callback-SDK work that never observes cancellation. Asking is theatre.
    case notCancellable

    /// Whether it is worth cancelling the abandoned task at all.
    var respondsToCancellation: Bool { self != .notCancellable }
}

// MARK: - Idempotency

/// What happens when the identical call runs a second time.
enum ToolIdempotency: String, Sendable, Equatable, CaseIterable {
    /// Repeating it converges on the same world state — every read, and every "set state to X".
    case intrinsic
    /// De-duplicable with an explicit key, once there is somewhere to keep one.
    case keyed
    /// Repeating it duplicates the effect: a second message, a second note, a second recording.
    case none
}

// MARK: - Timeout policy

/// How long a tool may run before the router stops waiting on it.
///
/// Deliberately a *duration* and nothing more: what a lost race means is decided by `effect` and
/// `cancellation`, never by the length of the wait. A side-effecting tool that runs out of time is
/// never reported as not having run.
enum ToolTimeoutPolicy: Sendable, Equatable {
    /// The router's configured budget — right for anything that finishes in a few seconds.
    case routerDefault
    /// This operation needs its own budget: a model round trip, an OCR pass, a device capture.
    case seconds(TimeInterval)

    func resolved(default fallback: TimeInterval) -> TimeInterval {
        switch self {
        case .routerDefault: return fallback
        case .seconds(let value): return value
        }
    }
}

// MARK: - Semantics

/// The execution contract of one tool, declared by the tool itself.
///
/// A tool that declares nothing gets `conservativeDefault`, which assumes the worst on every axis.
/// That default is a migration ramp, not a resting place: `ToolEffectClassificationTests` fails when
/// a newly registered tool leans on it without being listed as deliberate debt, so the unclassified
/// set can only shrink.
struct ToolExecutionSemantics: Sendable, Equatable {
    let effect: ToolEffect
    let cancellation: ToolCancellation
    let idempotency: ToolIdempotency
    let timeout: ToolTimeoutPolicy

    init(effect: ToolEffect, cancellation: ToolCancellation, idempotency: ToolIdempotency,
         timeout: ToolTimeoutPolicy = .routerDefault) {
        self.effect = effect
        self.cancellation = cancellation
        self.idempotency = idempotency
        self.timeout = timeout
    }

    /// What an unclassified tool is assumed to be: it reaches outside the device, it cannot be
    /// stopped, and repeating it duplicates whatever it did.
    static let conservativeDefault = ToolExecutionSemantics(
        effect: .externalMutation, cancellation: .notCancellable, idempotency: .none)

    // Shorthands for the four common shapes. They exist so a tool's declaration reads as one line
    // at the top of the type rather than four labelled arguments.

    static func read(_ cancellation: ToolCancellation = .cooperative,
                     timeout: ToolTimeoutPolicy = .routerDefault) -> ToolExecutionSemantics {
        ToolExecutionSemantics(effect: .readOnly, cancellation: cancellation,
                               idempotency: .intrinsic, timeout: timeout)
    }

    static func local(_ cancellation: ToolCancellation = .notCancellable,
                      idempotency: ToolIdempotency = .none,
                      timeout: ToolTimeoutPolicy = .routerDefault) -> ToolExecutionSemantics {
        ToolExecutionSemantics(effect: .localMutation, cancellation: cancellation,
                               idempotency: idempotency, timeout: timeout)
    }

    static func external(_ cancellation: ToolCancellation = .notCancellable,
                         idempotency: ToolIdempotency = .none,
                         timeout: ToolTimeoutPolicy = .routerDefault) -> ToolExecutionSemantics {
        ToolExecutionSemantics(effect: .externalMutation, cancellation: cancellation,
                               idempotency: idempotency, timeout: timeout)
    }

    static func actuation(_ cancellation: ToolCancellation = .notCancellable,
                          idempotency: ToolIdempotency = .none,
                          timeout: ToolTimeoutPolicy = .routerDefault) -> ToolExecutionSemantics {
        ToolExecutionSemantics(effect: .physicalActuation, cancellation: cancellation,
                               idempotency: idempotency, timeout: timeout)
    }

    /// Whether the timer winning the race is an authoritative "nothing happened".
    ///
    /// True only for a read, and true for *every* read: a read leaves nothing behind whether or not
    /// we managed to stop it, so there is nothing a retry could duplicate. Anything that writes,
    /// sends, or actuates may have landed in the moment between the timer firing and the work
    /// returning — reporting that as a failure is a claim we can't support, and acting on the claim
    /// is what sends the message twice.
    var timeoutIsAuthoritative: Bool { effect == .readOnly }

    /// Whether an automatic retry of an interrupted call is safe on this tool alone.
    var isSafeToRepeat: Bool {
        effect == .readOnly || idempotency == .intrinsic
    }
}
