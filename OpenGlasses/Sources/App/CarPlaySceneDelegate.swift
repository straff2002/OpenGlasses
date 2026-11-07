import CarPlay
import Combine
import UIKit

/// Manages the CarPlay interface for OpenGlasses.
///
/// Voice-based conversational app — primary modality is voice.
/// Templates: Tab Bar (Voice, Modes, Conversations, Playbooks, Jobs — all lists) as the root, with
/// the voice control template presented over it: on connect in its ready state (iOS 26.4+, where
/// it carries Talk / Stop / End and a Menu button back to the tabs), or from a row that talks.
/// Max template depth: 3 including the root — tab bar, a tab's list, then one pushed page or the
/// voice template (`CarPlayVoiceScreen.depth`).
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    var interfaceController: CPInterfaceController?
    private var voiceControlTemplate: CPVoiceControlTemplate?

    /// The connected scene, so the app can refresh the Jobs list when the job moves (Plan FO P3a).
    /// Weak: the scene owns the delegate, and a disconnected car must not keep the app holding one.
    private(set) static weak var current: CarPlaySceneDelegate?

    /// The car's scene, for handing directions to a maps app on the car screen (Plan FO P3c).
    /// Weak for the same reason `current` is.
    private weak var carScene: CPTemplateApplicationScene?

    /// What the voice screen is doing, and every decision about it (`CarPlayVoiceScreen`).
    /// Main actor only.
    private var voiceScreen = CarPlayVoiceScreen(hasButtons: CarPlaySceneDelegate.voiceTemplateHasButtons)

    /// Whether the voice template is up.
    var isVoiceActive: Bool { voiceScreen.isPresented }

    /// The CarPlay audio set-up and conversation start a Start Listening began — cancelled by End
    /// or a disconnect, so a conversation is never opened after the driver ended it.
    private var voiceStartTask: Task<Void, Never>?

    /// Follows the conversation while the voice template is up.
    private var conversationObserver: AnyCancellable?

    // MARK: - Scene Lifecycle

    @objc func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.delegate = self
        self.carScene = templateApplicationScene
        Self.current = self
        PrivacyLog.device(.carPlay, .connected)

        Task { @MainActor in
            AppStateProvider.shared?.carPlayConnected = true
        }

        let tabBar = buildTabBar()
        // The voice template cannot be the root (the SDK only presents it), so the tab bar is, and
        // the ready screen goes over it once it is up — voice is what the driver sees first.
        interfaceController.setRootTemplate(tabBar, animated: true) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, let appState = AppStateProvider.shared else { return }
                self.showReadyScreenOnConnect(appState)
            }
        }
        // The Jobs list is built empty with the bar and filled from the main actor, like every
        // other data-bearing tab here.
        refreshJobsTab()
        // The brief on connect (Plan FO P3c) — off unless the technician switched it on, because
        // a car that starts talking the moment it is turned on is a nag otherwise.
        Task { @MainActor in
            guard Config.fieldAssistActive, Config.briefOnCarPlayConnect,
                  let appState = AppStateProvider.shared,
                  let next = appState.upcomingJobs.next else { return }
            await appState.guidedJobFlow.briefAloud(jobId: next.id)
        }
    }

    // MARK: - Tab Bar

    private func buildTabBar() -> CPTabBarTemplate {
        let voiceTab = buildVoiceTab()
        let modesTab = buildModesTab()
        let conversationsTab = buildConversationsTab()
        let playbooksTab = buildPlaybooksTab()
        let jobsTab = buildJobsTab()

        let tabBar = CPTabBarTemplate(templates: [voiceTab, modesTab, conversationsTab,
                                                  playbooksTab, jobsTab])
        return tabBar
    }

    /// Where the Jobs list sits in the bar. Last, so the four tabs that shipped keep their order
    /// and `refreshConversationsTab`/`refreshPlaybooksTab`'s index arithmetic is untouched.
    private static let jobsTabIndex = 4

    // MARK: - Voice Tab (Primary)

    /// Three rows. `CPVoiceControlTemplate` carries no buttons of its own, so Stop and End live
    /// here: Stop cuts the reply off and keeps the conversation listening, End hangs it up.
    private func buildVoiceTab() -> CPListTemplate {
        let listenItem = CPListItem(
            text: String(localized: "Start Listening"),
            detailText: String(localized: "Tap to activate voice assistant"),
            image: UIImage(systemName: "mic.fill")
        )
        listenItem.handler = { [weak self] _, completion in
            self?.startVoice()
            completion()
        }

        let stopItem = CPListItem(
            text: String(localized: "Stop Talking"),
            detailText: String(localized: "Cut the reply short and keep listening"),
            image: UIImage(systemName: "speaker.slash.fill")
        )
        stopItem.handler = { [weak self] _, completion in
            self?.stopTalking()
            completion()
        }

        let endItem = CPListItem(
            text: String(localized: "End Conversation"),
            detailText: String(localized: "Stop listening and end the conversation"),
            image: UIImage(systemName: "mic.slash.fill")
        )
        endItem.handler = { [weak self] _, completion in
            self?.endVoice()
            completion()
        }

        let section = CPListSection(items: [listenItem, stopItem, endItem])
        let template = CPListTemplate(title: String(localized: "Voice"), sections: [section])
        template.tabImage = UIImage(systemName: "mic.fill")
        return template
    }

    // MARK: - Modes / Personas Tab

    private func buildModesTab() -> CPListTemplate {
        // Config.enabledPersonas reads from UserDefaults — safe off main actor
        let personas = Config.enabledPersonas
        let items: [CPListItem] = personas.map { persona in
            let item = CPListItem(
                text: persona.name,
                detailText: persona.wakePhrase,
                image: UIImage(systemName: "person.circle")
            )
            item.handler = { [weak self] _, completion in
                self?.switchPersona(persona)
                completion()
            }
            return item
        }

        let section = CPListSection(items: items, header: String(localized: "Personas"), sectionIndexTitle: nil)
        let template = CPListTemplate(title: String(localized: "Modes"), sections: [section])
        template.tabImage = UIImage(systemName: "person.2.fill")
        return template
    }

    // MARK: - Conversations Tab

    private func buildConversationsTab() -> CPListTemplate {
        var items: [CPListItem] = []

        let newItem = CPListItem(
            text: String(localized: "New Conversation"),
            detailText: nil,
            image: UIImage(systemName: "plus.circle.fill")
        )
        newItem.handler = { [weak self] _, completion in
            self?.startNewConversation()
            completion()
        }
        items.append(newItem)

        // Snapshot conversation data on the main actor
        Task { @MainActor in
            // Conversations will be populated on next refresh; initial load shows just "New Conversation"
        }

        let section = CPListSection(items: items)
        let template = CPListTemplate(title: String(localized: "Conversations"), sections: [section])
        template.tabImage = UIImage(systemName: "bubble.left.and.bubble.right.fill")
        return template
    }

    // MARK: - Playbooks Tab

    private func buildPlaybooksTab() -> CPListTemplate {
        let section = CPListSection(items: [])
        let template = CPListTemplate(title: String(localized: "Playbooks"), sections: [section])
        template.tabImage = UIImage(systemName: "list.clipboard.fill")
        return template
    }

    // MARK: - Jobs Tab (Plan FO P3a)

    /// The Jobs list, built on the main actor from `CarPlayJobsList`'s rows.
    ///
    /// **Read-only, and one glance per row.** The active job first — number and whether it is
    /// running — then finished jobs by number, date and outcome. The work record is never drawn
    /// here. Selecting the active job resumes its conversation through the P1 chokepoint;
    /// selecting a finished one reads its name aloud and does nothing else. The Debrief action
    /// §6 describes is P3b's, and the seam for it is `CarPlayJobsList.Selection`.
    private func buildJobsTab() -> CPListTemplate {
        let template = CPListTemplate(title: String(localized: "Jobs"), sections: [CPListSection(items: [])])
        template.tabImage = UIImage(systemName: "wrench.and.screwdriver.fill")
        return template
    }

    /// Rebuild the Jobs tab from current job state.
    func refreshJobsTab() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let appState = AppStateProvider.shared else { return }
            let sessions = FieldSessionService.shared
            let rows = CarPlayJobsList.rows(active: sessions.activeSession,
                                            history: sessions.history,
                                            boundThreadId: appState.guidedJobFlow.boundThreadId,
                                            debriefAvailable: Config.fieldAssistActive,
                                            stagedSends: appState.jobSends.stagedCount,
                                            upcoming: Config.fieldAssistActive ? appState.upcomingJobs.jobs : [])
            var items: [CPListItem] = rows.map { row in
                let item = CPListItem(
                    text: row.title,
                    detailText: row.detail,
                    image: UIImage(systemName: Self.symbol(for: row))
                )
                let selection = row.selection
                let spoken = row.spoken
                item.handler = { [weak self] _, completion in
                    self?.selectJob(selection, spoken: spoken)
                    completion()
                }
                return item
            }
            if items.isEmpty {
                items = [CPListItem(text: CarPlayJobsList.emptyMessage(
                    fieldAssistActive: Config.fieldAssistActive), detailText: nil)]
            }

            let template = CPListTemplate(title: String(localized: "Jobs"), sections: [CPListSection(items: items)])
            template.tabImage = UIImage(systemName: "wrench.and.screwdriver.fill")

            guard let tabBar = self.interfaceController?.rootTemplate as? CPTabBarTemplate else { return }
            var templates = tabBar.templates
            if templates.count > Self.jobsTabIndex {
                templates[Self.jobsTabIndex] = template
                tabBar.updateTemplates(templates)
            }
        }
    }

    /// Act on a row. Both cases speak; only the active job does anything else.
    private func selectJob(_ selection: CarPlayJobsList.Selection, spoken: String) {
        PrivacyLog.device(.carPlay, .commandHandled, command: PrivacyToken("selectJob"))
        Task { @MainActor in
            guard let appState = AppStateProvider.shared else { return }
            switch selection {
            case .resumeActiveJob(let threadId):
                guard let threadId else {
                    await appState.speechService.speak(spoken, source: .job)
                    return
                }
                // Through the chokepoint, never by assigning `activeThreadId` — resuming the job's
                // own thread is never a question, so this never asks one on a car screen.
                appState.guidedJobFlow.requestResume(threadId: threadId, confirmed: false)
                self.startVoice()
            case .speakPastJob:
                // Read-only: what a past row does with Field Assist off, where a debrief would
                // have nothing to write onto.
                await appState.speechService.speak(spoken, source: .job)
            case .debriefPastJob(let sessionId):
                // Through the flow, which names the job out loud and binds the turns to *that*
                // job's conversation. Nothing is written until the technician says "save".
                let started = await appState.guidedJobFlow.startDebrief(jobId: sessionId)
                if started { self.startVoice() }
                else { await appState.speechService.speak(spoken, source: .job) }
            case .readSendQueue:
                await appState.speechService.speak(appState.jobSends.spokenQueue(), source: .job)
            case .openUpcomingJob(let id):
                self.pushUpcomingJob(id: id, spoken: spoken)
            }
        }
    }

    private static func symbol(for row: CarPlayJobsList.Row) -> String {
        if row.isActiveJob { return "wrench.and.screwdriver.fill" }
        if case .openUpcomingJob = row.selection { return "calendar" }
        return "checkmark.seal"
    }

    /// A job ahead's page on the car screen: two rows, Brief and Directions (Plan FO P3c). Depth
    /// three with the tab bar and the list — CarPlay's limit, and the reason there is no fourth.
    @MainActor
    private func pushUpcomingJob(id: String, spoken: String) {
        guard let appState = AppStateProvider.shared,
              let job = appState.upcomingJobs.job(id: id) else { return }
        let items: [CPListItem] = CarPlayJobsList.upcomingActions(for: job).map { action in
            let item = CPListItem(text: action.title, detailText: nil,
                                  image: UIImage(systemName: action.symbol))
            item.handler = { [weak self] _, completion in
                self?.performUpcoming(action)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: job.title, sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
        Task { await appState.speechService.speak(spoken, source: .job) }
    }

    private func performUpcoming(_ action: CarPlayJobsList.UpcomingAction) {
        PrivacyLog.device(.carPlay, .commandHandled, command: PrivacyToken("upcomingJob"))
        Task { @MainActor in
            guard let appState = AppStateProvider.shared else { return }
            switch action {
            case .brief(let jobId):
                await appState.guidedJobFlow.briefAloud(jobId: jobId)
            case .directions(let jobId):
                guard let destination = appState.upcomingJobs.job(id: jobId)?.destination,
                      let handoff = MapsLauncher.plan(destination: destination) else { return }
                MapsLauncher.open(handoff)
                // Only a fallback is worth saying: the maps app appearing is the confirmation.
                if handoff.unavailable != nil { await appState.speechService.speak(handoff.spoken, source: .job) }
            }
        }
    }

    // MARK: - Directions (Plan FO P3c)

    /// Hand a maps URL to the car screen through the CarPlay scene's own open path, so the maps
    /// app takes the display and the brief can keep speaking. False when no car scene is
    /// connected, and the caller opens it on the phone instead.
    @discardableResult
    func openOnCarScreen(_ url: URL) -> Bool {
        guard let carScene else { return false }
        carScene.open(url, options: nil, completionHandler: nil)
        return true
    }

    // MARK: - Voice Control

    // The decisions live in `CarPlayVoiceScreen`; everything below reads a snapshot, hands it over
    // and carries out what comes back. All of it runs on the main actor — the CarPlay handlers
    // arrive on the main thread, and every `Task` here is `@MainActor`, so taps are applied in the
    // order they were made.

    /// Whether the voice template can carry buttons (iOS 26.4). Without them there is no ready
    /// screen: nothing on it could be tapped, and nothing would lead back to the tabs.
    private static var voiceTemplateHasButtons: Bool {
        if #available(iOS 26.4, *) { return true }
        return false
    }

    /// The conversation as the voice screen sees it.
    @MainActor
    private static func conversation(_ appState: AppState) -> CarPlayVoiceScreen.Conversation {
        CarPlayVoiceScreen.Conversation(inConversation: appState.inConversation,
                                        isListening: appState.isListening,
                                        isProcessing: appState.isProcessing,
                                        isSpeaking: appState.speechService.isSpeaking)
    }

    /// Voice first: the ready screen on connect, over the tab bar. It opens no microphone and says
    /// nothing — only Talk does. Without template buttons the car opens on the tab bar as before.
    @MainActor
    private func showReadyScreenOnConnect(_ appState: AppState) {
        guard voiceScreen.connected() else { return }
        presentVoiceTemplate(showing: .ready, appState: appState)
    }

    private func startVoice() {
        Task { @MainActor [weak self] in
            guard let self, let appState = AppStateProvider.shared else { return }
            self.startVoice(appState)
        }
    }

    @MainActor
    private func startVoice(_ appState: AppState) {
        switch voiceScreen.start(Self.conversation(appState)) {
        case .nothing:
            return
        case .show(let state):
            show(state)
        case .presentOverRunningConversation(let state):
            PrivacyLog.device(.carPlay, .commandHandled, command: PrivacyToken("showVoice"))
            presentVoiceTemplate(showing: state, appState: appState)
        case .presentAndStartConversation:
            PrivacyLog.device(.carPlay, .commandHandled, command: PrivacyToken("startVoice"))
            presentVoiceTemplate(showing: .listening, appState: appState)
            beginConversation(appState)
        case .startConversation:
            PrivacyLog.device(.carPlay, .commandHandled, command: PrivacyToken("startVoice"))
            show(.listening)
            beginConversation(appState)
        }
    }

    /// The CarPlay audio set-up, then the wake word's own conversation start — the only place the
    /// car screen opens the microphone, and only after a tap.
    @MainActor
    private func beginConversation(_ appState: AppState) {
        voiceStartTask?.cancel()
        voiceStartTask = Task { @MainActor [weak self] in
            // Cancelled before it ran (End, or the car going): leave the audio mode alone.
            guard !Task.isCancelled else { return }
            appState.wakeWordService.carPlayMode = true
            await appState.wakeWordService.reconfigureAudioSession()
            guard !Task.isCancelled else { return }
            appState.wakeWordService.stopListening()
            try? await Task.sleep(nanoseconds: 100_000_000)
            // Ended (or the car went) while the audio was being set up: open nothing.
            guard !Task.isCancelled else { return }
            await appState.handleWakeWordDetected()
            guard let self, !Task.isCancelled else { return }
            self.voiceStartTask = nil
            self.apply(self.voiceScreen.startFinished(Self.conversation(appState)), appState: appState)
        }
    }

    /// Present the voice template on `state` and follow the conversation while it is up.
    @MainActor
    private func presentVoiceTemplate(showing state: CarPlayVoiceScreen.VoiceState, appState: AppState) {
        guard let interfaceController else { return }
        // Depth: tab bar, its list, and this template make three — never over a pushed page.
        if CarPlayVoiceScreen.mustPopToRootBeforePresenting(pushed: max(0, interfaceController.templates.count - 1)) {
            interfaceController.popToRootTemplate(animated: false, completion: nil)
        }
        let states = CarPlayVoiceScreen.states(hasButtons: voiceScreen.hasButtons)
        let template = CPVoiceControlTemplate(voiceControlStates: states.map(voiceControlState))
        if #available(iOS 26.4, *) {
            // The way back to the tabs (Modes, Conversations, Playbooks, Jobs). The conversation,
            // if one is running, carries on; the Voice tab's rows still reach it.
            template.leadingNavigationBarButtons = [
                CPBarButton(title: String(localized: "Menu")) { [weak self] _ in self?.showTabs() }
            ]
        }
        voiceControlTemplate = template
        interfaceController.presentTemplate(template, animated: true) { [weak self, weak template] presented, _ in
            // A state can only be activated once the template is up; it opens on the first one.
            guard presented, let template, state != states.first,
                  self?.voiceControlTemplate === template else { return }
            template.activateVoiceControlState(withIdentifier: state.rawValue)
        }
        observeConversation(appState)
    }

    private func voiceControlState(_ state: CarPlayVoiceScreen.VoiceState) -> CPVoiceControlState {
        let voiceState = CPVoiceControlState(identifier: state.rawValue,
                                             titleVariants: [state.title],
                                             image: UIImage(systemName: state.symbol),
                                             repeats: true)
        if #available(iOS 26.4, *) {
            let limit = min(CarPlayVoiceScreen.maximumButtons, CPVoiceControlState.maximumActionButtonCount)
            voiceState.actionButtons = state.buttons.prefix(limit).map { button in
                let image = UIImage(systemName: button.symbol) ?? UIImage()
                let cpButton = CPButton(image: image) { [weak self] _ in self?.tapped(button) }
                cpButton.title = button.title
                return cpButton
            }
        }
        return voiceState
    }

    private func tapped(_ button: CarPlayVoiceScreen.Button) {
        switch button {
        case .talk: startVoice()
        case .stop: stopTalking()
        case .end: endVoice()
        }
    }

    /// The Menu button: down to the tab bar. The conversation is left as it is.
    private func showTabs() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            PrivacyLog.device(.carPlay, .commandHandled, command: PrivacyToken("showTabs"))
            self.voiceScreen.templateDisappeared()
            self.takeDownVoiceTemplate()
        }
    }

    /// Follow listening, thinking and speaking while the template is up. Every assignment to these
    /// publishes (an end of conversation reassigns `isListening` even when it is already false),
    /// and the snapshot is read a run-loop turn later, once the assignments that published it are
    /// all in — `@Published` announces before it stores, and `returnToWakeWord` clears
    /// `isListening` a line before `inConversation`.
    @MainActor
    private func observeConversation(_ appState: AppState) {
        conversationObserver = Publishers.Merge3(
            appState.$isListening.map { _ in () },
            appState.$isProcessing.map { _ in () },
            appState.speechService.$isSpeaking.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak appState] in
                MainActor.assumeIsolated {
                    guard let self, let appState else { return }
                    self.apply(self.voiceScreen.observe(Self.conversation(appState)), appState: appState)
                }
            }
    }

    @MainActor
    private func show(_ state: CarPlayVoiceScreen.VoiceState) {
        voiceControlTemplate?.activateVoiceControlState(withIdentifier: state.rawValue)
    }

    @MainActor
    private func apply(_ effect: CarPlayVoiceScreen.UpdateEffect, appState: AppState) {
        switch effect {
        case .none:
            return
        case .show(let state):
            show(state)
            return
        case .showReady:
            PrivacyLog.device(.carPlay, .commandHandled, command: PrivacyToken("voiceEnded"))
            show(.ready)
        case .dismiss:
            PrivacyLog.device(.carPlay, .commandHandled, command: PrivacyToken("voiceEnded"))
            takeDownVoiceTemplate()
        }
        scheduleReleaseFallback(appState)
    }

    /// An end with no `returnToWakeWord` behind it (a brief read out on the ready screen, listening
    /// switched off) still gives the audio back.
    @MainActor
    private func scheduleReleaseFallback(_ appState: AppState) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.voiceScreen.releaseFallbackDue(Self.conversation(appState)) else { return }
            await self.releaseAudio(appState)
        }
    }

    /// The app finished ending a conversation (`AppState.returnToWakeWord`, its re-arm included).
    /// Called on the main actor, at the very end of that path.
    @MainActor
    func appFinishedEndingConversation() {
        guard let appState = AppStateProvider.shared else { return }
        switch voiceScreen.appFinishedEnding(Self.conversation(appState)) {
        case .none:
            return
        case .release(let screen):
            switch screen {
            case .showReady: show(.ready)
            case .dismiss: takeDownVoiceTemplate()
            case .none, .show: break
            }
            Task { @MainActor [weak self] in await self?.releaseAudio(appState) }
        }
    }

    /// Give CarPlay's audio session back — voice is no longer in use.
    @MainActor
    private func releaseAudio(_ appState: AppState) async {
        PrivacyLog.device(.carPlay, .commandHandled, command: PrivacyToken("releaseAudio"))
        await appState.wakeWordService.deactivateAudioSession()
    }

    /// Dismiss the template this delegate presented, and stop following the conversation.
    @MainActor
    private func takeDownVoiceTemplate() {
        conversationObserver = nil
        guard voiceControlTemplate != nil else { return }
        // Cleared first, so the disappearance this dismissal causes is recognised as our own.
        voiceControlTemplate = nil
        interfaceController?.dismissTemplate(animated: true, completion: nil)
    }

    /// Stop: cut the reply off and keep the conversation going (`interruptSpeechAndListen`, the
    /// temple tap's interrupt). Outside a conversation it only silences what is being read out.
    private func stopTalking() {
        Task { @MainActor [weak self] in
            guard let self, let appState = AppStateProvider.shared else { return }
            switch self.voiceScreen.stop(Self.conversation(appState)) {
            case .nothing:
                return
            case .interruptAndListen:
                PrivacyLog.device(.carPlay, .commandHandled, command: PrivacyToken("stopTalking"))
                await appState.interruptSpeechAndListen()
            case .stopSpeaking:
                PrivacyLog.device(.carPlay, .commandHandled, command: PrivacyToken("stopTalking"))
                appState.speechService.stopSpeaking()
            }
        }
    }

    /// End: hang the conversation up (`hangUpConversation`, the temple tap's hang up — the in-flight
    /// turn, the recorder and the reply all go). The audio session is released when its end path
    /// finishes (`appFinishedEndingConversation`).
    private func endVoice() {
        Task { @MainActor [weak self] in
            guard let self, let appState = AppStateProvider.shared else { return }
            self.endVoice(appState)
        }
    }

    @MainActor
    private func endVoice(_ appState: AppState, carDisconnected: Bool = false) {
        let effect = carDisconnected ? voiceScreen.carDisconnected()
                                     : voiceScreen.end(Self.conversation(appState))
        voiceStartTask?.cancel()
        voiceStartTask = nil
        switch effect.screen {
        case .showReady: show(.ready)
        case .dismiss: takeDownVoiceTemplate()
        case .none, .show: break
        }
        if carDisconnected { takeDownVoiceTemplate() }
        if effect.restorePhoneAudio { appState.wakeWordService.carPlayMode = false }
        guard effect.hangUp else { return }
        PrivacyLog.device(.carPlay, .commandHandled, command: PrivacyToken("stopVoice"))
        Task { @MainActor in
            await appState.hangUpConversation()
            // `hangUpConversation` ends in `returnToWakeWord`, whose last step released the audio
            // through `appFinishedEndingConversation`; this is the backstop should that hook have
            // missed. After a disconnect nothing is owed: the phone's own end path handed it back.
            if self.voiceScreen.releaseFallbackDue(Self.conversation(appState)) {
                await self.releaseAudio(appState)
            }
        }
    }

    // MARK: - Actions

    private func switchPersona(_ persona: Persona) {
        // Persona names are omitted, not fingerprinted — a small wearer-visible set.
        PrivacyLog.device(.carPlay, .commandHandled, command: PrivacyToken("switchPersona"))
        Task { @MainActor in
            guard let appState = AppStateProvider.shared else { return }
            appState.activePersona = persona
            Config.setActiveModelId(persona.modelId)
            Config.setActivePresetId(persona.presetId)
            appState.llmService.refreshActiveModel()
        }
        refreshModesTab()
    }

    /// Plan FO P1: through the job chokepoint, not `endThread()` directly. A tap here used to end
    /// whatever thread was open with no idea a Field Assist job owned it — and a CarPlay tap that
    /// breaks the job's conversation is the exact failure the binding exists to prevent.
    ///
    /// There is nowhere in CarPlay to put the "keep this in the job?" question, so the answer here
    /// is the safe one: while a job owns the open conversation, New Conversation keeps it. The
    /// driver gets the job's thread, which is where the next thing they say belongs anyway.
    private func startNewConversation() {
        PrivacyLog.device(.carPlay, .commandHandled, command: PrivacyToken("newConversation"))
        Task { @MainActor in
            guard let appState = AppStateProvider.shared else { return }
            if appState.guidedJobFlow.leaveJobThreadQuestion() == nil {
                appState.guidedJobFlow.requestNewChat()
            }
        }
        startVoice()
    }

    /// The two-step resume, at last: this used to assign `activeThreadId` and stop, so the driver
    /// carried on a conversation the model had never been shown.
    private func resumeConversation(threadId: String) {
        PrivacyLog.device(.carPlay, .commandHandled, command: PrivacyToken("resumeThread"),
                          item: PrivateIdentifier(threadId))
        Task { @MainActor in
            guard let appState = AppStateProvider.shared else { return }
            // Same rule as above: no question surface here, so a job keeps its conversation.
            if appState.guidedJobFlow.leaveJobThreadQuestion(switchingTo: threadId) == nil {
                appState.activateConversationThread(threadId)
            }
        }
        startVoice()
    }

    private func activatePlaybook(_ playbook: Playbook) {
        // A playbook's name is the wearer's own procedure title.
        PrivacyLog.device(.carPlay, .commandHandled, command: PrivacyToken("activatePlaybook"))
        Task { @MainActor in
            guard let appState = AppStateProvider.shared else { return }
            // The store's return value is the playbook's first step, composed for the wearer —
            // the same class of string the tool router stopped printing in batch 2.
            _ = appState.playbookStore.startPlaybook(playbook.id)
        }
        startVoice()
    }

    // MARK: - Refresh (call from main actor)

    /// Rebuild the modes tab to reflect the active persona.
    func refreshModesTab() {
        guard let tabBar = interfaceController?.rootTemplate as? CPTabBarTemplate else { return }
        let updatedModes = buildModesTab()
        var templates = tabBar.templates
        if templates.count > 1 {
            templates[1] = updatedModes
            tabBar.updateTemplates(templates)
        }
    }

    /// Rebuild the conversations tab with current data from the main actor.
    func refreshConversationsTab() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let store = AppStateProvider.shared?.conversationStore else { return }
            let threads = store.threads.sorted { $0.updatedAt > $1.updatedAt }.prefix(11)

            var items: [CPListItem] = []

            let newItem = CPListItem(
                text: String(localized: "New Conversation"),
                detailText: nil,
                image: UIImage(systemName: "plus.circle.fill")
            )
            newItem.handler = { [weak self] _, completion in
                self?.startNewConversation()
                completion()
            }
            items.append(newItem)

            for thread in threads {
                let subtitle = Self.relativeDate(thread.updatedAt)
                let item = CPListItem(
                    text: thread.title,
                    detailText: subtitle,
                    image: UIImage(systemName: "bubble.left.fill")
                )
                let threadId = thread.id
                item.handler = { [weak self] _, completion in
                    self?.resumeConversation(threadId: threadId)
                    completion()
                }
                items.append(item)
            }

            let section = CPListSection(items: items)
            let template = CPListTemplate(title: String(localized: "Conversations"), sections: [section])
            template.tabImage = UIImage(systemName: "bubble.left.and.bubble.right.fill")

            guard let tabBar = self.interfaceController?.rootTemplate as? CPTabBarTemplate else { return }
            var templates = tabBar.templates
            if templates.count > 2 {
                templates[2] = template
                tabBar.updateTemplates(templates)
            }
        }
    }

    /// Rebuild the playbooks tab with current data from the main actor.
    func refreshPlaybooksTab() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let store = AppStateProvider.shared?.playbookStore else { return }
            let playbooks = store.reusablePlaybooks
            let activeId = store.activeSession?.playbookId

            let items: [CPListItem] = playbooks.map { playbook in
                let isActive = activeId == playbook.id
                let item = CPListItem(
                    text: playbook.name,
                    detailText: isActive ? String(localized: "In Progress") : String(localized: "\(playbook.steps.count) steps"),
                    image: UIImage(systemName: playbook.icon)
                )
                item.handler = { [weak self] _, completion in
                    self?.activatePlaybook(playbook)
                    completion()
                }
                return item
            }

            let section = CPListSection(items: items)
            let template = CPListTemplate(title: String(localized: "Playbooks"), sections: [section])
            template.tabImage = UIImage(systemName: "list.clipboard.fill")

            guard let tabBar = self.interfaceController?.rootTemplate as? CPTabBarTemplate else { return }
            var templates = tabBar.templates
            if templates.count > 3 {
                templates[3] = template
                tabBar.updateTemplates(templates)
            }
        }
    }

    // MARK: - Helpers

    private static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Disconnect Handling
// Moved to extension to silence "nearly matches didSelect" warning (Xcode SR-XXXXX).
extension CarPlaySceneDelegate {
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        PrivacyLog.device(.carPlay, .disconnected)
        if Self.current === self { Self.current = nil }
        Task { @MainActor in
            AppStateProvider.shared?.carPlayConnected = false
        }
        // Strongly held: the scene may let the delegate go once it has disconnected, and the
        // conversation must still be ended.
        Task { @MainActor in
            guard let appState = AppStateProvider.shared else { return }
            self.endVoice(appState, carDisconnected: true)
        }
        self.interfaceController = nil
        self.carScene = nil
    }
}

// MARK: - Template Dismissal
extension CarPlaySceneDelegate: CPInterfaceControllerDelegate {
    /// The system took the voice template down — not this delegate's own dismissal, which clears
    /// `voiceControlTemplate` first. Forget it, so the next Start Listening presents again rather
    /// than finding the screen "already up" and doing nothing.
    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        MainActor.assumeIsolated {
            guard let shown = voiceControlTemplate, aTemplate === shown else { return }
            voiceControlTemplate = nil
            conversationObserver = nil
            voiceScreen.templateDisappeared()
            PrivacyLog.device(.carPlay, .commandHandled, command: PrivacyToken("voiceDismissed"))
        }
    }
}
