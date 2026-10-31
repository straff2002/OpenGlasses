import Foundation

/// What a vault's `"vault_only": true` seals while a job on that vault is open (Plan KE P0).
///
/// A vault's `prompt_rules` can say "no web knowledge", and a tester's job searched the web anyway:
/// a rule in a prompt is not a guard. This holds the one decision: which tools may run on a sealed
/// job. **Everything not in `keptTools` is sealed**, whatever carries it, so a tool nobody has
/// thought about, a user's custom HTTP tool, a skill pack, an MCP tool (always a qualified name) and
/// the gateway's `execute` are shut without being named here. `sealedTools` is the other half of the
/// decision written down, so a guard test can walk `FieldToolProfile.names` and fail on a tool that
/// is in neither: a new tool is decided, not inherited.
///
/// Applied in four places, each reading this type and not its own list:
///  - declared and listed: `FieldToolProfile.declaredNames` (the declarations and the prompt's list
///    alike), `ToolExposureCore.names`, `ToolDeclarations.mcpToolDeclarations` and the gateway's
///    `execute` in `ToolDeclarations`;
///  - looked up: `ToolLookupTool.declarable`;
///  - refused at dispatch: `NativeToolRouter.featureGateRefusal`, ahead of every seam and for every
///    origin, so a remembered name, a goal step or a skill pack cannot reach a sealed tool;
///  - `UncertaintyReask`, which searches without going through the router at all.
///
/// It stops outside *sources*. The turn still goes to the chosen model; that is a choice of
/// provider, not of source, and the vault guide says so.
enum VaultOnlyPolicy {

    /// The job's own tools: what it reads from the vault, what it records, what it captures.
    nonisolated static let keptJobTools: Set<String> = [
        "field_session", "manual_lookup", "manual_figure", "show_source", "table_lookup", "equipment_lookup",
        "procedure_runner", "rule_chain", "propose_chain", "playbook",
        "reading", "evidence", "parts_request", "van_stock", "deliver_report", "escalate_to_expert",
        "team_learning", "service_history", "task", "propose_task",
        "capture_photo", "record_clip", "photo_log", "pin_frame", "smart_capture", "vision_assess",
        "look_closely", "scan_document", "scan_code", "scan_badge", "domain_calc", "refrigerant_gauges",
        "capture_flow", "safety_assessment", "first_aid", "emergency_info",
    ]

    /// The phone's own tools. None of them answers a technical question: the time, a timer, where
    /// the next job is, the wearer's own notes and memories, a call to a person.
    nonisolated static let keptPhoneTools: Set<String> = [
        "convert_units", "calculate", "reminder", "set_timer", "set_alarm", "calendar",
        "save_note", "list_notes", "session_search", "summarize_conversation", "new_topic", "yield_to_human",
        "remember_scene", "memory_search", "my_memory", "activity",
        "get_datetime", "get_weather", "where_am_i", "navigate", "get_directions", "find_nearby",
        "phone_call", "lookup_contact", "send_message",
        "flashlight", "brightness", "device_info", "teleprompter", "music_control", "step_count", "health_summary",
    ]

    /// `lookup_tools` stays: it answers only from what may be declared (`ToolLookupTool.declarable`),
    /// and without it an on-demand turn could not reach the job's own tools.
    nonisolated static let keptTools: Set<String> = keptJobTools.union(keptPhoneTools)
        .union([ToolLookupTool.toolName])

    /// The tools the job would otherwise be offered that bring outside knowledge in or lead back to
    /// a sealed tool. Documentation for the guard test: being absent from `keptTools` is what seals.
    nonisolated static let sealedTools: Set<String> = [
        // The web.
        "web_search", "get_news",
        // Takes any URL, or the one a QR code printed, and hands the page to the model as context.
        "qr_context",
        // Lists every tool and connected MCP server, so a sealed one would be offered back.
        "discover_capabilities",
        // Everyday tools no job is offered, kept out if the field profile is switched off:
        // the brain and a briefing reach outside the vault, and the rest are not the job's.
        "brain", "daily_briefing", "play_podcast", "translate", "health_check",
    ]

    /// Whether a job is sealed: one is open, and its vault said so when it started or says so now.
    /// Pure.
    nonisolated static func isSealed(jobOpen: Bool, recordedOnJob: Bool?, vaultSays: Bool?) -> Bool {
        jobOpen && (recordedOnJob == true || vaultSays == true)
    }

    /// Whether a tool is shut on a sealed job. Pure. Anything not kept is sealed, so an unknown name
    /// and an MCP tool's qualified name both answer true.
    nonisolated static func isSealed(tool name: String) -> Bool { !keptTools.contains(name) }

    /// `names` without what the seal shuts, in the same order. Pure.
    nonisolated static func unsealed(_ names: [String]) -> [String] {
        names.filter { !isSealed(tool: $0) }
    }

    /// What the model hears for a call the seal refused. Nothing ran, so nothing is left to retry.
    nonisolated static func refusal(tool name: String) -> String {
        "'\(name)' was not run: this job's vault is vault-only, so answers come from its manuals and "
            + "core files and nothing outside them can be looked up. Search with manual_lookup, or say "
            + "what the manuals do not cover."
    }

    /// Whether the job open right now is sealed.
    @MainActor
    static var jobIsSealed: Bool { FieldSessionService.shared.vaultOnlyJobOpen }
}
