import Foundation

// MARK: - Plan BQ P1 — Siri action catalog (pure core)
//
// Merges the three candidate sources — curated built-ins, harvested user-authored
// capabilities, and hand-made user actions — applies enablement + compliance gating, and
// resolves entity ids back to bindings. No AppIntents, no singletons: the intent layer and
// the Settings UI both build a catalog from injected inputs, so all policy is headless-
// testable.

/// A curated built-in Siri action. The `id` triples as the Settings toggle key, the
/// static-intent runtime-guard key (`IntentSupport.requireEnabled`), and the dispatch key in
/// `BuiltinActionRunner`.
struct BuiltinSiriAction: Identifiable, Equatable {
    let id: String
    let displayName: String
    let synonyms: [String]

    /// Curation rule (plan BQ): only actions Siri/system apps can't already do — glasses
    /// hardware, or OpenGlasses' own data.
    static let all: [BuiltinSiriAction] = [
        .init(id: "take_photo", displayName: "Take and Describe Photo",
              synonyms: ["describe photo", "what do you see"]),
        .init(id: "capture_photo", displayName: "Capture Photo",
              synonyms: ["snap a photo", "silent photo"]),
        .init(id: "record_video", displayName: "Record Video",
              synonyms: ["start recording", "stop recording"]),
        .init(id: "describe_scene", displayName: "Describe Scene",
              synonyms: ["describe what you see"]),
        .init(id: "read_text", displayName: "Read Text",
              synonyms: ["read this", "read aloud"]),
        .init(id: "translate_text", displayName: "Translate Text",
              synonyms: ["translate this"]),
        .init(id: "analyze_food", displayName: "Analyze Food",
              synonyms: ["is this healthy", "food check"]),
        .init(id: "identify_object", displayName: "Identify Object",
              synonyms: ["what is this"]),
        .init(id: "describe_environment", displayName: "Describe Environment",
              synonyms: ["what's around me", "surroundings"]),
        .init(id: "connect_glasses", displayName: "Connect Glasses",
              synonyms: ["connect"]),
        .init(id: "disconnect_glasses", displayName: "Disconnect Glasses",
              synonyms: ["disconnect"]),
        .init(id: "toggle_glasses", displayName: "Toggle Glasses Connection",
              synonyms: []),
        .init(id: "listening_on", displayName: "Start Listening",
              synonyms: ["wake word on"]),
        .init(id: "listening_off", displayName: "Stop Listening",
              synonyms: ["wake word off"]),
        .init(id: "gemini_live_toggle", displayName: "Toggle Live Session",
              synonyms: ["live mode"]),
        .init(id: "live_mode_standard", displayName: "Live Standard Mode",
              synonyms: []),
        .init(id: "live_mode_museum", displayName: "Museum Guide Mode",
              synonyms: ["museum mode", "docent"]),
        .init(id: "live_mode_accessibility", displayName: "Blind Assistant Mode",
              synonyms: ["accessibility mode"]),
        .init(id: "live_mode_reading", displayName: "Reading Assistant Mode",
              synonyms: []),
        .init(id: "live_mode_translator", displayName: "Live Translator Mode",
              synonyms: ["translator mode"]),
        .init(id: "live_mode_tutor", displayName: "Language Tutor Mode",
              synonyms: []),
        .init(id: "memory_rewind", displayName: "Memory Rewind",
              synonyms: ["what did I miss", "what did they just say"]),
        .init(id: "daily_briefing", displayName: "Daily Briefing",
              synonyms: ["brief me", "morning briefing"]),
        .init(id: "teleprompter_start", displayName: "Start Teleprompter",
              synonyms: []),
        .init(id: "teleprompter_stop", displayName: "Stop Teleprompter",
              synonyms: []),
        .init(id: "meeting_summary", displayName: "Meeting Summary",
              synonyms: ["summarize the meeting", "summarize this conversation"]),
        .init(id: "save_location", displayName: "Save This Location",
              synonyms: ["remember this spot"]),
        .init(id: "broadcast_toggle", displayName: "Toggle Broadcast",
              synonyms: ["start broadcasting", "stop broadcasting", "go live"]),
    ]

    static func action(id: String) -> BuiltinSiriAction? {
        all.first { $0.id == id }
    }
}

/// A user-authored capability discovered by `CapabilityHarvester` and offered as a
/// toggleable Siri-action candidate.
struct HarvestedCapability: Identifiable, Equatable {
    let kind: SiriCapabilityKind
    let capabilityId: String
    let title: String

    /// Stable key, also used in `SiriExposureConfig.enabledCapabilityIds`.
    var id: String { SiriExposureConfig.capabilityKey(kind: kind, id: capabilityId) }
}

/// Discovers user-authored capabilities from injected library snapshots. Pure — the live
/// provider passes real library contents; tests pass fixtures.
enum CapabilityHarvester {
    static func harvest(
        flows: [(id: String, title: String)] = [],
        procedures: [(id: String, title: String)] = [],
        playbooks: [(id: String, name: String)] = [],
        customTools: [CustomToolDefinition] = []
    ) -> [HarvestedCapability] {
        var out: [HarvestedCapability] = []
        out += flows.map { .init(kind: .captureFlow, capabilityId: $0.id, title: $0.title) }
        out += procedures.map { .init(kind: .procedure, capabilityId: $0.id, title: $0.title) }
        out += playbooks.map { .init(kind: .playbook, capabilityId: $0.id, title: $0.name) }
        out += customTools.map { .init(kind: .customTool, capabilityId: $0.name, title: $0.name) }
        return out
    }
}

/// The merged, gated catalog the entity query and Settings UI both consume.
struct SiriActionCatalog {
    enum Source: Equatable { case builtin, harvested, user }

    struct Entry: Identifiable, Equatable {
        /// Namespaced: "builtin:<id>" / "capability:<kind>:<id>" / "user:<uuid>".
        let id: String
        let displayName: String
        let synonyms: [String]
        let binding: SiriActionBinding
        let source: Source
        let isEnabled: Bool
    }

    let entries: [Entry]

    /// - Parameters:
    ///   - blockedToolNames: tool names compliance currently forbids (pass
    ///     `Config.hipaaDisabledTools` when `Config.hipaaMode`, else empty). Entries whose
    ///     binding resolves to a blocked tool are dropped entirely, not just disabled.
    ///   - agentModeEnabled: custom-tool bindings (Shortcuts / URL-scheme egress) are
    ///     catalog-eligible only when Agent Mode is on.
    init(
        config: SiriExposureConfig,
        harvested: [HarvestedCapability] = [],
        agentModeEnabled: Bool = false,
        blockedToolNames: Set<String> = []
    ) {
        var out: [Entry] = []

        for builtin in BuiltinSiriAction.all {
            out.append(Entry(
                id: "builtin:\(builtin.id)",
                displayName: builtin.displayName,
                synonyms: builtin.synonyms,
                binding: .builtin(id: builtin.id),
                source: .builtin,
                isEnabled: !config.disabledBuiltinActions.contains(builtin.id)
            ))
        }

        for capability in harvested {
            let binding = SiriActionBinding.capability(kind: capability.kind, id: capability.capabilityId)
            guard Self.isEligible(binding, agentModeEnabled: agentModeEnabled, blockedToolNames: blockedToolNames) else { continue }
            out.append(Entry(
                id: "capability:\(capability.id)",
                displayName: capability.title,
                synonyms: [],
                binding: binding,
                source: .harvested,
                isEnabled: config.enabledCapabilityIds.contains(capability.id)
            ))
        }

        for action in config.userActions {
            guard Self.isEligible(action.binding, agentModeEnabled: agentModeEnabled, blockedToolNames: blockedToolNames) else { continue }
            out.append(Entry(
                id: "user:\(action.id)",
                displayName: action.displayName,
                synonyms: action.synonyms,
                binding: action.binding,
                source: .user,
                isEnabled: action.isEnabled
            ))
        }

        self.entries = out
    }

    var enabledEntries: [Entry] { entries.filter(\.isEnabled) }

    func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    /// Enabled entries whose name or a synonym contains the spoken/typed string
    /// (case-insensitive) — backs `EntityStringQuery.entities(matching:)`.
    func entries(matching string: String) -> [Entry] {
        let target = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return [] }
        return enabledEntries.filter { entry in
            entry.displayName.lowercased().contains(target)
                || entry.synonyms.contains { $0.lowercased().contains(target) }
        }
    }

    private static func isEligible(
        _ binding: SiriActionBinding,
        agentModeEnabled: Bool,
        blockedToolNames: Set<String>
    ) -> Bool {
        if case .capability(kind: .customTool, id: _) = binding, !agentModeEnabled { return false }
        guard let tool = binding.toolName else { return true }
        if blockedToolNames.contains(tool) { return false }
        // A bound tool runs straight off the registry, with no router and so no confirmation
        // gate. Compliance blocking (above) and the composition floor are separate screens: an
        // action can be forbidden by either.
        if ComposedToolPolicy.isRestrictedTarget(tool) { return false }
        return true
    }

    // MARK: Validation (user-created actions)

    enum ValidationIssue: Equatable {
        case emptyName
        case duplicateName(String)
        case emptyPrompt
        case unknownTool(String)
        case invalidArgsJSON
        case toolBlockedByCompliance(String)
        case toolNeedsDirectConfirmation(String)
        case agentModeRequired
    }

    /// Validate a new/edited user action against the current catalog.
    /// - Parameter availableToolNames: pass the registry's tool names to catch typos in
    ///   `.tool` bindings; nil skips existence checking (e.g. before registry is up).
    static func validate(
        _ definition: SiriActionDefinition,
        existing: [Entry],
        availableToolNames: Set<String>?,
        agentModeEnabled: Bool,
        blockedToolNames: Set<String>
    ) -> ValidationIssue? {
        let name = definition.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .emptyName }
        let collision = existing.first {
            $0.displayName.lowercased() == name.lowercased() && $0.id != "user:\(definition.id)"
        }
        if let collision { return .duplicateName(collision.displayName) }

        switch definition.binding {
        case .builtin:
            break
        case .prompt(let text):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyPrompt }
        case .tool(let toolName, let argsJSON):
            if blockedToolNames.contains(toolName) { return .toolBlockedByCompliance(toolName) }
            if ComposedToolPolicy.isRestrictedTarget(toolName) {
                return .toolNeedsDirectConfirmation(toolName)
            }
            if let availableToolNames, !availableToolNames.contains(toolName) {
                return .unknownTool(toolName)
            }
            if !argsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let data = argsJSON.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil else {
                    return .invalidArgsJSON
                }
            }
        case .capability(let kind, let id):
            if kind == .customTool {
                if !agentModeEnabled { return .agentModeRequired }
                if blockedToolNames.contains(id) { return .toolBlockedByCompliance(id) }
            } else if let tool = definition.binding.toolName, blockedToolNames.contains(tool) {
                return .toolBlockedByCompliance(tool)
            }
            if let tool = definition.binding.toolName, ComposedToolPolicy.isRestrictedTarget(tool) {
                return .toolNeedsDirectConfirmation(tool)
            }
        }
        return nil
    }
}
