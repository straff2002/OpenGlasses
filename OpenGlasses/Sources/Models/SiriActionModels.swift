import Foundation

// MARK: - Plan BQ P1 — Siri exposure models
//
// Static App Intents are compiled into the app's metadata and can't be added or removed at
// runtime. Everything user-controllable therefore routes through ONE generic intent
// (`RunGlassesActionIntent`) whose `SiriActionEntity` parameter is resolved against these
// models at query time — entity queries are runtime code, so the user's selections directly
// control what Siri can see and predict.

/// The kind of user-authored capability a harvested Siri action launches.
enum SiriCapabilityKind: String, Codable, CaseIterable {
    case captureFlow = "capture_flow"
    case procedure
    case playbook
    case customTool = "custom_tool"
    /// A tile on the Voice tab's grid — a shipped action or one of the wearer's speed-dial
    /// actions — keyed by its `HomeGridEntry.id` ("builtin:…" / "quick:…").
    ///
    /// Deliberately a *capability kind* rather than a new binding case: the grid's actions are
    /// harvested exactly like capture flows and playbooks, so they inherit the same storage
    /// (`enabledCapabilityIds`), the same default-off rule, and the same curation screen —
    /// and `SiriExposureConfig`'s stored shape does not change, so an exposure saved by an
    /// earlier build still decodes.
    case gridAction = "grid_action"

    var displayLabel: String {
        switch self {
        case .captureFlow: return "Capture Flow"
        case .procedure: return "Procedure"
        case .playbook: return "Playbook"
        case .customTool: return "Custom Tool"
        case .gridAction: return "Grid Action"
        }
    }
}

/// What a Siri action does when invoked.
enum SiriActionBinding: Codable, Equatable {
    /// One of the curated built-in behaviours (photo, listening, live modes, …), keyed by
    /// the same id used for the Settings toggle and the static-intent runtime guard.
    case builtin(id: String)
    /// A canned instruction sent through the normal direct-mode assistant turn.
    case prompt(text: String)
    /// A single native-tool call; the string result becomes the Siri dialog.
    case tool(name: String, argsJSON: String)
    /// Launches a user-authored capability by id (capture flow / procedure / playbook /
    /// custom tool).
    case capability(kind: SiriCapabilityKind, id: String)

    /// The native-tool name this binding ultimately calls, if any — used for HIPAA gating.
    var toolName: String? {
        switch self {
        case .builtin, .prompt: return nil
        case .tool(let name, _): return name
        case .capability(let kind, let id):
            switch kind {
            case .captureFlow: return "capture_flow"
            case .procedure: return "procedure_runner"
            case .playbook: return "playbook"
            case .customTool: return id // custom tools are registered under their own name
            // A grid tile is a canned *turn*, not a tool call: it reaches the assistant through
            // the same seam the wearer's own typing does, and whatever tool the model then picks
            // goes through the router's gates like any other. There is no single tool to name.
            case .gridAction: return nil
            }
        }
    }
}

/// A user-created Siri action (the "hand-made" catalog source).
struct SiriActionDefinition: Codable, Identifiable, Equatable {
    var id: String
    var displayName: String
    /// Alternate spoken names Siri should also resolve ("brief me", "morning rundown").
    var synonyms: [String]
    var binding: SiriActionBinding
    var isEnabled: Bool
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        displayName: String,
        synonyms: [String] = [],
        binding: SiriActionBinding,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.synonyms = synonyms
        self.binding = binding
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

/// Persisted Siri exposure selections (Config-backed).
///
/// Built-ins default ON (parity with the static intents that already shipped), so the set
/// stores *disabled* ids — a new built-in added in a later release is exposed without a
/// migration. Harvested capabilities default OFF, so that set stores *enabled* ids.
struct SiriExposureConfig: Codable, Equatable {
    var disabledBuiltinActions: Set<String> = []
    /// Enabled harvested capabilities, keyed "\(kind.rawValue):\(id)".
    var enabledCapabilityIds: Set<String> = []
    var userActions: [SiriActionDefinition] = []

    init(
        disabledBuiltinActions: Set<String> = [],
        enabledCapabilityIds: Set<String> = [],
        userActions: [SiriActionDefinition] = []
    ) {
        self.disabledBuiltinActions = disabledBuiltinActions
        self.enabledCapabilityIds = enabledCapabilityIds
        self.userActions = userActions
    }

    static func capabilityKey(kind: SiriCapabilityKind, id: String) -> String {
        "\(kind.rawValue):\(id)"
    }
}
