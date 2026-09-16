import Foundation

/// Plan FF P0/PR2 — the stateful half of the audible lifecycle: one queue, one clock, one set of
/// sinks, and the rule that a notice is either heard, expired for a stated reason, or still waiting.
///
/// The policy decides *what* a signal means and *how* it should sound. This decides *whether it is
/// said now, later, or not at all* — which is where every one of the interesting failures lives:
///
/// * A "connection lost" line that sat behind the assistant's speech and played after the socket
///   had already come back. It is not a stale detail, it is a false statement, and a wearer who
///   cannot glance at the screen has no way to find out it was wrong.
/// * The mirror-image failure: dropping the loss notice because the route was busy, so a session
///   that never came back also never said so.
/// * A recovery cue fired from the reconnect callback, at the one moment when the camera has by
///   construction not yet produced a picture — reporting "camera unavailable" on every healthy
///   reconnect, which teaches the wearer to ignore it.
///
/// Everything that touches the world is injected: the clock, the route, the visual evidence, and
/// the two sinks. `autoPump: false` stops the internal timer so a test drives `pump()` against a
/// fake clock and asserts the exact order of what was played and said.
@MainActor
final class AudibleLifecycleCoordinator {

    // MARK: - Input

    /// What a realtime session reports about its own lifecycle.
    ///
    /// Named for what happened, not for what to say: the manager knows the socket dropped, it does
    /// not get to decide whether the wearer hears about it.
    enum Signal: Equatable {
        /// A session finished starting. Carries what it actually managed to bring up.
        case sessionStarted(AudibleLifecyclePolicy.SessionReadiness)
        /// The socket dropped. The retry ladder may or may not be running; either way the wearer
        /// has lost the assistant for now.
        case connectionLost
        /// The socket came back and the restart ran. `audioRestored` is whether microphone capture
        /// actually restarted — the thing that used to be a log line when it threw.
        /// `contextCarried` is Plan FF P1/PR5's fourth fact: whether the conversation itself came
        /// back, by server resumption or by a locally rebuilt handover.
        case reconnected(audioRestored: Bool, needsVisualEvidence: Bool, contextCarried: Bool)

        /// A reconnect reported by a backend that has no way to know what became of the
        /// conversation — the OpenAI Realtime wire has no resumption concept — so it claims
        /// nothing about context rather than guessing. This is the shape every caller used before
        /// the fourth fact existed, kept as an overload so those call sites keep saying exactly
        /// what they always said.
        static func reconnected(audioRestored: Bool, needsVisualEvidence: Bool) -> Signal {
            .reconnected(audioRestored: audioRestored, needsVisualEvidence: needsVisualEvidence,
                         contextCarried: true)
        }
        /// The retry ladder gave up.
        case reconnectExhausted
        /// The session ended (stopped, or torn down after a terminal failure).
        case sessionEnded
        /// A capture the wearer asked for produced an image. Fired from the success boundary only.
        case requestedCaptureSucceeded
    }

    // MARK: - Dependencies

    private let isActive: () -> Bool
    private let style: () -> AudibleLifecyclePolicy.CueStyle
    private let route: () -> AudibleLifecyclePolicy.SpeechRoute
    private let visualEvidence: () -> Bool
    private let now: () -> Date
    private let playEarcon: (AudibleLifecyclePolicy.Earcon) -> Void
    /// `(line, interrupts)`. The sink decides how an interrupting line takes the floor.
    private let speak: (String, Bool) -> Void
    private let autoPump: Bool

    init(isActive: @escaping () -> Bool,
         style: @escaping () -> AudibleLifecyclePolicy.CueStyle = { .tonesAndSpeech },
         route: @escaping () -> AudibleLifecyclePolicy.SpeechRoute = { .init() },
         visualEvidence: @escaping () -> Bool = { false },
         now: @escaping () -> Date = Date.init,
         autoPump: Bool = true,
         playEarcon: @escaping (AudibleLifecyclePolicy.Earcon) -> Void,
         speak: @escaping (String, Bool) -> Void) {
        self.isActive = isActive
        self.style = style
        self.route = route
        self.visualEvidence = visualEvidence
        self.now = now
        self.autoPump = autoPump
        self.playEarcon = playEarcon
        self.speak = speak
    }

    deinit { pumpTask?.cancel() }

    // MARK: - State

    /// One notice waiting for the route.
    private struct Pending {
        let notice: AudibleLifecyclePolicy.Notice
        let generation: Int
        let postedAt: Date
    }

    /// A reconnect whose recovery shape is not decided yet, because the camera has not had a chance
    /// to produce a picture. The whole reason the cue is not fired from the callback.
    private struct PendingRecovery {
        let audioRestored: Bool
        let needsVisualEvidence: Bool
        /// Decided at reconnect time and carried through the wait unchanged: waiting for the camera
        /// tells you nothing new about whether the conversation survived.
        let contextCarried: Bool
        let generation: Int
        let deadline: Date
    }

    /// Bumped whenever a session starts or ends. A notice posted under an older generation describes
    /// a session that no longer exists and is dropped rather than spoken about a new one.
    private(set) var generation: Int = 0

    private var queue: [Pending] = []
    private var pendingRecovery: PendingRecovery?
    private var lastDelivered: (notice: AudibleLifecyclePolicy.Notice, at: Date)?
    /// Whether this generation's loss notice actually reached the wearer. Decides whether a plain
    /// recovery is news or noise (see `isWorthSayingWithoutAHeardLoss`).
    private var lossWasHeard = false
    private var pumpTask: Task<Void, Never>?

    /// How long a reconnect waits for the camera to prove itself before the cue goes out as
    /// camera-unavailable. Comfortably longer than `CameraReadiness.evidenceMaxAge` and than a
    /// healthy frame interval, so an ordinary recovery is reported as a full one.
    static let recoveryEvidenceWindow: TimeInterval = 3

    /// Cadence of the internal timer, when one is running. Only ever runs while something is
    /// waiting, so an idle session costs nothing.
    static let pumpInterval: TimeInterval = 0.5

    /// Whether anything is waiting to be said or decided.
    var hasPendingWork: Bool { !queue.isEmpty || pendingRecovery != nil }

    /// How many notices are waiting for the route. Exposed so the bound is assertable rather than
    /// only documented.
    var pendingCount: Int { queue.count }

    /// Whether a notice of this kind is currently waiting.
    func isPending(_ notice: AudibleLifecyclePolicy.Notice) -> Bool {
        queue.contains { $0.notice == notice }
    }

    // MARK: - Signals

    /// Report a lifecycle signal.
    ///
    /// Returns whether this coordinator took responsibility for telling the wearer. A session
    /// manager that has its own local spoken cue uses the answer to stay quiet rather than say the
    /// same thing twice — and "took responsibility" deliberately includes *queued*, because a cue
    /// that is waiting for the route is still this coordinator's to deliver.
    @discardableResult
    func handle(_ signal: Signal) -> Bool {
        guard isActive() else { return false }

        let accepted: Bool
        switch signal {
        case .sessionStarted(let readiness):
            beginGeneration()
            if let notice = AudibleLifecyclePolicy.startupNotice(for: readiness) {
                post(notice)
            }
            accepted = true

        case .connectionLost:
            post(.connectionLost)
            accepted = true

        case .reconnected(let audioRestored, let needsVisualEvidence, let contextCarried):
            noteReconnect(audioRestored: audioRestored, needsVisualEvidence: needsVisualEvidence,
                          contextCarried: contextCarried)
            accepted = true

        case .reconnectExhausted:
            // A terminal failure supersedes anything still waiting about this session: there is no
            // longer a retry to report, and "trying to get it back" after "I gave up" is nonsense.
            pendingRecovery = nil
            queue.removeAll { $0.notice == .connectionLost }
            post(.recoveryFailed)
            accepted = true

        case .sessionEnded:
            // Nothing is said for an ordinary stop, so nothing is claimed either — a caller with
            // its own cue for that keeps it.
            endGeneration()
            accepted = false

        case .requestedCaptureSucceeded:
            post(.captureSucceeded)
            accepted = true
        }
        pump()
        return accepted
    }

    /// A session began. Everything queued about the previous one is about a session that is gone.
    private func beginGeneration() {
        generation += 1
        queue.removeAll()
        pendingRecovery = nil
        lossWasHeard = false
    }

    /// A session ended. Same reasoning, and nothing new is posted — the wearer stopped it, or the
    /// terminal failure cue has already gone out.
    private func endGeneration() {
        generation += 1
        queue.removeAll()
        pendingRecovery = nil
        lossWasHeard = false
        cancelPumpIfIdle()
    }

    private func noteReconnect(audioRestored: Bool, needsVisualEvidence: Bool,
                               contextCarried: Bool) {
        guard audioRestored else {
            // Nothing to wait for: a reconnect with no microphone is decided the moment it happens.
            post(AudibleLifecyclePolicy.recoveryNotice(
                for: .init(audioRestored: false,
                           needsVisualEvidence: needsVisualEvidence,
                           hasFreshVisualEvidence: false,
                           contextCarried: contextCarried)))
            return
        }
        // Evidence may already be in hand (an audio-only session, or a camera that never stopped).
        // Otherwise wait — bounded — rather than report the absence of a picture that has not had
        // time to arrive.
        if !needsVisualEvidence || visualEvidence() {
            post(AudibleLifecyclePolicy.recoveryNotice(
                for: .init(audioRestored: true,
                           needsVisualEvidence: needsVisualEvidence,
                           hasFreshVisualEvidence: true,
                           contextCarried: contextCarried)))
            return
        }
        pendingRecovery = PendingRecovery(audioRestored: true,
                                          needsVisualEvidence: true,
                                          contextCarried: contextCarried,
                                          generation: generation,
                                          deadline: now().addingTimeInterval(Self.recoveryEvidenceWindow))
        // A recovery under evaluation already makes the queued loss false.
        queue.removeAll { $0.notice == .connectionLost }
        startPumpIfNeeded()
    }

    // MARK: - Queueing

    private func post(_ notice: AudibleLifecyclePolicy.Notice) {
        // Coalescing: a recovery statement expires a loss that was never heard.
        queue.removeAll { AudibleLifecyclePolicy.expires($0.notice, on: notice) }

        if AudibleLifecyclePolicy.isRecoveryStatement(notice),
           !lossWasHeard,
           !AudibleLifecyclePolicy.isWorthSayingWithoutAHeardLoss(notice) {
            // The wearer heard no interruption, so there is nothing to correct.
            return
        }

        let pending = Pending(notice: notice, generation: generation, postedAt: now())
        queue.append(pending)
        enforceDepth()
        startPumpIfNeeded()
    }

    /// Keep the queue short, and never let a cosmetic notice push a failure out of it.
    private func enforceDepth() {
        while queue.count > AudibleLifecyclePolicy.maxQueueDepth {
            // Evict the least important thing waiting; ties go to the oldest, which has had the
            // longest chance to become irrelevant.
            guard let victim = queue.indices.min(by: { lhs, rhs in
                let l = queue[lhs], r = queue[rhs]
                let lp = AudibleLifecyclePolicy.priority(of: l.notice)
                let rp = AudibleLifecyclePolicy.priority(of: r.notice)
                if lp != rp { return lp < rp }
                return l.postedAt < r.postedAt
            }) else { return }
            queue.remove(at: victim)
        }
    }

    // MARK: - Delivery

    /// Resolve anything that has become decidable, drop anything that has become untrue or stale,
    /// and deliver at most one notice. Returns what was delivered, for tests and for callers that
    /// want to know whether the wearer was told.
    @discardableResult
    func pump() -> [AudibleLifecyclePolicy.Notice] {
        let at = now()
        resolvePendingRecovery(at: at)

        // A notice about a session that no longer exists says nothing true about this one.
        queue.removeAll { $0.generation != generation }
        // …and one that was about a moment which has passed describes the wrong moment.
        queue.removeAll { pending in
            guard let stale = AudibleLifecyclePolicy.staleAfter(pending.notice) else { return false }
            return at.timeIntervalSince(pending.postedAt) > stale
        }

        guard !queue.isEmpty else {
            cancelPumpIfIdle()
            return []
        }

        let routeIsBusy = route().isBusy
        let index: Int?
        if routeIsBusy {
            // The route is occupied, so only a failure that has waited out its bound goes now:
            // "do not drop the only failure notice indefinitely."
            index = highestPriorityIndex(where: { pending in
                AudibleLifecyclePolicy.isFailure(pending.notice)
                    && at.timeIntervalSince(pending.postedAt) >= AudibleLifecyclePolicy.maxQueuedWait
            })
        } else {
            index = highestPriorityIndex(where: { _ in true })
        }
        guard let index else {
            cancelPumpIfIdle()
            return []
        }

        let pending = queue.remove(at: index)
        cancelPumpIfIdle()
        guard deliver(pending.notice, at: at) else { return [] }
        return [pending.notice]
    }

    private func highestPriorityIndex(where include: (Pending) -> Bool) -> Int? {
        queue.indices
            .filter { include(queue[$0]) }
            .max(by: { lhs, rhs in
                let l = queue[lhs], r = queue[rhs]
                let lp = AudibleLifecyclePolicy.priority(of: l.notice)
                let rp = AudibleLifecyclePolicy.priority(of: r.notice)
                if lp != rp { return lp < rp }
                return l.postedAt > r.postedAt   // older first among equals
            })
    }

    private func resolvePendingRecovery(at: Date) {
        guard let recovery = pendingRecovery else { return }
        guard recovery.generation == generation else {
            pendingRecovery = nil
            return
        }
        let haveEvidence = visualEvidence()
        guard haveEvidence || at >= recovery.deadline else { return }
        pendingRecovery = nil
        post(AudibleLifecyclePolicy.recoveryNotice(
            for: .init(audioRestored: recovery.audioRestored,
                       needsVisualEvidence: recovery.needsVisualEvidence,
                       hasFreshVisualEvidence: haveEvidence,
                       contextCarried: recovery.contextCarried)))
    }

    /// Play and speak. Returns whether it actually went out — an identical notice inside the repeat
    /// window is a republish, not a second event.
    private func deliver(_ notice: AudibleLifecyclePolicy.Notice, at: Date) -> Bool {
        if let last = lastDelivered, last.notice == notice,
           at.timeIntervalSince(last.at) < AudibleLifecyclePolicy.repeatWindow {
            return false
        }
        lastDelivered = (notice, at)
        if notice == .connectionLost { lossWasHeard = true }

        let cue = AudibleLifecyclePolicy.cue(for: notice, style: style())
        playEarcon(cue.earcon)
        if let spoken = cue.spoken { speak(spoken, cue.interrupts) }
        return true
    }

    // MARK: - The internal timer
    //
    // Only runs while something is waiting. The queue's deadlines are wall-clock, so without a tick
    // a bounded wait would only expire the next time some unrelated signal arrived — which is
    // exactly the "the failure notice was never delivered" bug in another costume.

    private func startPumpIfNeeded() {
        guard autoPump, hasPendingWork, pumpTask == nil else { return }
        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pumpInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.pump()
                if !self.hasPendingWork { return }
            }
        }
    }

    private func cancelPumpIfIdle() {
        guard !hasPendingWork else { return }
        pumpTask?.cancel()
        pumpTask = nil
    }

    // MARK: - Cue learning

    /// Play every cue with its meaning, in order. Runs regardless of which live preset is selected:
    /// it is reached from a settings control the wearer deliberately activated, and a wearer
    /// deciding *whether* to use Blind Assistant should be able to hear what it will sound like.
    ///
    /// Returns the task so a caller can cancel it; a second call replaces the first rather than
    /// interleaving two tours.
    @discardableResult
    func playCueTour(gap secondsBetween: TimeInterval = AudibleLifecyclePolicy.lessonGap) -> Task<Void, Never> {
        tourTask?.cancel()
        let gap = UInt64(max(0, secondsBetween) * 1_000_000_000)
        let task = Task { [weak self] in
            for lesson in AudibleLifecyclePolicy.lessons {
                guard !Task.isCancelled, let self else { return }
                self.playEarcon(lesson.earcon)
                try? await Task.sleep(nanoseconds: gap)
                guard !Task.isCancelled else { return }
                self.speak(lesson.meaning, false)
                // The spoken line has to finish before the next tone, or the tour teaches the
                // wrong pairing. The sink's own speech serialisation does the waiting; this gap
                // just keeps the tone off the tail of the sentence.
                try? await Task.sleep(nanoseconds: gap)
            }
        }
        tourTask = task
        return task
    }

    private var tourTask: Task<Void, Never>?
}
