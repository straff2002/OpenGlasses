import Foundation

/// Plan LU P1 — `AppState` as the owner of the private conversation.
///
/// The state and the transcript live in `privateConversation` (a `PrivateConversationController`,
/// observed by the phone and watch surfaces the way `guidedJobFlow` is). This is everything around
/// it that needs the app: the start refusals read from the job, the organisation's profile and the
/// live session; the model's context, the gateway key and the quiet-gap timer that follow a start
/// and an end; and the one helper every conversation-store write goes through.
///
/// **The only writers** of the private state are `beginPrivate(entry:)`, `endPrivate(reason:)` and
/// `notePrivateEvent(_:announce:)` (which ends through the same path).
extension AppState {

    // MARK: - Persistence (Plan LU §3)

    /// Whether this turn is written to the conversation store: conversation history is on and no
    /// private conversation is open. Every `ConversationStore` write a turn makes goes through it,
    /// so a private turn writes no thread, message, title, summary or active-thread id.
    var persistsConversation: Bool {
        Config.conversationPersistenceEnabled && !privateConversation.isActive
    }

    /// A private turn's message, into the private transcript and nowhere else. A no-op with no
    /// private conversation open, so it sits in the `else` of every persistence check.
    func notePrivateTurn(role: String, content: String) {
        privateConversation.append(role: role, content: content)
    }

    // MARK: - Starting (Plan LU §2)

    /// What a start is decided on, read from the app now.
    func privateStartConditions() -> PrivateStartConditions {
        let sessions = FieldSessionService.shared
        let session = sessions.activeSession
        var jobThreads = Set(sessions.history.compactMap(\.conversationThreadId))
        if let bound = session?.conversationThreadId { jobThreads.insert(bound) }
        if let debrief = guidedJobFlow.debrief?.threadId { jobThreads.insert(debrief) }
        return PrivateStartConditions(
            jobOpen: session.map { $0.endedAt == nil && $0.outcome != .cancelled } ?? false,
            activeThreadBelongsToJob: conversationStore.activeThreadId.map(jobThreads.contains) ?? false,
            organisationPinnedOff: PolicyEnvelope.isLocked(.privateConversationsAllowed),
            allowedInSettings: Config.privateConversationsAllowed,
            liveRunning: geminiLiveSession.isActive || openAIRealtimeSession.isActive)
    }

    /// Start a private conversation, or say why not. The stored conversation open now is left
    /// exactly as it was, still active, so the next ordinary conversation can carry on from it.
    ///
    /// - Returns: nil when one is open afterwards (already private counts); the refusal otherwise,
    ///   whose `reason` is what the wearer is told.
    @discardableResult
    func beginPrivate(entry: PrivateEntry) -> PrivateStartRefusal? {
        let wasActive = privateConversation.isActive
        if let refusal = privateConversation.begin(entry: entry, conditions: privateStartConditions()) {
            return refusal
        }
        guard !wasActive else { return nil }
        // The model's context becomes the private transcript, replayed as a stored thread's is;
        // the stored conversation's is put aside to come back at the end.
        llmService.beginPrivateHistory(privateConversation.transcript.replayMessages())
        // The gateway hears the private conversation under a key of its own (§5).
        openClawBridge.beginPrivateSession()
        // A question held for the cloud while offline belongs to the conversation it was asked in:
        // none crosses into the private one, and none of the private one's is replayed after it.
        connectivityHandoff.conversationReset()
        schedulePrivateIdleCheck()
        privateConversationDidStart()
        return nil
    }

    /// The header's and the Chat list's **Start a private conversation** (Plan LU P1b). A refusal
    /// is shown the way the app's other short notices are; a start says nothing out loud, since
    /// the wearer is looking at the phone and the page now says Private.
    @discardableResult
    func startPrivateFromButton() -> PrivateStartRefusal? {
        let refusal = beginPrivate(entry: .button)
        if let refusal {
            NoticeCenter.shared.post(refusal.reason, severity: .warning, source: .app)
        }
        return refusal
    }

    /// The watch's Private and End (Plan LU P1b): the reply the watch is sent back.
    func handleWatchPrivateRequest(_ action: WatchPrivateWire.Action) -> [String: Any] {
        switch action {
        case .start:
            let refusal = beginPrivate(entry: .watch)
            return WatchPrivateWire.reply(isPrivate: privateConversation.isActive, refusal: refusal?.reason)
        case .end:
            notePrivateEvent(.endOnWatch)
            return WatchPrivateWire.reply(isPrivate: privateConversation.isActive, refusal: nil)
        }
    }

    /// What follows every start, on the surfaces that show it: *Private* on the lens for three
    /// seconds (Display glasses only; the HUD's own gate drops it elsewhere), and the Live
    /// Activity's placeholder at once rather than at the next turn. The watch hears through its
    /// observer of `privateConversation`.
    private func privateConversationDidStart() {
        glassesDisplay.flash(PrivateConversationLines.badge, duration: PrivateConversationLines.lensSeconds)
        updateLiveActivity()
    }

    // MARK: - Ending (Plan LU §8)

    /// End the private conversation for `reason`. Says nothing: the caller knows whether the
    /// wearer is there to hear it (`PrivateConversationLines.announcesEnd`).
    func endPrivate(reason: PrivateEndReason) {
        guard privateConversation.end(reason) else { return }
        privateConversationDidEnd()
    }

    /// Something happened that might end the private conversation. Ends it when `PrivateEndPolicy`
    /// says so, and says "Private conversation ended." when `announce` and the wearer is there to
    /// hear it.
    @discardableResult
    func notePrivateEvent(_ event: PrivateEndEvent, announce: Bool = true) -> PrivateEndReason? {
        guard let reason = privateConversation.handle(event) else { return nil }
        privateConversationDidEnd()
        if announce, PrivateConversationLines.announcesEnd(event) {
            let line = PrivateConversationLines.ended
            Task { @MainActor [weak self] in await self?.speechService.speak(line, source: .acknowledgement) }
        }
        return reason
    }

    /// What follows every end: the model's context and the gateway key go back to the stored
    /// conversation's, and nothing on the glanceable surfaces still holds the private words.
    private func privateConversationDidEnd() {
        privateIdleTimer?.cancel()
        privateIdleTimer = nil
        llmService.endPrivateHistory()
        openClawBridge.endPrivateSession()
        connectivityHandoff.conversationReset()
        // The Live Activity and the watch read these; the private reply must not reappear on them
        // once the placeholder stops covering it.
        lastResponse = ""
        currentTranscription = ""
        updateLiveActivity()
    }

    /// The quiet gap, by timer: 30 minutes without a private turn ends it, said to nobody. The
    /// same gap is checked at the start of the next turn (`PrivateEndEvent.turnStarting`).
    private func schedulePrivateIdleCheck() {
        privateIdleTimer?.cancel()
        privateIdleTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let quiet = self?.privateConversation.quietFor,
                      self?.privateConversation.isActive == true else { return }
                let wait = max(1, PrivateEndPolicy.idleGap - quiet)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if self.notePrivateEvent(.idleTimerFired(quietFor: self.privateConversation.quietFor)) != nil {
                    return
                }
            }
        }
    }

    /// The app is being quit: the private conversation ends with it, for the record's one line.
    /// Its words were only ever in memory.
    func endPrivateForAppQuit() {
        notePrivateEvent(.appQuit, announce: false)
    }
}
