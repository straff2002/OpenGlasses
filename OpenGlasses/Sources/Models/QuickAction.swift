import Foundation

/// A user-configurable quick action button shown on the main screen.
struct QuickAction: Codable, Identifiable {
    var id: String
    var label: String
    var icon: String
    var type: ActionType

    enum ActionType: String, Codable, CaseIterable, Identifiable {
        case prompt = "prompt"
        case photo = "photo"
        case photoThenPrompt = "photoThenPrompt"
        case homeAssistant = "homeAssistant"
        case siriShortcut = "siriShortcut"
        case openApp = "openApp"
        case toggleRecording = "toggleRecording"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .prompt: return "Text Prompt"
            case .photo: return "Take Photo"
            case .photoThenPrompt: return "Photo + Prompt"
            case .homeAssistant: return "Home Assistant"
            case .siriShortcut: return "Siri Shortcut"
            case .openApp: return "Open App"
            case .toggleRecording: return "Record Meeting"
            }
        }

        var description: String {
            switch self {
            case .prompt: return "Send a text prompt to the AI"
            case .photo: return "Capture and describe a photo"
            case .photoThenPrompt: return "Capture a photo with a custom prompt"
            case .homeAssistant: return "Call a Home Assistant service"
            case .siriShortcut: return "Run a Siri Shortcut by name"
            case .openApp: return "Open an app via URL scheme"
            case .toggleRecording: return "Start or stop a preserved meeting recording"
            }
        }
    }

    /// The prompt text (for .prompt and .photoThenPrompt types)
    var promptText: String?
    /// Home Assistant service call (e.g., "light.turn_off") for .homeAssistant type
    var haService: String?
    /// Home Assistant entity ID (e.g., "light.living_room") for .homeAssistant type
    var haEntityId: String?
    /// Extra data as JSON string for .homeAssistant type (e.g., {"brightness": 50})
    var haData: String?
    /// Siri Shortcut name for .siriShortcut type
    var shortcutName: String?
    /// URL scheme for .openApp type (e.g., "weixin://")
    var urlScheme: String?

    static let travelTemplates: [QuickAction] = [
        QuickAction(
            id: "travel-translate-sign-menu",
            label: "Translate Sign",
            icon: "text.viewfinder",
            type: .photoThenPrompt,
            promptText: "Read all visible text in this image. First provide exact original text, then translate to English. If helpful, use the translate tool to improve accuracy. Keep response concise for glasses."
        ),
        QuickAction(
            id: "travel-ask-local-phrase",
            label: "Local Phrase",
            icon: "globe",
            type: .prompt,
            promptText: "Help me say this naturally in the local language where I am. If my intent is unclear, ask one short clarification first. Then provide local phrase, pronunciation, and a polite variant. Use the translate tool."
        ),
    ]

    /// Built-in Field Assist quick action. Injected at the front of `Config.quickActions`
    /// whenever Field Assist is active (see `withFieldAssistAction`) — it is never persisted,
    /// so it appears/disappears with the entitlement. A `.prompt` action so it routes through
    /// the existing pipeline and the AI starts the session via the `field_session` tool.
    static let fieldAssist = QuickAction(
        id: "field-assist",
        label: "Field Assist",
        icon: "wrench.and.screwdriver.fill",
        type: .prompt,
        promptText: "Start a Field Assist session on my default vault. Briefly confirm you're ready and what you can help me troubleshoot."
    )

    /// Built-in record toggle — merged into existing users' persisted lists like the travel
    /// templates, so the meeting recorder is reachable without reconfiguring the speed dial.
    static let recordMeeting = QuickAction(
        id: "record-meeting",
        label: "Record",
        icon: "record.circle",
        type: .toggleRecording
    )

    static let defaults: [QuickAction] = [
        QuickAction(id: "describe", label: "Describe", icon: "eye", type: .photoThenPrompt,
                    promptText: "Describe what you see in this image in detail."),
        recordMeeting,
        QuickAction(id: "calendar", label: "Event", icon: "calendar", type: .photoThenPrompt,
                    promptText: "Extract any event details from this image (dates, times, locations, names) and create a calendar entry summary."),
        QuickAction(id: "task", label: "Task", icon: "checklist", type: .photoThenPrompt,
                    promptText: "Extract any action items or tasks from this image and list them."),
        QuickAction(id: "lights-off", label: "Lights Off", icon: "lightbulb.slash", type: .homeAssistant,
                    haService: "light.turn_off", haEntityId: "all"),
    ] + travelTemplates
}
