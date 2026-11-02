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
            case .prompt: return String(localized: "Text Prompt")
            case .photo: return String(localized: "Take Photo")
            case .photoThenPrompt: return String(localized: "Photo + Prompt")
            case .homeAssistant: return "Home Assistant"
            case .siriShortcut: return String(localized: "Siri Shortcut")
            case .openApp: return String(localized: "Open App")
            case .toggleRecording: return String(localized: "Record Meeting")
            }
        }

        /// English name for the model-facing quick-action tool output; `displayName` is the
        /// localized on-screen label.
        var toolLabel: String {
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
            case .prompt: return String(localized: "Send a text prompt to the AI")
            case .photo: return String(localized: "Capture and describe a photo")
            case .photoThenPrompt: return String(localized: "Capture a photo with a custom prompt")
            case .homeAssistant: return String(localized: "Call a Home Assistant service")
            case .siriShortcut: return String(localized: "Run a Siri Shortcut by name")
            case .openApp: return String(localized: "Open an app via URL scheme")
            case .toggleRecording: return String(localized: "Start or stop a preserved meeting recording")
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
            promptText: "Read all visible text in this image. First provide exact original text, then translate to English. If helpful, use the translate tool to improve accuracy. Keep response concise\(GlassesSupportPolicy.forGlasses)."
        ),
        QuickAction(
            id: "travel-ask-local-phrase",
            label: "Local Phrase",
            icon: "globe",
            type: .prompt,
            promptText: "Help me say this naturally in the local language where I am. If my intent is unclear, ask one short clarification first. Then provide local phrase, pronunciation, and a polite variant. Use the translate tool."
        ),
    ]

    /// Opens the manual picker directly; AppState handles this before sending any prompt.
    static let myManuals = QuickAction(
        id: "my-manuals", label: "My Manuals", icon: "books.vertical", type: .prompt
    )

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

    /// The general Field Assist tiles — the starter and the job tiles — in grid order. A trade's
    /// tiles follow them (`fieldAssistActions(trades:)`).
    static var fieldAssistActions: [QuickAction] { [fieldAssist] + fieldAssistJobActions }

    /// What Field Assist injects for these trades: the general tiles, then each trade's, in trade
    /// order. With no trade it is exactly `fieldAssistActions`.
    static func fieldAssistActions(trades: [FieldTrade]) -> [QuickAction] {
        fieldAssistActions + trades.flatMap(tradeActions(for:))
    }

    /// Every tile Field Assist may inject, whatever the trades. Stripped from any list before
    /// injection, never saved, and never offered for editing — each one is the app's, not the
    /// wearer's.
    static var fieldAssistManagedActions: [QuickAction] {
        fieldAssistActions + FieldTrade.allCases.flatMap(tradeActions(for:))
    }

    // MARK: - Trade presets

    /// The tiles a trade adds after the general job tiles. Injected and stripped exactly like
    /// them, and never persisted.
    static func tradeActions(for trade: FieldTrade) -> [QuickAction] {
        switch trade {
        case .refrigerationHVAC:
            return refrigerationTradeActions
        case .electrical:
            // None yet. Planned: a clause lookup in the loaded codes and standards (Plan IN) and a
            // test sheet read from a photo of handwritten results (Plan IR). Choosing the trade is
            // stored now, so those tiles arrive for the technicians who already chose it.
            return []
        }
    }

    /// Refrigeration and HVAC (Plan IS). Read Gauges is a `.prompt`, not a `.photoThenPrompt`:
    /// the picture belongs to `refrigerant_gauges`, which reads it with `instrument_reading`, files
    /// it on the job and keeps it for a follow-up answer — a photo sent with the prompt would be
    /// seen by the model and by nothing that computes. Without glasses the tile opens the phone
    /// camera first with the gauges' framing hint (`PhoneCapturePolicy.preCaptureTiles`) and the
    /// tool takes that staged photo; with glasses the tool takes a fresh still itself.
    ///
    /// The refrigerant log tile comes with Plan IS P2, which builds the log.
    static let refrigerationTradeActions: [QuickAction] = [
        QuickAction(
            id: "fa-read-gauges", label: "Read Gauges", icon: "gauge.with.dots.needle.67percent", type: .prompt,
            promptText: "Read the manifold or digital gauge set in front of me with refrigerant_gauges and give me superheat and subcooling. Use the refrigerant from the nameplate or this job's record; if you don't have it, or anything else is missing, ask me. If no picture can be taken, ask me to say the pressures and line temperatures, and work it out with domain_calc."),
        QuickAction(
            id: "fa-pt-lookup", label: "P-T Lookup", icon: "thermometer.medium", type: .prompt,
            promptText: "I need a pressure-temperature lookup. Ask me the refrigerant and either a gauge pressure or a temperature, then answer with domain_calc's pt_lookup. Never assume the refrigerant."),
    ]

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
                    promptText: "Describe the scene and the main objects or readable text in front of the wearer, in two or three spoken sentences. If the picture is too close, too dark or blurry, say that first."),
        recordMeeting,
    ] + travelTemplates
}
