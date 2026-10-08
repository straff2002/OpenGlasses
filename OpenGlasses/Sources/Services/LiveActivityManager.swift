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

    /// End any stale Live Activities left over from a previous launch (e.g. after force-quit).
    func endStaleActivities() {
        Task {
            for activity in Activity<GlassesActivityAttributes>.activities {
                await activity.end(.init(state: activity.content.state, staleDate: nil), dismissalPolicy: .immediate)
                PrivacyLog.device(.liveActivity, .staleEnded,
                                  item: PrivateIdentifier(activity.id))
            }
        }
    }

    /// Whether the wearer allows this app to show Live Activities at all (Settings › Avenkin).
    static var activitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Whether the activity this manager started is still live on the Lock Screen — not ended
    /// by the app, not swiped away by the wearer. What an `AudioRecordingIntent` must have before
    /// its `perform()` returns (see `AppState.startAskWithoutWakeWord`).
    var isRunning: Bool {
        guard let activity = currentActivity else { return false }
        return activity.activityState == .active
    }

    /// Start a new Live Activity. No-op if one is already running or Live Activities are disabled.
    /// Returns whether one is running afterwards.
    @discardableResult
    func start(glassesName: String = "Avenkin") -> Bool {
        // Clean up any stale activities from previous launches
        for activity in Activity<GlassesActivityAttributes>.activities where activity.id != currentActivity?.id {
            Task {
                await activity.end(.init(state: activity.content.state, staleDate: nil), dismissalPolicy: .immediate)
                PrivacyLog.device(.liveActivity, .staleEnded,
                                  item: PrivateIdentifier(activity.id))
            }
        }

        guard Self.activitiesEnabled else {
            PrivacyLog.device(.liveActivity, .notEnabled)
            return false
        }
        // One the wearer dismissed from the Lock Screen is gone for good; request a fresh one.
        if isRunning {
            PrivacyLog.device(.liveActivity, .alreadyRunning)
            return true
        }
        currentActivity = nil

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
            PrivacyLog.device(.liveActivity, .started, item: PrivateIdentifier(activity.id))
            return true
        } catch {
            PrivacyLog.device(.liveActivity, .startFailed, error: SafeErrorSummary(error))
            return false
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

    /// End the Live Activity immediately — also kills any stale activities from previous launches.
    func end() {
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

        // End tracked activity
        if let activity = currentActivity {
            Task {
                await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
                PrivacyLog.device(.liveActivity, .ended)
            }
            currentActivity = nil
        }

        // Also kill any stale activities from previous launches (e.g. after force-quit)
        Task {
            for activity in Activity<GlassesActivityAttributes>.activities {
                await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
                PrivacyLog.device(.liveActivity, .staleEnded,
                                  item: PrivateIdentifier(activity.id))
            }
        }
    }
}
