import AVFoundation
import Foundation

/// Single arbiter of the shared `AVAudioSession` across the app's audio subsystems.
///
/// Subsystems `acquire` the session for a given `AudioSessionOwner` instead of calling
/// `setActive(true)` themselves, and `release` it when done. Acquiring supersedes any prior holder
/// (last-acquire-wins); releasing deactivates the session **only** if no newer owner has acquired it
/// since — the stale-release suppression that keeps a preempted subsystem's late teardown from
/// killing the session a newer one is using. The arbitration logic is the pure `AudioSessionLedger`;
/// this type adds the serial-queue safety and the real activation/deactivation.
///
/// Activation goes through `AudioSessionActivator`, so the preferred → `.default` fallback and
/// deactivate-first-to-clear-a-stale-route behaviour of the *acquire* path are unchanged.
///
/// **BJ PR1 — off-main activation.** Synchronous `setActive` on the main thread can stall the UI on
/// an `AVAudioSession` route change (worst on the Bluetooth glasses path). Two additions close that,
/// without changing any existing behaviour:
///  - **One serial `sessionIOQueue` for both activation and deactivation** (total order). The
///    deactivation block re-checks the ledger first, so a superseded deactivation becomes a no-op
///    instead of tearing the session out from under a newer owner (this *closes* the prior
///    `deactivationQueue`-vs-`acquire` race, it doesn't copy it).
///  - **`acquireOffMain` / `reconfigure`** run activation on that queue and are awaited, so a
///    main-actor caller hands off the blocking work. `reconfigure` re-tunes the already-active
///    session in place with **no deactivate-first and no fallback**, so a subsystem's hand-tuned
///    options (wake word's `mixWithOthers`) are never silently swapped.
///
/// The session is injected (`AudioSessionConforming`) so tests drive a fake; production uses
/// `.shared`, which binds `AVAudioSession.sharedInstance()`.
final class AudioSessionCoordinator: @unchecked Sendable {
    static let shared = AudioSessionCoordinator()

    private let stateQueue = DispatchQueue(label: "audio.session.coordinator.state")
    /// BJ PR1 — one serial queue for BOTH activation and deactivation, so their order is total.
    /// Internal (not private) so a test can block it and drive the release race deterministically.
    let sessionIOQueue = DispatchQueue(label: "audio.session.coordinator.io", qos: .userInitiated)
    private var ledger = AudioSessionLedger()
    private let session: AudioSessionConforming

    private init() { self.session = AVAudioSession.sharedInstance() }

    /// Test seam — inject a fake session. Never `.shared` in tests (the AVAudioSession/Wearables
    /// house rule: tests use fresh instances, never the shared singleton).
    init(session: AudioSessionConforming) { self.session = session }

    /// The owner currently recognised as holding the shared session, or `nil` if it's free.
    var currentOwner: AudioSessionOwner? {
        stateQueue.sync { ledger.current?.owner }
    }

    /// Complete snapshot of who is using audio right now: the exclusive owner (if any) plus any
    /// non-exclusive coexisting riders. The single source of truth for diagnostics / future
    /// precedence decisions.
    var audioActivity: (owner: AudioSessionOwner?, coexisting: [AudioSessionOwner]) {
        stateQueue.sync { (ledger.current?.owner, ledger.coexistingOwners) }
    }

    /// Register a non-exclusive coexisting hold — for subsystems that use the shared session
    /// *under* the current exclusive owner (live translation listening mid-conversation, TTS
    /// output) and must NOT preempt it or deactivate it. They keep their own session configuration;
    /// this only records that they're active. Return the token to `endCoexisting` later.
    @discardableResult
    func beginCoexisting(_ owner: AudioSessionOwner) -> UUID {
        let token = UUID()
        stateQueue.sync { ledger.beginCoexisting(owner, token: token) }
        PrivacyLog.audio(.coordinator, .leaseHeld, owner: PrivacyToken(owner.rawValue))
        return token
    }

    /// End a coexisting hold. Never deactivates the session (the exclusive owner is untouched).
    func endCoexisting(_ token: UUID) {
        stateQueue.sync { ledger.endCoexisting(token: token) }
    }

    /// Record `owner` as the current holder **without** performing activation — for subsystems
    /// that manage their own hand-tuned session configuration (notably the always-on wake-word
    /// listener, whose `mixWithOthers` pause/resume behaviour must stay exactly as-is) but still
    /// need the coordinator to know who owns the mic. Supersedes any prior holder, just like
    /// `acquire`. Return the lease to `release` later.
    @discardableResult
    func assumeOwnership(_ owner: AudioSessionOwner) -> AudioSessionLease {
        let lease = stateQueue.sync { ledger.acquire(owner, token: UUID()).lease }
        PrivacyLog.audio(.coordinator, .leaseAssumed, owner: PrivacyToken(owner.rawValue))
        return lease
    }

    /// Acquire the shared session for `owner`, configuring and activating it **on the caller's
    /// thread**. Supersedes any prior holder. On activation failure the lease is rolled back (so a
    /// failed acquire never leaves the caller recorded as owner) and the error is rethrown.
    ///
    /// For callers already off the main thread. Main-actor callers should prefer `acquireOffMain`.
    ///
    /// - Parameter configure: run after `setCategory` and before `setActive` — for non-fatal hints
    ///   like `setPreferredSampleRate` (call them with `try?` inside).
    @discardableResult
    func acquire(
        _ owner: AudioSessionOwner,
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions,
        configure: (AudioSessionConforming) -> Void = { _ in }
    ) throws -> AudioSessionLease {
        let token = UUID()
        let lease = stateQueue.sync { ledger.acquire(owner, token: token).lease }
        do {
            try AudioSessionActivator.activate(
                session,
                category: category,
                mode: mode,
                options: options,
                configure: configure
            )
            PrivacyLog.audio(.coordinator, .leaseAcquired, owner: PrivacyToken(owner.rawValue),
                             detail: PrivacyToken("main"))
            return lease
        } catch {
            rollBack(lease)
            throw error
        }
    }

    /// Like `acquire`, but performs the (potentially blocking) activation on `sessionIOQueue`
    /// instead of the caller's thread, so a main-actor caller never stalls the UI on an
    /// `AVAudioSession` route change. Supersedes any prior holder; rolls the lease back on failure.
    @discardableResult
    func acquireOffMain(
        _ owner: AudioSessionOwner,
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions,
        configure: @escaping (AudioSessionConforming) -> Void = { _ in }
    ) async throws -> AudioSessionLease {
        let token = UUID()
        let lease = stateQueue.sync { ledger.acquire(owner, token: token).lease }
        do {
            try await runOnSessionIO {
                try AudioSessionActivator.activate(
                    self.session, category: category, mode: mode, options: options, configure: configure)
            }
            PrivacyLog.audio(.coordinator, .leaseAcquired, owner: PrivacyToken(owner.rawValue),
                             detail: PrivacyToken("offMain"))
            return lease
        } catch {
            rollBack(lease)
            throw error
        }
    }

    /// Re-tune the **already-active** session in place: `setCategory` → optional hints → `setActive`,
    /// on `sessionIOQueue`, with **no deactivate-first and no fallback**. For subsystems that adjust
    /// their own live session (wake word pause/resume/configure) and must not have the session torn
    /// down or their hand-tuned options silently swapped to `.default`. A transient failure surfaces
    /// to the caller. Ownership is unchanged — the caller already owns (or self-owns) the session.
    func reconfigure(
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions,
        activeOptions: AVAudioSession.SetActiveOptions = [],
        configure: @escaping (AudioSessionConforming) -> Void = { _ in }
    ) async throws {
        try await runOnSessionIO {
            try self.session.setCategory(category, mode: mode, options: options)
            configure(self.session)
            try self.session.setActive(true, options: activeOptions)
        }
    }

    /// Ensure the shared session is active, on `sessionIOQueue`, without changing its category or
    /// ownership (BJ PR2). For a coexisting rider (TTS playback) whose `AVAudioPlayer.play()` would
    /// otherwise *implicitly* activate the session on the main thread when no exclusive owner has
    /// activated it (CarPlay / call-active, where wake word's pause early-returns). `setActive(true)`
    /// is idempotent when already active.
    func ensureActiveOffMain() async {
        try? await runOnSessionIO { try self.session.setActive(true, options: []) }
    }

    /// Deactivate the shared session off-main when there is no lease to `release` (a rare fallback —
    /// wake word normally holds a lease). Prefer `release(_:)`, which also honours ownership.
    func deactivateOffMain() async {
        try? await runOnSessionIO {
            try self.session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Release `lease`. Deactivates the shared session only if `lease` is still the current owner;
    /// a stale release (a newer owner has acquired since) is ignored. The deactivation runs on
    /// `sessionIOQueue` and **re-checks the ledger** immediately before `setActive(false)`, so a
    /// deactivation that was queued before a newer owner acquired becomes a no-op (BJ PR1).
    func release(_ lease: AudioSessionLease) {
        let decision = stateQueue.sync { ledger.release(lease) }
        switch decision {
        case .deactivate:
            sessionIOQueue.async { [self] in
                // Re-check under the state lock: if a newer owner acquired the session between the
                // release decision and this block running, do NOT deactivate — that would kill the
                // live session out from under them (the race the single queue + this guard close).
                let stillFree = stateQueue.sync { ledger.current == nil }
                guard stillFree else {
                    PrivacyLog.audio(.coordinator, .leaseSuppressed,
                                     owner: PrivacyToken(lease.owner.rawValue))
                    return
                }
                do {
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                    PrivacyLog.audio(.coordinator, .leaseReleased,
                                     owner: PrivacyToken(lease.owner.rawValue))
                } catch {
                    PrivacyLog.audio(.coordinator, .leaseDeactivateFailed,
                                     owner: PrivacyToken(lease.owner.rawValue),
                                     error: SafeErrorSummary(error))
                }
            }
        case .superseded(let by):
            PrivacyLog.audio(.coordinator, .leaseStale, owner: PrivacyToken(lease.owner.rawValue),
                             detail: PrivacyToken(by.rawValue))
        case .alreadyReleased:
            break
        }
    }

    /// Await all currently-queued activation/deactivation to finish. With async activation the
    /// ledger can report owner X *before* X's `setActive(true)` has actually run; callers that
    /// consult ownership to decide audio routing (wake-word interruption handling, expert-call
    /// precedence) await this so they act on reality, not a pending intention.
    func activationSettled() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionIOQueue.async { cont.resume() }
        }
    }

    // MARK: - Private

    /// Roll a lease back if it's still current (a failed activation must not leave the caller owner).
    private func rollBack(_ lease: AudioSessionLease) {
        stateQueue.sync {
            if ledger.current == lease { _ = ledger.release(lease) }
        }
    }

    /// Run blocking session I/O on the single serial `sessionIOQueue`, bridged to `async`.
    private func runOnSessionIO(_ work: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionIOQueue.async {
                do { try work(); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
        }
    }
}
