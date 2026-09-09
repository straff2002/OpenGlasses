import Foundation

/// Whether the bystander blur is available *right now*, and why not when it isn't.
///
/// Before this existed, "unavailable" had exactly one cause — an explicit `suspend()` call from the
/// background-optimisation path — and that call only happened when a broadcast or WebRTC stream was
/// already running. Every other way the app can stop being able to blur (backgrounded while
/// recording, sitting in the lock-screen transition, protected data gone) was invisible to the
/// filter, so the relay never learned to drop those frames.
///
/// The lifecycle is modelled as a value type rather than read from `UIApplication` at the point of
/// use for two reasons. First, availability is a *policy* — several independent signals collapsing
/// into one verdict — and policies are worth testing on their own. Second, the transitions that
/// matter most (foreground → background, unlocked → locked, and the window in between) cannot be
/// driven from a headless unit test if the only source of truth is the real application object.
struct PrivacyFilterAvailability: Equatable {

    /// Why filtering is unavailable. Carried through to the drop reason so a device log says which
    /// of these stopped the frame rather than only that something did.
    enum Unavailable: String, Equatable {
        /// The app is backgrounded — the blur pass may be throttled or killed outright.
        case backgrounded
        /// The app is neither fully active nor fully backgrounded: the lock-screen slide, the app
        /// switcher, a system alert. Treated as unavailable deliberately; see `isAvailable`.
        case transitioning
        /// The device is locked with protected data unavailable.
        case locked
        /// `PrivacyFilterService.suspend()` was called (background resource optimisation).
        case explicitlySuspended
    }

    /// The three scene phases, mirrored so callers need not import SwiftUI to drive this.
    enum Phase: String, Equatable {
        case active
        case inactive
        case background
    }

    private(set) var phase: Phase = .active
    private(set) var isProtectedDataAvailable = true
    private(set) var isExplicitlySuspended = false

    /// Bumped every time availability *returns*. Consumers that cache detection results key off
    /// this: a mask computed before the app went away describes a scene the wearer has since
    /// walked out of, so coming back must force a fresh detection rather than reuse it.
    private(set) var resumeGeneration = 0

    init() {}

    /// The verdict, in priority order. An explicit suspend is reported ahead of the lifecycle
    /// causes because it is the one a developer reading a log can act on directly.
    var unavailableReason: Unavailable? {
        if isExplicitlySuspended { return .explicitlySuspended }
        if !isProtectedDataAvailable { return .locked }
        switch phase {
        case .background: return .backgrounded
        // `.inactive` is the transition window — the couple of hundred milliseconds while the
        // lock-screen slides up, the app switcher is open, or a call banner has focus. iOS makes no
        // promise about whether GPU work still completes there, and it is the exact window a frame
        // can be in flight through. Fail closed: an unblurred frame published during a transition
        // is indistinguishable, to whoever receives it, from one published while unlocked.
        case .inactive: return .transitioning
        case .active: return nil
        }
    }

    var isAvailable: Bool { unavailableReason == nil }

    // MARK: - Signals

    mutating func note(phase newPhase: Phase) {
        let wasAvailable = isAvailable
        phase = newPhase
        noteReturn(from: wasAvailable)
    }

    mutating func noteProtectedData(available: Bool) {
        let wasAvailable = isAvailable
        isProtectedDataAvailable = available
        noteReturn(from: wasAvailable)
    }

    mutating func suspend() {
        let wasAvailable = isAvailable
        isExplicitlySuspended = true
        noteReturn(from: wasAvailable)
    }

    mutating func resume() {
        let wasAvailable = isAvailable
        isExplicitlySuspended = false
        noteReturn(from: wasAvailable)
    }

    private mutating func noteReturn(from wasAvailable: Bool) {
        guard !wasAvailable, isAvailable else { return }
        resumeGeneration += 1
    }
}

#if canImport(SwiftUI)
import SwiftUI

extension PrivacyFilterAvailability.Phase {
    /// Map SwiftUI's scene phase. A phase this app does not know about is treated as the
    /// transition window rather than as active — the whole point of the type is to fail closed.
    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .inactive: self = .inactive
        case .background: self = .background
        @unknown default: self = .inactive
        }
    }
}
#endif
