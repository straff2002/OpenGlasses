import Foundation
import UIKit
import UserNotifications

/// The app side of the offline handoff (Plan GE P1/P2): the controller's seams, and the two turn
/// shapes that need no model — a deterministic tool answer and a held question. Every decision
/// lives in `ConnectivityHandoffController` and the pure types beside it; this file reads app state
/// and calls entry points that already exist.
extension AppState {

    func makeConnectivityHandoff() -> ConnectivityHandoffController {
        ConnectivityHandoffController(
            initiallyOnline: reachability.isOnline,
            seams: .init(
                isEnabled: { OfflineHandoffAvailability.isEffectivelyEnabled() },
                isAppActive: { UIApplication.shared.applicationState != .background },
                availableBrains: { OfflineHandoffAvailability.current() },
                probe: {
                    // The cloud model the conversation returns to — never the on-device one a phone
                    // turn temporarily made active, since turns restore it before the tick runs.
                    await ConnectivityProbe.probe(ConnectivityProbe.probeURL(for: Config.activeModel))
                },
                queuedItems: { [weak self] in self?.offlineQueue.pendingCount ?? 0 },
                isBusy: { [weak self] in
                    guard let self else { return false }
                    return self.isProcessing || self.speechService.isSpeaking
                },
                liveSessionActive: { [weak self] in
                    guard let self else { return false }
                    return self.geminiLiveSession.isActive || self.openAIRealtimeSession.isActive
                },
                speak: { [weak self] line in await self?.speechService.speak(line) },
                showStatus: { [weak self] text in
                    self?.glassesDisplay.showNotification(title: nil, body: text, icon: .info, duration: 5)
                },
                notify: { title, body in
                    let content = UNMutableNotificationContent()
                    content.title = title
                    content.body = body
                    UNUserNotificationCenter.current().add(
                        UNNotificationRequest(identifier: "offline-held-question-\(UUID().uuidString)",
                                              content: content, trigger: nil))
                },
                conversationId: { [weak self] in
                    guard let self else { return "none" }
                    return self.conversationStore.activeThreadId
                        ?? "generation-\(self.conversationReset.currentGeneration)"
                },
                onReturnToCloud: { [weak self] context in
                    await self?.carryOutReturnToCloud(context)
                }))
    }

    /// Back on the cloud: tell the model which answers came from the phone (one line), then answer
    /// the held question or say, once, that it was too old.
    private func carryOutReturnToCloud(_ context: ConnectivityHandoffController.ReturnContext) async {
        // Plan GE P3: a live session handed to the phone starts again, opening with the turns the
        // phone answered (and a still-fresh held question as the last thing the wearer said).
        let pending = connectivityHandoff.pendingLiveResume
        connectivityHandoff.pendingLiveResume = nil
        if let mode = LiveModeHandoffPlanner.modeToResume(
            pending: pending, currentMode: currentMode,
            liveSessionActive: geminiLiveSession.isActive || openAIRealtimeSession.isActive) {
            var turns: [(role: String, content: String)] = context.answeredOnPhone.flatMap {
                [(role: "user", content: $0.question), (role: "assistant", content: $0.answer)]
            }
            if case .fresh(let question) = context.heldQuestion {
                turns.append((role: "user", content: question))
            }
            let seed = LiveModeHandoffPlanner.resumeContext(phoneTurns: turns)
            switch mode {
            case .geminiLive: geminiLiveSession.pendingResumeContext = seed
            case .openaiRealtime: openAIRealtimeSession.pendingResumeContext = seed
            case .direct: break
            }
            PrivacyLog.model(.offlineHandoff, count: turns.count, detail: PrivacyToken("liveResume"))
            await requestLiveSession(mode, source: .offlineReturn)
            return
        }

        if let note = context.inboundNote {
            llmService.injectSystemMessage(note)
        }
        switch context.heldQuestion {
        case .none:
            break
        case .expired:
            await speechService.speak(HandoffAnnouncer.heldExpiredLine)
        case .fresh(let question):
            // The question is already in the saved conversation from when it was asked; the replay
            // only adds the answer.
            await sendTextMessage(question, recordUserTurn: false)
        }
    }

    /// A live session gave up reconnecting. Returns true when the conversation was handed to the
    /// phone (the caller then claims the lifecycle signal), false to end the session as before.
    func handOffLostLiveSession(_ mode: AppMode) -> Bool {
        let decision = LiveModeHandoffPlanner.decideOnLoss(
            mode: mode,
            handoffEnabled: connectivityHandoff.isEnabled,
            route: connectivityHandoff.route,
            pathSatisfied: reachability.isOnline)
        guard case .continueOnPhone(let resume) = decision else { return false }
        PrivacyLog.model(.offlineHandoff, detail: PrivacyToken("liveToPhone"))
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.connectivityHandoff.liveSessionHandedToPhone(resume: resume)
            await self.performModeSwitch(to: .direct)
        }
        return true
    }

    /// Serve a phone turn that needs no model: run the deterministic tool, or hold the question.
    /// Returns the reply to speak and record, or nil when the tool produced nothing — the caller
    /// then falls back to ``ConnectivityHandoffController/modelPlan()``.
    func phoneReplyWithoutModel(_ plan: ConnectivityHandoffController.TurnPlan, query: String) async -> String? {
        switch plan {
        case .deterministic(let route):
            let outcome = await nativeToolRouter.execute(.root(
                name: route.toolName, arguments: ToolArguments(route.toolArguments), origin: .user))
            guard case .completed(let result) = outcome else {
                PrivacyLog.model(.offlineTurn, detail: PrivacyToken("deterministicFellBack"))
                return nil
            }
            // Follow-up continuity, as for a tier-0 answer: the model never saw this exchange.
            llmService.recordExternalExchange(user: query, assistant: result)
            connectivityHandoff.recordOnDeviceAnswer(question: query, answer: result)
            PrivacyLog.model(.offlineTurn, detail: PrivacyToken("deterministic"))
            return result
        case .hold:
            PrivacyLog.model(.offlineTurn, detail: PrivacyToken("held"))
            return connectivityHandoff.hold(query)
        case .cloud, .phoneModel:
            return nil
        }
    }
}

/// What the phone can think with, read from the app's settings and disk (Plan GE).
@MainActor
enum OfflineHandoffAvailability {

    static func current() -> OfflineBrainSelector.Available {
        let saved = Config.savedModels
        var localId: String?
        var isGGUF = false
        if let local = saved.first(where: { $0.llmProvider == .local }) {
            let repository = LocalModelRepository()
            let selected = LocalModelSelection.store(repository: repository).selectedID()
                ?? LocalModelID(local.model)
            if repository.isInstalled(selected)
                || LocalLLMService.downloadedModelIdsOnDisk().contains(selected.rawValue) {
                localId = local.id
                isGGUF = LocalModelSelection.runtime(for: selected, repository: repository) == .llamaCpp
            }
        }
        let apple = FirstRunDefaults.appleIntelligenceAvailable
            ? saved.first(where: { $0.llmProvider == .appleOnDevice })?.id
            : nil
        return .init(localModelConfigId: localId, localModelIsGGUF: isGGUF,
                     appleOnDeviceConfigId: apple,
                     appleOnDeviceServesBackground: OfflineBrainSelector.appleOnDeviceVerifiedInBackground,
                     cpuTierAllowed: OfflineBrainSelector.cpuTierVerifiedOnDevice)
    }

    static func isEffectivelyEnabled() -> Bool {
        ConnectivityHandoffController.isEffectivelyEnabled(
            setting: Config.offlineHandoffEnabled,
            available: current(),
            medicalLocalOnly: MedicalLLMRoutingPolicy.isEnforced(hipaaMode: Config.hipaaMode,
                                                                 localOnly: Config.hipaaLocalOnly))
    }
}
