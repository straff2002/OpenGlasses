import Foundation

/// The one place a conversation is retired, whichever way the wearer asked.
///
/// Three entry points reach it — the classifier's Tier-0 phrase route, the model calling the
/// `new_topic` tool, and the conversation UI's new-conversation action — and all three land on
/// the same state machine rather than each doing their own half of the job. Nothing here knows
/// how a backend resets; that is an adapter's business.
///
/// The sequence of one run:
///
/// 1. **requested** — the generation advances and any speech in flight is stopped. From this
///    instant everything produced by the old context is stale, *before* the outcome is known.
///    A failed reset therefore suppresses one answer the wearer asked to discard anyway, which is
///    the right way round: the alternative is speaking a reply from the conversation they just
///    asked to leave while the reset is still running.
/// 2. **inFlight** — wait for the turn boundary (a tool result owed to the model is delivered
///    first), then ask each backend in the plan, in order.
/// 3. **completed / failed** — only if *every* backend crossed the boundary are the phone's
///    history cleared and exactly one new saved thread started. Otherwise nothing local changes
///    and the wearer is told which backend held out. Clearing only the phone's display and
///    calling it a fresh start is the failure this plan exists to prevent.
///
/// Repeated requests coalesce: a second "new topic" while a reset is in flight joins the run
/// already going and returns its report, so two utterances can never make two threads.
@MainActor
final class ConversationResetCoordinator: ObservableObject {

    enum Phase: Equatable { case idle, requested, inFlight }

    struct Dependencies {
        /// The backends that own this conversation's context right now, in reset order.
        /// `.phoneHistory` is implicit and need not appear.
        var plan: @MainActor () -> [ConversationBackendID] = { [] }
        /// The adapter for a backend, or nil when none is registered (reported as unsupported).
        var adapter: @MainActor (ConversationBackendID) -> (any ConversationContextResetting)? = { _ in nil }
        /// Returns once no turn is mid-flight.
        var awaitTurnBoundary: @MainActor () async -> Void = {}
        /// Clear the phone's turn history. Runs only on the completed path.
        var clearLocalHistory: @MainActor () -> Void = {}
        /// Start exactly one new saved thread. Runs only on the completed path, and only when
        /// conversation persistence is on — the caller decides that, not this type.
        var startSavedThread: @MainActor () -> Void = {}
        /// Stop anything the old context is still saying.
        var stopSpeech: @MainActor () -> Void = {}
        /// Speak/show the confirmation. Called after the boundary is crossed, never before.
        var announce: @MainActor (ConversationResetReport) async -> Void = { _ in }
        /// Record the run (privacy log).
        var record: @MainActor (ConversationResetReport) -> Void = { _ in }
    }

    @Published private(set) var phase: Phase = .idle
    private(set) var lastReport: ConversationResetReport?

    /// Advances once per reset run. Anything produced by the conversation that was current when
    /// an older generation was captured is stale and must not reach the transcript or the speaker.
    private(set) var generation: UInt64 = 0

    /// How many requests joined a reset already running instead of starting their own. A wearer
    /// repeating "new topic" while the first one works is the common case, and the count is what
    /// makes "it coalesced" observable rather than inferred.
    private(set) var coalescedRequests: Int = 0

    private var dependencies: Dependencies
    private var inFlight: Task<ConversationResetReport, Never>?

    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
    }

    /// Wire the coordinator after the services it drives exist (AppState builds in stages).
    func configure(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// True while `generation` is still the one captured. The transcript and the speaker both
    /// gate on this.
    func isCurrent(_ captured: UInt64) -> Bool { captured == generation }

    /// The generation a turn should carry for the whole of its life.
    var currentGeneration: UInt64 { generation }

    @discardableResult
    func requestReset(source: ConversationResetSource) async -> ConversationResetReport {
        // Coalesce: the second "new topic" during a reset is the same reset. No second generation,
        // no second thread, no second confirmation.
        if let inFlight {
            coalescedRequests += 1
            return await inFlight.value
        }

        phase = .requested
        generation &+= 1
        dependencies.stopSpeech()

        let task = Task { @MainActor in await self.run(source: source) }
        inFlight = task
        let report = await task.value
        inFlight = nil
        phase = .idle
        return report
    }

    // MARK: - The run

    private func run(source: ConversationResetSource) async -> ConversationResetReport {
        phase = .inFlight

        // A tool result owed to the model is delivered before any context is retired.
        await dependencies.awaitTurnBoundary()

        var outcomes: [ConversationResetOutcome] = []
        for backend in dependencies.plan() where backend != .phoneHistory {
            guard let adapter = dependencies.adapter(backend) else {
                outcomes.append(.unsupported(backend, reason: "no reset is wired for this backend"))
                continue
            }
            outcomes.append(await adapter.resetConversationContext())
        }

        let remotesCrossed = outcomes.allSatisfy(\.crossedBoundary)
        if remotesCrossed {
            dependencies.clearLocalHistory()
            dependencies.startSavedThread()
            outcomes.insert(.completed(.phoneHistory), at: 0)
        }
        // Nothing is inserted for the phone on the held-back path: it was not asked and did not
        // refuse, and listing it among the backends that kept their context would put "this
        // conversation" into the spoken apology. `didRetireLocalContext` carries that fact.

        let report = ConversationResetReport(source: source,
                                             generation: generation,
                                             outcomes: outcomes,
                                             didRetireLocalContext: remotesCrossed)
        lastReport = report
        dependencies.record(report)
        await dependencies.announce(report)
        return report
    }
}
