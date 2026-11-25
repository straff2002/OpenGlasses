import Combine
import Foundation
import UIKit

// Plan NH — the daily allowance's seams on the app. `AllowanceService` decides; this connects it to
// the turn path, the live sessions, the speech engine and the subscription sheet.

extension AppState {

    /// Called once from `init`.
    func wireAllowance() {
        let allowance = AllowanceService.shared
        llmService.allowance = allowance
        geminiLiveSession.allowance = allowance
        openAIRealtimeSession.allowance = allowance
        LiveAllowanceGate.refusal = { [weak allowance] in allowance?.liveConnectRefusal() }
        // A purchase, a restore, an expiry or an organisation profile changes who is exempt.
        allowance.refresh(whenever: StoreKitService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher())
        allowance.refresh(whenever: NotificationCenter.default.publisher(for: .orgPolicyDidChange)
            .map { _ in () }.eraseToAnyPublisher())
        allowance.refresh(whenever: NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .map { _ in () }.eraseToAnyPublisher())
        allowance.refresh(whenever: NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)
            .map { _ in () }.eraseToAnyPublisher())
        let speech = speechService
        allowance.observeSpeech(speech.$isSpeaking.eraseToAnyPublisher()) { [weak speech] in
            speech?.isSpeaking ?? false
        }
        // A refusal opens the subscription sheet on a phone in front of someone; anywhere else —
        // Siri, the Watch, CarPlay, the widget, a Live Activity, a locked phone — the line has been
        // said or returned already and a notification opens the sheet later. Nothing waits for it.
        allowance.onRefused = { [weak self] _ in
            guard let self else { return }
            if UIApplication.shared.applicationState == .active {
                if !self.subscriptionSheetPresented { self.subscriptionSheetPresented = true }
            } else {
                AllowanceNotification.post()
            }
        }
    }
}
