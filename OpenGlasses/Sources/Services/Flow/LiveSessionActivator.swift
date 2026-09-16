import Foundation

/// Where an activation request came from.
///
/// The distinction that matters is `isExplicit`: a wearer pressing the Action Button or asking Siri
/// is asking *now*, and that overrides a previous stop. Launch and foreground are the app deciding
/// on its own, and they do not.
enum LiveActivationSource: String, Equatable, CaseIterable {
    case launch
    case foreground
    case actionButton
    case siriShortcut
    case wakeWord
    case appUI

    /// Whether this is the wearer asking, rather than the app assuming.
    var isExplicit: Bool {
        switch self {
        case .launch, .foreground: return false
        case .actionButton, .siriShortcut, .wakeWord, .appUI: return true
        }
    }
}

/// The activation owner, as the activator needs it: switch modes, start, stop, and answer what is
/// running. `AppState` is the production implementation; a recording fake is the test one.
@MainActor
protocol LiveSessionActivationOwner: AnyObject {
    var activeMode: AppMode { get }
    func isSessionActive(_ mode: AppMode) -> Bool
    /// Run the mode switch's teardown → settle → substrate actions **to completion**. This is what
    /// replaced the fixed 600 ms sleep every entry point used to guess with.
    func performModeSwitch(to mode: AppMode) async
    func startSession(_ mode: AppMode) async
    func stopSession(_ mode: AppMode)
}

/// Plan FF P1/PR3 — one owner for "start the live assistant", whatever asked for it.
///
/// Before this, five entry points each carried their own copy of *switch mode, sleep 600 ms, start*
/// — a number nobody measured, guarding a teardown whose real duration is
/// `ModeSwitchPolicy.settleDelay` plus however long the camera and audio session take. Two of those
/// paths racing produced two sessions; a wearer pressing Stop while one was mid-flight got a
/// session anyway, a second or two later, with nothing left to press.
///
/// So this holds three rules the copies could not:
///
/// * **Coalescing.** A second request for the same mode awaits the first's outcome and returns it,
///   rather than starting a second session on top.
/// * **A stop cancels a pending start.** Every await is followed by a generation check, so a stop
///   arriving during the permission wait, the mode switch or the start itself leaves nothing
///   running and nothing scheduled — including a stop that lands while `startSession` is in
///   flight, which is torn back down rather than left up.
/// * **An ambient event never restarts a stopped session.** `stoppedByUserThisForeground` latches
///   on a user stop and is cleared only by an explicit request, so scene activation, a glasses
///   reconnect or a route change cannot put back what the wearer took down.
@MainActor
final class LiveSessionActivator {

    enum Outcome: Equatable {
        case started
        case alreadyActive
        case skipped(BlindAssistantLaunchPolicy.SkipReason)
        /// A stop arrived while this request was still working.
        case cancelled
    }

    /// One activation request.
    struct Request {
        let mode: AppMode
        let source: LiveActivationSource
        /// Evaluated inside the activation rather than by the caller, so the answer is read after
        /// the stop check and the wait it may contain is a wait a stop can cancel.
        let gate: (@MainActor () async -> BlindAssistantLaunchPolicy.Decision)?
        /// Whether an already-running session is restarted. True only for the preset-selecting
        /// shortcuts, whose whole purpose is to change what the running session is.
        let restartIfActive: Bool

        init(mode: AppMode,
             source: LiveActivationSource,
             restartIfActive: Bool = false,
             gate: (@MainActor () async -> BlindAssistantLaunchPolicy.Decision)? = nil) {
            self.mode = mode
            self.source = source
            self.restartIfActive = restartIfActive
            self.gate = gate
        }
    }

    private unowned let owner: LiveSessionActivationOwner
    /// Says a line through the app's own speech path — not through VoiceOver, because these have to
    /// be heard with VoiceOver off as well.
    private let speak: (String) -> Void
    /// Injected so the restart settle is a wait a test can stand inside.
    private let sleep: (TimeInterval) async -> Void

    init(owner: LiveSessionActivationOwner,
         speak: @escaping (String) -> Void,
         sleep: @escaping (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.owner = owner
        self.speak = speak
        self.sleep = sleep
    }

    // MARK: - State

    private var inFlight: (mode: AppMode, task: Task<Outcome, Never>)?

    /// Bumped by every stop. A request whose captured value no longer matches has been overtaken.
    private var stopGeneration = 0

    /// The wearer stopped a session themselves.
    ///
    /// The name is Plan FF's. The cycle it actually spans is the app's lifetime, not one foreground
    /// period: clearing it on backgrounding would hand every return-to-foreground a fresh restart,
    /// which is precisely the repeat this exists to prevent. It is cleared by an explicit request —
    /// the Action Button, Siri, the wake word, the app's own Start control — and by relaunching.
    private(set) var stoppedByUserThisForeground = false

    /// The last skip actually spoken, so the same reason is not repeated on every foreground.
    /// Cleared whenever a different decision is reached, so a second occurrence after something
    /// changed is still reported.
    private var lastSpokenSkip: BlindAssistantLaunchPolicy.SkipReason?

    // MARK: - Activation

    @discardableResult
    func activate(_ request: Request) async -> Outcome {
        // Join an in-flight request for the same mode rather than racing it. A request for a
        // *different* mode waits its turn instead — switching brains while a switch is in flight is
        // the one case where "same answer" would be the wrong answer.
        while let current = inFlight {
            let outcome = await current.task.value
            if current.mode == request.mode { return outcome }
            if inFlight?.task == current.task { inFlight = nil }
        }

        if request.source.isExplicit { stoppedByUserThisForeground = false }

        let task = Task { @MainActor [weak self] () -> Outcome in
            guard let self else { return .cancelled }
            return await self.run(request)
        }
        inFlight = (request.mode, task)
        let outcome = await task.value
        if inFlight?.task == task { inFlight = nil }
        return outcome
    }

    private func run(_ request: Request) async -> Outcome {
        let generation = stopGeneration

        if let gate = request.gate {
            let decision = await gate()
            guard generation == stopGeneration else { return .cancelled }
            switch decision {
            case .skip(let reason):
                announce(skip: reason)
                return .skipped(reason)
            case .start(let start):
                lastSpokenSkip = nil
                if let cue = start.cue { speak(cue) }
            }
        }

        if owner.isSessionActive(request.mode) {
            guard request.restartIfActive else { return .alreadyActive }
            owner.stopSession(request.mode)
            // The one delay that survives: an audio session does not hand itself over instantly,
            // and this path stops and restarts the same one. It is `ModeSwitchPolicy`'s number
            // rather than a second guess at it.
            await sleep(ModeSwitchPolicy.settleDelay)
            guard generation == stopGeneration else { return .cancelled }
        }

        if owner.activeMode != request.mode {
            await owner.performModeSwitch(to: request.mode)
            guard generation == stopGeneration else { return .cancelled }
            // A switch out of a live call redials by itself (Plan CF). If it did, there is nothing
            // left for this request to start.
            if owner.isSessionActive(request.mode) { return .alreadyActive }
        }

        guard generation == stopGeneration else { return .cancelled }
        await owner.startSession(request.mode)
        guard generation == stopGeneration else {
            // A stop landed while the session was coming up. It asked for nothing to be running,
            // so nothing is.
            owner.stopSession(request.mode)
            return .cancelled
        }
        return .started
    }

    // MARK: - Stop

    /// Where the last stop came from. Kept for diagnostics — a session that will not restart is a
    /// question ("why is it not coming back?") whose answer is which control was pressed.
    private(set) var lastStopSource: LiveActivationSource?

    /// The wearer stopped the session. Cancels any pending startup and latches the stop.
    func stop(_ mode: AppMode, source: LiveActivationSource) {
        stopGeneration &+= 1
        stoppedByUserThisForeground = true
        lastStopSource = source
        lastSpokenSkip = nil
        owner.stopSession(mode)
    }

    /// A stop that is **not** the wearer's — mode teardown, disconnect, a terminal failure. It
    /// cancels pending startup for the same reason, but it does not latch: the wearer did not ask
    /// for the assistant to stay down.
    func noteSessionEndedExternally() {
        stopGeneration &+= 1
    }

    // MARK: - Announcement

    private func announce(skip reason: BlindAssistantLaunchPolicy.SkipReason) {
        guard let line = reason.spokenReason else {
            lastSpokenSkip = nil
            return
        }
        guard lastSpokenSkip != reason else { return }
        lastSpokenSkip = reason
        speak(line)
    }
}
