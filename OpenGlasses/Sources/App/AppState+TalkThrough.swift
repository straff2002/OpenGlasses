import Foundation

/// The app side of talk-through (Plan JI §7a, P6b): building the session on live hints' carriers,
/// starting and stopping it (never alongside live hints), the taps, the Live Activity's buttons and
/// the spoken words. Every decision is in the pure types under `Services/TalkThrough/`; this file
/// reads state and calls what exists.
@MainActor
extension AppState {

    /// The session's wiring: the same adapters live hints uses, with the running procedure, the
    /// job's manuals and the job's model rules beside them. No allowance: talk-through is part of
    /// running a procedure, not a listening session (decision 25).
    func makeTalkThrough() -> TalkThroughService {
        let sessions = FieldSessionService.shared
        let service = TalkThroughService(carriers: .init(
            captions: AmbientCaptionHintSource(service: ambientCaptions),
            procedure: sessions,
            manuals: sessions,
            model: LLMServiceHintModel(llm: llmService, isOnline: { [weak self] in self?.reachability.isOnline ?? true }),
            // Over a procedure's step card a hint flashes, and the step card comes back (Plan MO §5a).
            lens: GlassesHintLens(display: glassesDisplay, answerCard: hudAnswerCard,
                                  taskCardShowing: { [weak self] in
                                      guard let router = self?.hudRouter else { return false }
                                      return router.isPresentingTask && !router.isPresentingMenu
                                  }),
            ear: TTSHintEar(tts: speechService),
            voiceActivity: MicLevelHintVoiceActivity(wakeWordService: wakeWordService),
            clock: SystemHintClock(),
            similarity: EmbedderTalkThroughSimilarity()))
        service.resolvedProvider = { [weak self] in self?.llmService.statelessModelProvider() }
        service.medicalLocalOnly = { Self.medicalLocalOnlyEnforced }
        service.vocabulary = { procedure in
            TalkThroughService.procedureVocabulary(procedure, equipment: FieldSessionService.shared.activeEquipment)
        }
        service.recognitionMustStayOnPhone = {
            TalkThroughRecognitionPolicy.requiresOnDevice(
                vaultOnly: FieldSessionService.shared.vaultOnlyJobOpen, medicalCompliance: Config.hipaaMode,
                medicalLocalOnly: Self.medicalLocalOnlyEnforced, privateConversation: PrivateConversationGate.isActive)
        }
        let captions = ambientCaptions
        service.applyOnDeviceRecognition = { captions.sessionRequiresOnDeviceRecognition = $0 }
        service.onRunningChanged = { [weak self] running in
            guard let self else { return }
            self.talkThroughRunning = running
            // The idle listener moves to the mic the setup gives (`TalkThroughMicPlan`), and back.
            self.wakeWordService.liveHintsSessionChanged()
            // The taps, the Live Activity and its buttons follow the session, as for live hints.
            self.liveHintsSessionChanged()
        }
        return service
    }

    private static var medicalLocalOnlyEnforced: Bool {
        MedicalLLMRoutingPolicy.isEnforced(hipaaMode: Config.hipaaMode, localOnly: Config.hipaaLocalOnly)
    }

    /// The session holding the taps and the Live Activity now: talk-through or live hints, never both.
    var hintSessionOwner: HintSessionOwner? {
        HintSessionArbiter.owner(liveHintsRunning: liveHintsSessionActive, talkThroughRunning: talkThroughRunning)
    }

    /// Glasses with a display are connected: talk-through leaves their hands-free mic alone.
    var talkThroughGlassesHaveDisplay: Bool {
        isConnected && glassesDisplay.deviceSupportsDisplay()
    }

    /// The mic talk-through hears the wearer on, by setup (decision 24).
    var talkThroughMicRoute: MicRoute {
        TalkThroughMicPlan.route(glassesConnected: isConnected, glassesHaveDisplay: talkThroughGlassesHaveDisplay)
    }

    // MARK: - Start and stop

    /// Talk the running procedure through. A live hints session stops first, with one line.
    @discardableResult
    func startTalkThrough() -> TalkThroughService.StartOutcome {
        guard FieldSessionService.shared.activeProcedure != nil else { return .noProcedure }
        guard !talkThroughRunning else { return .alreadyRunning }
        let handover = HintSessionArbiter.start(.talkThrough, running: liveHintsSessionActive ? .liveHints : nil)
        if handover.stop == .liveHints { stopActiveLiveHints() }
        let outcome = talkThrough.start()
        if outcome == .started { sayTalkThroughLine(handover.line ?? TalkThroughCopy.started) }
        return outcome
    }

    func stopTalkThrough() {
        guard talkThroughRunning else { return }
        talkThrough.stop(reason: .wearer)
    }

    /// Live hints is starting: talk-through stops first, and says so once.
    func yieldTalkThroughToLiveHints() {
        let handover = HintSessionArbiter.start(.liveHints, running: talkThroughRunning ? .talkThrough : nil)
        guard handover.stop == .talkThrough else { return }
        talkThrough.stop(reason: .liveHints)
        if let line = handover.line { sayTalkThroughLine(line) }
    }

    private func sayTalkThroughLine(_ line: String) {
        Task { @MainActor [weak self] in
            await self?.speechService.speak(line, source: .acknowledgement)
        }
    }

    // MARK: - Temple taps and media buttons

    /// A decoded tap while talk-through runs (`TalkThroughTapPolicy`): yes to a waiting proposal,
    /// otherwise repeat; two skip; three nothing. False with no talk-through running.
    func handleTalkThroughTap(_ gesture: TempleGesture) -> Bool {
        guard talkThroughRunning else { return false }
        let service = talkThrough
        let outcome = TalkThroughTapPolicy.resolve(gesture, sessionRunning: service.isRunning,
                                                   proposalWaiting: service.proposal != nil,
                                                   hintPlaying: service.isHintPlaying)
        guard outcome != .notOurs else { return false }
        if let earcon = TalkThroughTapPolicy.earcon(for: outcome) { playTempleEarcon(earcon) }
        switch outcome {
        case .confirmProposal: service.confirmProposal()
        case .repeatHint: service.repeatHint()
        case .skip: service.skip()
        case .ignored, .notOurs: break
        }
        PrivacyLog.speech(.talkThrough, .controlHandled, detail: PrivacyToken("tap.\(gesture)"))
        return true
    }

    /// The Live Activity's repeat, skip and stop, while talk-through holds it. False otherwise.
    func takeTalkThroughActivityCommand(_ command: LiveHintsActivityCommand) -> Bool {
        guard talkThroughRunning else { return false }
        switch command {
        case .repeatHint: talkThrough.repeatHint()
        case .skipHint: talkThrough.skip()
        case .stop: stopTalkThrough()
        }
        PrivacyLog.speech(.talkThrough, .controlHandled, detail: PrivacyToken("activity.\(command.rawValue)"))
        return true
    }

    // MARK: - Voice

    /// "Talk me through it", "stop talking me through", "just go", and a yes or no to a waiting
    /// proposal. Ahead of the procedure's no-model handler, but a yes or no the procedure needs (a
    /// yes/no step's answer, a read-back) is left to it. Returns whether the words were taken.
    func handleTalkThroughVoice(_ text: String) async -> Bool {
        if let command = TalkThroughVoiceCommand.parse(text) {
            let line: String?
            switch command {
            case .start:
                // With no procedure the words are a request for the assistant.
                guard FieldSessionService.shared.activeProcedure != nil else { return false }
                if talkThroughRunning {
                    line = TalkThroughCopy.alreadyRunning
                } else {
                    startTalkThrough()
                    line = nil
                }
            case .stop:
                guard talkThroughRunning else { return false }
                stopTalkThrough()
                line = TalkThroughCopy.stopped
            case .justGo:
                guard talkThroughRunning else { return false }
                talkThrough.turnOnJustGo()
                line = TalkThroughCopy.justGo
            }
            PrivacyLog.speech(.talkThrough, .controlHandled, detail: PrivacyToken("voice.\(command)"))
            if let line { await speechService.speak(line, source: .acknowledgement) }
            return true
        }
        guard talkThroughRunning else { return false }
        return talkThrough.takeReply(text, presentation: FieldSessionService.shared.activeProcedurePresentation)
    }
}
