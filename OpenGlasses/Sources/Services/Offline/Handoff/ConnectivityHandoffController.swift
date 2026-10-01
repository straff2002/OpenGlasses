import Foundation

/// The live half of the offline handoff (Plan GE P1/P2).
///
/// Owns the pure ``ConnectivityHandoffPolicy``, feeds it path edges from `Reachability` and the
/// outcome of every cloud attempt from `LLMService`, runs the return probe on a backoff, and applies
/// the route changes the policy makes: the announcement (``HandoffAnnouncer``), the HUD status chip,
/// and — on the way back — the note to the cloud model and the held question.
///
/// It decides *how a turn is served* (``planTurn(_:)``); `AppState` carries the plan out, because
/// that is where the turn pipeline lives. Every side effect goes through ``Seams``, so the whole
/// controller runs headlessly in `ConnectivityHandoffControllerTests` with a fake clock, a fake
/// probe and recorded speech.
@MainActor
final class ConnectivityHandoffController: ObservableObject {

    /// What happens on the way back to the cloud, for `AppState` to carry out.
    struct ReturnContext: Equatable {
        /// The one-line note for the cloud model naming the answers given on the phone, or nil.
        var inboundNote: String?
        /// The question held while nothing could think, classified by age.
        var heldQuestion: HeldQuestionStore.TakeResult
        /// This conversation's exchanges answered on the phone, oldest first — the seed for a live
        /// session that is resumed (Plan GE P3).
        var answeredOnPhone: [HandoffTranscriptBridge.OnDeviceAnswer] = []
    }

    /// How the current turn is served.
    enum TurnPlan: Equatable {
        /// As normal.
        case cloud
        /// On the phone, by this saved on-device model configuration.
        case phoneModel(configId: String)
        /// On the phone, by a native tool with no model (``OfflineKeywordRouter``).
        case deterministic(OfflineKeywordRouter.Route)
        /// Nothing on the phone can think it through: hold it for the cloud.
        case hold
    }

    struct Seams {
        var now: () -> Date
        /// The setting is on, an on-device model is installed, and medical local-only is off.
        var isEnabled: () -> Bool
        var isAppActive: () -> Bool
        var availableBrains: () -> OfflineBrainSelector.Available
        /// Probe the cloud model's host.
        var probe: () async -> ConnectivityProbe.Outcome
        /// Items waiting in the offline queue.
        var queuedItems: () -> Int
        /// A turn is being inferred or spoken; route changes wait for it.
        var isBusy: () -> Bool
        /// A live session is up. Its own recovery cues speak for the connection while it retries,
        /// so the handoff does not announce on top of them (Plan GE P3).
        var liveSessionActive: () -> Bool
        var speak: (String) async -> Void
        /// Show a short HUD status line.
        var showStatus: (String) -> Void
        /// Post a local notification (title, body).
        var notify: (String, String) -> Void
        /// The conversation a held question belongs to.
        var conversationId: () -> String
        /// Carry out the return: inject the note, answer or drop the held question.
        var onReturnToCloud: (ReturnContext) async -> Void
        var sleep: (TimeInterval) async -> Void

        init(now: @escaping () -> Date = Date.init,
             isEnabled: @escaping () -> Bool,
             isAppActive: @escaping () -> Bool,
             availableBrains: @escaping () -> OfflineBrainSelector.Available,
             probe: @escaping () async -> ConnectivityProbe.Outcome,
             queuedItems: @escaping () -> Int = { 0 },
             isBusy: @escaping () -> Bool = { false },
             liveSessionActive: @escaping () -> Bool = { false },
             speak: @escaping (String) async -> Void,
             showStatus: @escaping (String) -> Void = { _ in },
             notify: @escaping (String, String) -> Void = { _, _ in },
             conversationId: @escaping () -> String = { "default" },
             onReturnToCloud: @escaping (ReturnContext) async -> Void = { _ in },
             sleep: @escaping (TimeInterval) async -> Void = { seconds in
                 try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
             }) {
            self.now = now
            self.isEnabled = isEnabled
            self.isAppActive = isAppActive
            self.availableBrains = availableBrains
            self.probe = probe
            self.queuedItems = queuedItems
            self.isBusy = isBusy
            self.liveSessionActive = liveSessionActive
            self.speak = speak
            self.showStatus = showStatus
            self.notify = notify
            self.conversationId = conversationId
            self.onReturnToCloud = onReturnToCloud
            self.sleep = sleep
        }
    }

    /// The route turns take right now.
    @Published private(set) var route: HandoffRoute

    private(set) var policy: ConnectivityHandoffPolicy
    private(set) var announcer = HandoffAnnouncer()
    private(set) var heldQuestions = HeldQuestionStore()
    /// The exchanges answered on the phone this episode, with the conversation each belongs to,
    /// for the note on return.
    private(set) var onDeviceAnswers: [(conversationId: String, answer: HandoffTranscriptBridge.OnDeviceAnswer)] = []

    var seams: Seams
    /// Plan GE P3: the live mode whose session was handed to the phone, to start again on return.
    var pendingLiveResume: AppMode?
    /// Off in tests, which drive ``tick()`` by hand.
    var autoSchedulesTicks = true
    /// How often the background loop re-evaluates while on the phone.
    var tickInterval: TimeInterval = 5

    private var heldLineSaidThisEpisode = false
    private var isProbing = false
    private var loopTask: Task<Void, Never>?

    init(initiallyOnline: Bool = true, tuning: ConnectivityHandoffPolicy.Tuning = .standard, seams: Seams) {
        self.seams = seams
        let policy = ConnectivityHandoffPolicy(tuning: tuning, pathSatisfied: initiallyOnline, now: seams.now())
        self.policy = policy
        self.route = policy.appliedRoute
    }

    /// Whether the handoff will act at all right now.
    var isEnabled: Bool { seams.isEnabled() }

    /// The setting's effective value: on, with something on the phone that can think, and not under
    /// medical local-only (which never uses the cloud, so there is nothing to hand off from). Pure.
    nonisolated static func isEffectivelyEnabled(setting: Bool, available: OfflineBrainSelector.Available,
                                                 medicalLocalOnly: Bool) -> Bool {
        setting && available.hasAnyModel && !medicalLocalOnly
    }

    // MARK: - Inputs

    /// A `Reachability` edge.
    func pathChanged(online: Bool) async {
        await handle(online ? .pathSatisfied : .pathUnsatisfied)
        ensureLoop()
    }

    /// The outcome of one cloud model attempt. Only connectivity-class failures count against the
    /// cloud; a 429 or a bad key says nothing about the signal.
    func noteCloudAttempt(error: Error?) {
        let event: ConnectivityHandoffPolicy.Event
        if let error {
            guard ConnectivityFailure.isConnectivityFailure(error) else { return }
            event = .connectivityFailure
        } else {
            event = .cloudSuccess
        }
        Task { await self.handle(event) }
    }

    /// A turn finished: a route change that waited for it applies now.
    func turnEnded() async {
        await applyIfIdle()
        ensureLoop()
    }

    /// Time-based work: expire held questions, probe when due, apply what waited, release an owed
    /// return line. The background loop calls this every ``tickInterval`` while it matters.
    func tick() async {
        let now = seams.now()
        if heldQuestions.expire(now: now) > 0 {
            seams.notify(HandoffAnnouncer.heldExpiredNotificationTitle,
                         HandoffAnnouncer.heldExpiredNotificationBody)
        }
        // Never mid-turn: a phone turn has the on-device model active, and the probe aims at the
        // cloud model the conversation would return to.
        if !isProbing, !seams.isBusy(), policy.isProbeDue(now: now) {
            isProbing = true
            let outcome = await seams.probe()
            isProbing = false
            switch outcome {
            case .reachable, .notProbeable: await handle(.probeSucceeded)
            case .unreachable: await handle(.probeFailed)
            }
        }
        await applyIfIdle()
        if !seams.isBusy(), let line = announcer.owedLine(now: seams.now(), onCloud: route == .cloud) {
            await seams.speak(line)
        }
    }

    // MARK: - Turns

    /// How the next turn should be served. `.cloud` whenever the handoff is off or the conversation
    /// is on the cloud.
    func planTurn(_ utterance: String) -> TurnPlan {
        guard route == .phone, isEnabled else { return .cloud }
        if let deterministic = OfflineKeywordRouter.route(utterance),
           OfflineToolPolicy.availability(of: deterministic.toolName) == .local {
            return .deterministic(deterministic)
        }
        return modelPlan()
    }

    /// The phone's answer when no tool can serve the turn deterministically (or the tool came back
    /// empty): an on-device model if one can run right now, otherwise hold.
    func modelPlan() -> TurnPlan {
        let brain = OfflineBrainSelector.select(appActive: seams.isAppActive(),
                                                available: seams.availableBrains())
        guard let configId = brain.configId else { return .hold }
        return .phoneModel(configId: configId)
    }

    /// Hold a question nothing on the phone can answer. Returns the line to say: the full
    /// explanation once per episode, a short acknowledgement after that.
    func hold(_ question: String) -> String {
        heldQuestions.hold(question, conversationId: seams.conversationId(), now: seams.now())
        defer { heldLineSaidThisEpisode = true }
        ensureLoop()
        return heldLineSaidThisEpisode ? HandoffAnnouncer.heldReplacedLine : HandoffAnnouncer.heldFirstLine
    }

    /// An exchange answered on the phone, for the note the cloud model gets on return.
    func recordOnDeviceAnswer(question: String, answer: String) {
        onDeviceAnswers.append((seams.conversationId(), .init(question: question, answer: answer)))
    }

    /// A conversation reset: nothing held or noted belongs to the new conversation.
    func conversationReset() {
        heldQuestions.removeAll()
        onDeviceAnswers.removeAll()
    }

    /// A live session lost its socket for good and the conversation carries on on the phone (Plan GE
    /// P3). Remembers the mode to resume and says so once — this line stands in for the ordinary
    /// "lost signal" announcement.
    func liveSessionHandedToPhone(resume mode: AppMode) async {
        pendingLiveResume = mode
        if let line = announcer.lineForLiveHandoff(now: seams.now()) {
            await seams.speak(line)
        }
        ensureLoop()
    }

    /// The offline-queue sync line was spoken on a rising edge; it already told the wearer the
    /// connection is back.
    func noteSyncLineSpoken() {
        announcer.noteSpokenReturn(now: seams.now())
    }

    // MARK: - Applying

    private func handle(_ event: ConnectivityHandoffPolicy.Event) async {
        if seams.isBusy() { policy.beginTurn() }
        if let change = policy.handle(event, now: seams.now()) {
            await apply(change)
        }
    }

    private func applyIfIdle() async {
        guard !seams.isBusy() else { return }
        if let change = policy.endTurn() { await apply(change) }
    }

    private func apply(_ newRoute: HandoffRoute) async {
        route = newRoute
        let now = seams.now()
        switch newRoute {
        case .phone:
            heldLineSaidThisEpisode = false
            let enabled = isEnabled
            if !seams.liveSessionActive() {
                seams.showStatus(enabled ? HandoffAnnouncer.phoneStatusChip : HandoffAnnouncer.offlineStatusChip)
                if let line = announcer.lineForEnteringPhone(now: now, canThinkOnPhone: enabled,
                                                             queuedItems: seams.queuedItems()) {
                    await seams.speak(line)
                }
            }
            PrivacyLog.model(.offlineHandoff, detail: PrivacyToken(enabled ? "phone" : "phoneInert"))
        case .cloud:
            if let line = announcer.lineForReturn(now: now) {
                seams.showStatus(line)
                await seams.speak(line)
            }
            // Only this conversation's phone answers are named: a reset in between started a new
            // conversation whose model has never seen the old ones.
            let conversationId = seams.conversationId()
            let answers = onDeviceAnswers.filter { $0.conversationId == conversationId }.map(\.answer)
            let context = ReturnContext(
                inboundNote: HandoffTranscriptBridge.inboundNote(answers),
                heldQuestion: heldQuestions.take(conversationId: conversationId, now: now),
                answeredOnPhone: answers)
            onDeviceAnswers.removeAll()
            heldQuestions.removeAll()
            PrivacyLog.model(.offlineHandoff, count: context.inboundNote == nil ? 0 : 1,
                             detail: PrivacyToken("cloud"))
            await seams.onReturnToCloud(context)
        }
    }

    private func ensureLoop() {
        guard autoSchedulesTicks, loopTask == nil, needsTicking else { return }
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.seams.sleep(self.tickInterval)
                await self.tick()
                if !self.needsTicking { break }
            }
            self?.loopTask = nil
        }
    }

    /// The loop has work while on the phone, while a change waits, or while a question is held.
    private var needsTicking: Bool {
        route == .phone || policy.hasPendingChange || !heldQuestions.isEmpty
            || announcer.wearerBelievesOffline || pendingLiveResume != nil
    }
}
