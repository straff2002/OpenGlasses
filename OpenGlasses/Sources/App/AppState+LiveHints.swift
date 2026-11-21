import AVFoundation
import Foundation

/// The app side of live hints' surfaces (Plan MO P2): starting from the session sheet, the demo,
/// the controls that work without the phone (temple taps and media buttons, the Live Activity's
/// buttons, the fixed spoken phrases), the background stop and the talk note. Every decision is in
/// the pure types under `Services/LiveHints/`; this file reads state and calls what exists.
@MainActor
extension AppState {

    // MARK: - What the sheet offers

    /// A Display is connected and on: the sheet offers the lens, and starts there.
    var liveHintsDisplayConnected: Bool {
        isConnected && Config.glassesDisplayEnabled && glassesDisplay.deviceSupportsDisplay()
    }

    /// The sheet's choices as it opens.
    func liveHintsDefaultChoices() -> LiveHintsSessionChoices {
        LiveHintsSessionChoices.defaults(displayConnected: liveHintsDisplayConnected)
    }

    /// Diarization is on for captions, so voices are told apart and "That's me" means something.
    var liveHintsTellsVoicesApart: Bool { Config.isDiarizationConfigured }

    /// The session running now: the real one or the demo. Never both.
    var activeLiveHints: LiveHintsService? {
        if liveHintsRunning { return liveHints }
        if liveHintsDemoRunning { return liveHintsDemo }
        return nil
    }

    /// The phone list the running session fills.
    var activeLiveHintsList: LiveHintsPhoneList {
        liveHintsDemoRunning ? liveHintsDemoList : liveHintsList
    }

    var liveHintsSessionActive: Bool { liveHintsRunning || liveHintsDemoRunning }

    // MARK: - Start and stop

    /// Start a session from the sheet's choices. A glasses mic without glasses, and a talk note in
    /// Medical Compliance mode, go back to their defaults first.
    @discardableResult
    func startLiveHints(choices: LiveHintsSessionChoices) -> LiveHintsService.StartOutcome {
        stopLiveHintsDemo()
        let applied = choices.applying(glassesConnected: isConnected, medicalCompliance: Config.hipaaMode)
        return startLiveHints(applied.settings)
    }

    /// The demo (§11): the canned conversation through the same session code. A real session stops
    /// first; the demo never opens the microphone.
    @discardableResult
    func startLiveHintsDemo() -> LiveHintsService.StartOutcome {
        stopLiveHints()
        var settings = LiveHintsService.Settings()
        settings.delivery = liveHintsDisplayConnected ? .lens : .ear
        return liveHintsDemo.start(settings)
    }

    func stopLiveHintsDemo() {
        guard liveHintsDemoRunning else { return }
        liveHintsDemo.stop(reason: .wearer)
    }

    /// Stop whichever session runs.
    func stopActiveLiveHints() {
        stopLiveHints()
        stopLiveHintsDemo()
    }

    /// A session, real or demo, started or stopped: the taps, the Live Activity and the idle mic
    /// follow it.
    func liveHintsSessionChanged() {
        // While a session runs the taps are its own; at stop the wearer's setting is back exactly
        // as it was (`MediaTriggerService.sessionHoldChanged`).
        mediaTrigger.sessionHoldChanged()
        // The Listening pill's twin (§10): a Live Activity for the whole session, which carries
        // repeat, skip and stop. It ends with the session only if nothing else keeps one.
        if liveHintsSessionActive {
            liveActivityManager.start(glassesName: glassesService.deviceName ?? "Avenkin")
        } else if !listeningEnabled {
            liveActivityManager.end()
        }
        updateLiveActivity()
    }

    /// The demo's own wiring: it stops itself when its conversation is over.
    func makeLiveHintsDemo() -> LiveHintsService {
        let clock = SystemHintClock()
        let built = LiveHintsDemo.carriers(
            model: LLMServiceHintModel(llm: llmService, isOnline: { [weak self] in self?.reachability.isOnline ?? true }),
            lens: GlassesHintLens(display: glassesDisplay, answerCard: hudAnswerCard),
            ear: TTSHintEar(tts: speechService),
            phoneList: liveHintsDemoList,
            clock: clock)
        let service = LiveHintsService(carriers: built.carriers)
        service.captureNotice = LiveHintsCopy.demoNotice
        // The demo explains nothing about the room's audio, because it has none.
        service.firstRunAcknowledged = { true }
        service.setFirstRunAcknowledged = { _ in }
        service.speakerLabel = { Self.demoSpeakerLabel($0) }
        built.captions.onFinished = { [weak service] in service?.stop(reason: .demoEnded) }
        service.onRunningChanged = { [weak self] running in
            guard let self else { return }
            self.liveHintsDemoRunning = running
            self.liveHintsSessionChanged()
        }
        return service
    }

    /// The demo's two voices: "You" and "Visitor".
    nonisolated static func demoSpeakerLabel(_ speaker: Int) -> String {
        speaker == LiveHintsDemo.wearerSpeaker
            ? String(localized: "You", comment: "Live hints demo: the wearer's voice in the sample conversation.")
            : String(localized: "Visitor", comment: "Live hints demo: the other voice in the sample conversation.")
    }

    // MARK: - Temple taps and media buttons

    /// A decoded tap while a session runs: repeat or skip (`LiveHintsTapPolicy`). Returns false when
    /// no session runs, and the wearer's own mapping takes the tap.
    func handleLiveHintsTap(_ gesture: TempleGesture) -> Bool {
        guard let service = activeLiveHints else { return false }
        let outcome = LiveHintsTapPolicy.resolve(gesture, sessionRunning: service.isRunning,
                                                 hintPlaying: service.isHintPlaying)
        guard outcome != .notOurs else { return false }
        if let earcon = LiveHintsTapPolicy.earcon(for: outcome) { playTempleEarcon(earcon) }
        switch outcome {
        case .repeatHint: service.repeatLastHint()
        case .skipHint: service.skipHint()
        case .ignored, .notOurs: break
        }
        PrivacyLog.speech(.liveHints, .controlHandled, detail: PrivacyToken("tap.\(outcome)"))
        return true
    }

    // MARK: - The Live Activity's buttons

    /// Act on a press of a Live Activity button, if one is pending and fresh. Taken once, on the
    /// Darwin notification and on becoming active, whichever runs first.
    func takePendingLiveHintsCommand(trigger: String) {
        guard let command = PendingLiveHintsCommand.shared.consume() else { return }
        guard let service = activeLiveHints else {
            PrivacyLog.speech(.liveHints, .controlHandled, detail: PrivacyToken("activity.noSession"))
            return
        }
        switch command {
        case .repeatHint: service.repeatLastHint()
        case .skipHint: service.skipHint()
        case .stop: stopActiveLiveHints()
        }
        PrivacyLog.speech(.liveHints, .controlHandled, detail: PrivacyToken("activity.\(command.rawValue)"))
    }

    // MARK: - Voice

    /// "Start live hints", "stop hints", "show hints", "hint me about …" (`LiveHintsVoiceCommand`).
    /// Returns whether the words were taken; anything else goes on to the assistant. Stop, show and
    /// a keyword only mean something while a session runs.
    func handleLiveHintsVoiceCommand(_ text: String) async -> Bool {
        guard let command = LiveHintsVoiceCommand.parse(text) else { return false }
        let line: String
        switch command {
        case .start:
            guard activeLiveHints == nil else {
                line = LiveHintsCopy.alreadyRunning
                break
            }
            switch startLiveHints(choices: liveHintsDefaultChoices()) {
            case .started: line = LiveHintsCopy.started
            case .alreadyRunning: line = LiveHintsCopy.alreadyRunning
            case .needsFirstRun: line = LiveHintsCopy.needsPhone
            case .disabled: line = LiveHintsCopy.switchedOff
            case .allowanceSpent: line = LiveHintsCopy.noTimeLeft
            }
        case .stop:
            guard activeLiveHints != nil else { return false }
            stopActiveLiveHints()
            line = LiveHintsCopy.stopped
        case .show:
            guard let service = activeLiveHints else { return false }
            // Back on the lens; with no lens to show it on, said again in the ear.
            if service.showHintsAgain() || (service.hasHint && !liveHintsDisplayConnected) {
                if !liveHintsDisplayConnected { service.repeatLastHint() }
                PrivacyLog.speech(.liveHints, .controlHandled, detail: PrivacyToken("voice.show"))
                return true
            }
            line = LiveHintsCopy.noHintToShow
        case .addKeyword(let keyword):
            guard let service = activeLiveHints else { return false }
            service.addKeyword(keyword)
            line = service.mode == .keyword ? LiveHintsCopy.keywordAdded(keyword)
                                            : LiveHintsCopy.keywordListened(keyword)
        }
        PrivacyLog.speech(.liveHints, .controlHandled, detail: PrivacyToken("voice.\(Self.voiceToken(command))"))
        await speechService.speak(line, source: .acknowledgement)
        return true
    }

    nonisolated static func voiceToken(_ command: LiveHintsVoiceCommand) -> String {
        switch command {
        case .start: return "start"
        case .stop: return "stop"
        case .show: return "show"
        case .addKeyword: return "addKeyword"
        }
    }

    // MARK: - The background stop

    /// Stop the session once the app has been away as long as captions are allowed to be
    /// (`LiveHintsPresenceRule`, the captions' own rule). The demo stops the same way.
    func applyLiveHintsPresence(_ mode: EngagementMode) {
        guard LiveHintsPresenceRule.shouldStop(mode: mode, sessionRunning: liveHintsSessionActive) else { return }
        if liveHintsRunning { liveHints.stop(reason: .background) }
        if liveHintsDemoRunning { liveHintsDemo.stop(reason: .background) }
    }

    // MARK: - The talk note (§9)

    /// At stop, with the switch on: the meeting-summary prompt over the session's captions, kept as
    /// a conversation note. Never in Medical Compliance mode or a Private Conversation; checked
    /// before the model call and again before the write.
    func writeLiveHintsTalkNote(_ ending: LiveHintsService.Ending) {
        let skip = LiveHintsTalkNote.skip(switchOn: ending.settings.talkNote, medicalCompliance: Config.hipaaMode,
                                          privateConversation: PrivateConversationGate.skips(.conversationNote),
                                          lineCount: ending.lines.count)
        if let skip {
            if skip != .switchOff {
                PrivacyLog.speech(.liveHints, .talkNoteSkipped, detail: PrivacyToken(skip.rawValue))
            }
            return
        }
        guard let model = Config.activeModel else {
            PrivacyLog.speech(.liveHints, .talkNoteSkipped, detail: PrivacyToken("noModel"))
            return
        }
        let tier: ConversationDigest.Tier = LLMServiceHintModel.runsOnPhone(model.llmProvider) ? .onDevice : .cloud
        let llm = llmService
        let lines = ending.lines
        Task { @MainActor [weak self] in
            let raw: String
            do {
                raw = try await TurnRecorder.offTurn {
                    try await llm.completeStateless(LiveHintsTalkNote.user(lines: lines), system: LiveHintsTalkNote.system)
                }
            } catch {
                PrivacyLog.speech(.liveHints, .talkNoteSkipped, detail: PrivacyToken("modelFailed"),
                                  error: SafeErrorSummary(error))
                return
            }
            guard let self else { return }
            // Either may have begun while the model answered.
            if let late = LiveHintsTalkNote.skip(switchOn: true, medicalCompliance: Config.hipaaMode,
                                                 privateConversation: PrivateConversationGate.skips(.conversationNote),
                                                 lineCount: lines.count) {
                PrivacyLog.speech(.liveHints, .talkNoteSkipped, detail: PrivacyToken(late.rawValue))
                return
            }
            guard let note = LiveHintsTalkNote.accept(raw, lines: lines) else {
                PrivacyLog.speech(.liveHints, .talkNoteSkipped, detail: PrivacyToken("notKept"))
                return
            }
            let saved = self.conversationStore.saveTalkNote(
                title: note.headline, text: LiveHintsTalkNote.text(headline: note.headline, points: note.points),
                points: note.points, endedAt: ending.endedAt, tier: tier)
            if saved.outcome == .saved {
                PrivacyLog.speech(.liveHints, .talkNoteSaved, count: note.points.count)
            } else {
                PrivacyLog.speech(.liveHints, .talkNoteSkipped, detail: PrivacyToken(saved.outcome.rawValue))
            }
        }
    }

    // MARK: - Opening a hint's passage on the phone

    /// The passage a hint stands on, for the session screen's press: the chunk the search returned
    /// (`documentId`, `chunkIndex`), or the sample document's for the demo.
    func liveHintsPassageText(documentId: String, chunkIndex: Int) -> String? {
        if let demo = LiveHintsDemo.passageText(documentId: documentId, chunkIndex: chunkIndex) { return demo }
        return documentStore.passages(after: chunkIndex - 1, documentId: documentId, limit: 1)
            .first { $0.chunkIndex == chunkIndex }?.text
    }

    /// Whether the phone's output is its own speaker: a media button can only come from a headset
    /// or the glasses, so a session holds the taps only with one connected.
    var liveHintsHeadsetConnected: Bool {
        !HintOutputRoute.isPhoneSpeaker(outputs: AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType))
    }
}

/// Listens for the Darwin notification the Live Activity's live-hints buttons post when they record
/// a press (`PendingLiveHintsCommand`).
final class LiveHintsCommandObserver {
    static let shared = LiveHintsCommandObserver()
    private var started = false
    private var onCommand: (() -> Void)?

    func start(onCommand: @escaping () -> Void) {
        self.onCommand = onCommand
        guard !started else { return }
        started = true
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<LiveHintsCommandObserver>.fromOpaque(observer).takeUnretainedValue().onCommand?()
            },
            PendingLiveHintsCommand.notificationName as CFString,
            nil,
            .deliverImmediately
        )
    }
}
