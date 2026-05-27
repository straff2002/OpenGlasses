import CarPlay
import UIKit

/// Manages the CarPlay interface for OpenGlasses.
///
/// Voice-based conversational app — primary modality is voice.
/// Templates: Tab Bar → Voice Control, Modes (List), Conversations (List), Playbooks (List)
/// Max template depth: 3 (including root tab bar).
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    var interfaceController: CPInterfaceController?
    private var voiceControlTemplate: CPVoiceControlTemplate?

    /// Track whether voice input is active so we know when to hold the audio session.
    private(set) var isVoiceActive = false

    // MARK: - Scene Lifecycle

    @objc func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        print("🚗 CarPlay connected")

        Task { @MainActor in
            AppStateProvider.shared?.carPlayConnected = true
        }

        let tabBar = buildTabBar()
        interfaceController.setRootTemplate(tabBar, animated: true, completion: nil)
    }

    // MARK: - Tab Bar

    private func buildTabBar() -> CPTabBarTemplate {
        let voiceTab = buildVoiceTab()
        let modesTab = buildModesTab()
        let conversationsTab = buildConversationsTab()
        let playbooksTab = buildPlaybooksTab()

        let tabBar = CPTabBarTemplate(templates: [voiceTab, modesTab, conversationsTab, playbooksTab])
        return tabBar
    }

    // MARK: - Voice Tab (Primary)

    private func buildVoiceTab() -> CPListTemplate {
        let listenItem = CPListItem(
            text: "Start Listening",
            detailText: "Tap to activate voice assistant",
            image: UIImage(systemName: "mic.fill")
        )
        listenItem.handler = { [weak self] _, completion in
            self?.startVoice()
            completion()
        }

        let stopItem = CPListItem(
            text: "Stop Listening",
            detailText: "End the current voice session",
            image: UIImage(systemName: "mic.slash.fill")
        )
        stopItem.handler = { [weak self] _, completion in
            self?.stopVoice()
            completion()
        }

        let section = CPListSection(items: [listenItem, stopItem])
        let template = CPListTemplate(title: "Voice", sections: [section])
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

        let section = CPListSection(items: items, header: "Personas", sectionIndexTitle: nil)
        let template = CPListTemplate(title: "Modes", sections: [section])
        template.tabImage = UIImage(systemName: "person.2.fill")
        return template
    }

    // MARK: - Conversations Tab

    private func buildConversationsTab() -> CPListTemplate {
        var items: [CPListItem] = []

        let newItem = CPListItem(
            text: "New Conversation",
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
        let template = CPListTemplate(title: "Conversations", sections: [section])
        template.tabImage = UIImage(systemName: "bubble.left.and.bubble.right.fill")
        return template
    }

    // MARK: - Playbooks Tab

    private func buildPlaybooksTab() -> CPListTemplate {
        let section = CPListSection(items: [])
        let template = CPListTemplate(title: "Playbooks", sections: [section])
        template.tabImage = UIImage(systemName: "list.clipboard.fill")
        return template
    }

    // MARK: - Voice Control

    private func startVoice() {
        guard !isVoiceActive else { return }
        isVoiceActive = true
        print("🚗 CarPlay: Starting voice input")

        let states: [CPVoiceControlState] = [
            CPVoiceControlState(
                identifier: "listening",
                titleVariants: ["Listening..."],
                image: UIImage(systemName: "ear.fill"),
                repeats: true
            ),
            CPVoiceControlState(
                identifier: "processing",
                titleVariants: ["Thinking..."],
                image: UIImage(systemName: "brain"),
                repeats: true
            ),
            CPVoiceControlState(
                identifier: "speaking",
                titleVariants: ["Speaking..."],
                image: UIImage(systemName: "speaker.wave.2.fill"),
                repeats: true
            )
        ]

        let template = CPVoiceControlTemplate(voiceControlStates: states)
        voiceControlTemplate = template

        interfaceController?.presentTemplate(template, animated: true, completion: nil)

        Task { @MainActor in
            guard let appState = AppStateProvider.shared else { return }
            appState.wakeWordService.carPlayMode = true
            appState.wakeWordService.reconfigureAudioSession()
            appState.wakeWordService.stopListening()
            try? await Task.sleep(nanoseconds: 100_000_000)
            await appState.handleWakeWordDetected()
        }
    }

    private func stopVoice() {
        guard isVoiceActive else { return }
        isVoiceActive = false
        print("🚗 CarPlay: Stopping voice input")

        voiceControlTemplate = nil
        interfaceController?.dismissTemplate(animated: true, completion: nil)

        Task { @MainActor in
            guard let appState = AppStateProvider.shared else { return }
            appState.speechService.stopSpeaking()
            appState.wakeWordService.deactivateAudioSession()
            appState.isListening = false
            appState.inConversation = false
        }
    }

    /// Update the voice control template state (called by AppState during conversation flow).
    func updateVoiceState(_ identifier: String) {
        voiceControlTemplate?.activateVoiceControlState(withIdentifier: identifier)
    }

    // MARK: - Actions

    private func switchPersona(_ persona: Persona) {
        print("🚗 CarPlay: Switching to persona '\(persona.name)'")
        Task { @MainActor in
            guard let appState = AppStateProvider.shared else { return }
            appState.activePersona = persona
            Config.setActiveModelId(persona.modelId)
            Config.setActivePresetId(persona.presetId)
            appState.llmService.refreshActiveModel()
        }
        refreshModesTab()
    }

    private func startNewConversation() {
        print("🚗 CarPlay: Starting new conversation")
        Task { @MainActor in
            AppStateProvider.shared?.conversationStore.endThread()
        }
        startVoice()
    }

    private func resumeConversation(threadId: String) {
        print("🚗 CarPlay: Resuming conversation \(threadId)")
        Task { @MainActor in
            guard let appState = AppStateProvider.shared else { return }
            appState.conversationStore.endThread()
            appState.conversationStore.activeThreadId = threadId
        }
        startVoice()
    }

    private func activatePlaybook(_ playbook: Playbook) {
        print("🚗 CarPlay: Activating playbook '\(playbook.name)'")
        Task { @MainActor in
            guard let appState = AppStateProvider.shared else { return }
            let result = appState.playbookStore.startPlaybook(playbook.id)
            print("🚗 CarPlay: \(result)")
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
        Task { @MainActor in
            guard let store = AppStateProvider.shared?.conversationStore else { return }
            let threads = store.threads.sorted { $0.updatedAt > $1.updatedAt }.prefix(11)

            var items: [CPListItem] = []

            let newItem = CPListItem(
                text: "New Conversation",
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
            let template = CPListTemplate(title: "Conversations", sections: [section])
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
        Task { @MainActor in
            guard let store = AppStateProvider.shared?.playbookStore else { return }
            let playbooks = store.playbooks
            let activeId = store.activeSession?.playbookId

            let items: [CPListItem] = playbooks.map { playbook in
                let isActive = activeId == playbook.id
                let item = CPListItem(
                    text: playbook.name,
                    detailText: isActive ? "In Progress" : "\(playbook.steps.count) steps",
                    image: UIImage(systemName: playbook.icon)
                )
                item.handler = { [weak self] _, completion in
                    self?.activatePlaybook(playbook)
                    completion()
                }
                return item
            }

            let section = CPListSection(items: items)
            let template = CPListTemplate(title: "Playbooks", sections: [section])
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
        print("🚗 CarPlay disconnected")
        Task { @MainActor in
            AppStateProvider.shared?.carPlayConnected = false
        }
        stopVoice()
        self.interfaceController = nil
    }
}
