import ActivityKit
import Foundation

/// Manages the glasses Live Activity on Lock Screen and Dynamic Island.
@MainActor
class LiveActivityManager {
    private var currentActivity: Activity<GlassesActivityAttributes>?

    /// Build quick action buttons from user's configured quick actions (top 4).
    private func quickActionButtons() -> [GlassesActivityAttributes.ContentState.QuickActionButton] {
        Array(Config.quickActions.prefix(4).map {
            GlassesActivityAttributes.ContentState.QuickActionButton(id: $0.id, label: $0.label, icon: $0.icon)
        })
    }

    /// Start a new Live Activity. No-op if one is already running or Live Activities are disabled.
    func start(glassesName: String = "OpenGlasses") {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("[LiveActivity] Activities not enabled")
            return
        }
        guard currentActivity == nil else {
            NSLog("[LiveActivity] Already running")
            return
        }

        let attributes = GlassesActivityAttributes(glassesName: glassesName)
        let personas = Config.enabledPersonas.prefix(3).map {
            GlassesActivityAttributes.ContentState.PersonaButton(id: $0.id, name: $0.name)
        }
        let initialState = GlassesActivityAttributes.ContentState(
            isConnected: false,
            isListening: false,
            isSpeaking: false,
            isProcessing: false,
            lastResponseSnippet: "",
            deviceName: nil,
            batteryLevel: nil,
            personaButtons: personas,
            quickActionButtons: quickActionButtons()
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            currentActivity = activity
            NSLog("[LiveActivity] Started: %@", activity.id)
        } catch {
            NSLog("[LiveActivity] Failed to start: %@", error.localizedDescription)
        }
    }

    /// Update the Live Activity with current state.
    func update(
        isConnected: Bool,
        isListening: Bool = false,
        isSpeaking: Bool = false,
        isProcessing: Bool = false,
        lastResponse: String = "",
        deviceName: String? = nil,
        batteryLevel: Int? = nil
    ) {
        guard let activity = currentActivity else { return }

        let snippet = String(lastResponse.prefix(80))
        let personas = Config.enabledPersonas.prefix(3).map {
            GlassesActivityAttributes.ContentState.PersonaButton(id: $0.id, name: $0.name)
        }
        let state = GlassesActivityAttributes.ContentState(
            isConnected: isConnected,
            isListening: isListening,
            isSpeaking: isSpeaking,
            isProcessing: isProcessing,
            lastResponseSnippet: snippet,
            deviceName: deviceName,
            batteryLevel: batteryLevel,
            personaButtons: personas,
            quickActionButtons: quickActionButtons()
        )

        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    /// End the Live Activity immediately.
    func end() {
        guard let activity = currentActivity else { return }
        let finalState = GlassesActivityAttributes.ContentState(
            isConnected: false,
            isListening: false,
            isSpeaking: false,
            isProcessing: false,
            lastResponseSnippet: "",
            deviceName: nil,
            batteryLevel: nil,
            personaButtons: [],
            quickActionButtons: []
        )

        Task {
            await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
            NSLog("[LiveActivity] Ended")
        }
        currentActivity = nil
    }
}
