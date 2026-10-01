import Foundation

/// A user-configurable quick action button shown on the main screen.
struct QuickAction: Codable, Identifiable, Equatable {
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
    /// so it appears/disappears with the entitlement.
    ///
    /// Still a `.prompt` so it keeps its persisted shape, but **`AppState` starts the job itself**
    /// before the prompt is sent (Plan FO P1): this is the entry point a technician is most likely
    /// to tap, and whether a job starts cannot be left to the model's reading of a sentence. The
    /// text below is the introduction that follows, and it says the session is already running so
    /// nothing tries to start a second one.
    static let fieldAssist = QuickAction(
        id: "field-assist",
        label: "Field Assist",
        icon: "wrench.and.screwdriver.fill",
        type: .prompt,
        promptText: "A Field Assist session has just been started on my default vault — do not call field_session start. Briefly confirm you're ready and what you can help me troubleshoot."
    )

    /// The job tiles that ride in with Field Assist, after `fieldAssist` itself. Injected and
    /// stripped exactly as it is — never persisted, so they leave the grid with the entitlement.
    /// Each asks for the job step it is named after; the Field Assist tools do the work, and a
    /// tile pressed with no job open is answered by the tool saying so.
    static let fieldAssistJobActions: [QuickAction] = [
        QuickAction(
            id: "fa-log-photo", label: "Log Photo", icon: "photo.badge.plus", type: .prompt,
            promptText: "Take a photo for this job's log. Caption it with what it shows, and tell me in one line what you logged."),
        QuickAction(
            id: "fa-fault-code", label: "Fault Code", icon: "exclamationmark.magnifyingglass", type: .prompt,
            promptText: "Read the fault code or nameplate in front of me and look it up in this job's manuals. Tell me what it means and the first thing to check."),
        QuickAction(
            id: "fa-safety-check", label: "Safety Check", icon: "checkmark.shield", type: .prompt,
            promptText: "Run a safety assessment on what I'm looking at. Tell me any serious hazard that isn't controlled, most dangerous first."),
        QuickAction(
            id: "fa-order-part", label: "Order Part", icon: "shippingbox", type: .prompt,
            promptText: "I need a part for this job. Ask me the part number and quantity, then request it from base."),
        QuickAction(
            id: "fa-send-report", label: "Send Report", icon: "paperplane", type: .prompt,
            promptText: "Send this job's report to base, and tell me where it went."),
    ]

    /// Everything Field Assist injects, in grid order.
    static var fieldAssistActions: [QuickAction] { [fieldAssist] + fieldAssistJobActions }

    /// Built-in record toggle — merged into existing users' persisted lists like the travel
    /// templates, so the meeting recorder is reachable without reconfiguring the speed dial.
    static let recordMeeting = QuickAction(
        id: "record-meeting",
        label: "Record",
        icon: "record.circle",
        type: .toggleRecording
    )

    /// A fresh install's speed dial. Deliberately short: the photo → event and photo → task actions
    /// that used to sit here duplicated the grid's own `Photo → Event` / `Photo → Task`, and a
    /// Home Assistant "Lights Off" did nothing for anyone without Home Assistant. Existing lists
    /// are the wearer's and keep whatever they hold.
    static let defaults: [QuickAction] = [
        QuickAction(id: "describe", label: "Describe", icon: "eye", type: .photoThenPrompt,
                    promptText: "Describe what you see in this image in detail."),
        recordMeeting,
    ] + travelTemplates
}
