import Foundation

/// What a native `write` tool may do in a private conversation (Plan LU §4).
///
/// Every native tool whose `ToolEffectClass` is `write` is one of two kinds:
/// - **memory-like**: it writes something Avenkin learns or keeps on its own initiative — memory,
///   the brain, people, the diary, voice-taught skills, the agent's own documents. In a private
///   conversation the router refuses it before authorization, with `refusalReason` for the model.
/// - **wearer-directed**: something the wearer asked for by name — a reminder, a timer, a note, a
///   saved place, a photo, the torch. It runs as usual, and what it makes is kept where it normally
///   lives, because the wearer asked for it (decision 2).
///
/// **Per action, where a tool mixes them.** A memory-like tool that also reads, or forgets, is
/// refused only for the actions that write: `my_memory correct` is refused, `my_memory forget`
/// runs. The table lists, for each such tool, the actions that still run — its reads and its
/// forgetting — under every alias the tool's own `execute` switch accepts. Anything else, including
/// an action the table does not know, is refused: a refused read costs the wearer a re-ask, a missed
/// write would keep what they asked not to be kept. Forgetting is never blocked, and
/// `PrivateToolRuleGuardTests` pins every forget alias.
///
/// MCP, custom, skill-pack and gateway tools are not classified here; they run under the external
/// seam's rules, as today. `PrivateToolRuleGuardTests` fails on any registered native `write` tool
/// missing from `kinds`, so a new one has to choose.
enum PrivateToolRule {

    enum Kind: String, Equatable, Sendable {
        case memoryLike
        case wearerDirected
    }

    enum Decision: Equatable, Sendable {
        case run
        case refuse(reason: String)
    }

    /// What the model is told when a memory-like call is refused. Model-facing, never shown.
    static let refusalReason = "This conversation is private: nothing is remembered. Offer a reminder "
        + "or a note if the wearer wants to keep something."

    /// The kind of every native `write` tool, by name.
    static let kinds: [String: Kind] = [
        // Memory-like (§4).
        "remember_scene": .memoryLike,
        "my_memory": .memoryLike,
        "agent_diary": .memoryLike,
        "brain": .memoryLike,
        "social_context": .memoryLike,
        "object_memory": .memoryLike,
        "meeting_summary": .memoryLike,
        "team_learning": .memoryLike,
        "voice_skills": .memoryLike,
        "edit_agent_docs": .memoryLike,
        // Not named in §4: a badge scan saves the person on it to the brain.
        "scan_badge": .memoryLike,

        // Wearer-directed, named in §4.
        "reminder": .wearerDirected,
        "calendar": .wearerDirected,
        "save_note": .wearerDirected,
        "set_timer": .wearerDirected,
        "goals": .wearerDirected,
        "task": .wearerDirected,
        "geofence": .wearerDirected,
        "save_location": .wearerDirected,
        "parking": .wearerDirected,

        // Wearer-directed, not named in §4. Notes, saves and alarms the wearer asks for by name.
        "notes_vault": .wearerDirected,
        "health_vault": .wearerDirected,
        "contextual_note": .wearerDirected,
        "document_knowledge": .wearerDirected,
        "set_alarm": .wearerDirected,
        "pomodoro": .wearerDirected,
        "manage_schedule": .wearerDirected,
        "playbook": .wearerDirected,
        "copy_to_clipboard": .wearerDirected,
        "study": .wearerDirected,
        "fitness_coach": .wearerDirected,
        "golf_mode": .wearerDirected,
        // A conversation reset; in a private conversation P1 treats it as `startFresh`.
        "new_topic": .wearerDirected,
        // The camera, the glasses and the phone doing what was asked.
        "capture_photo": .wearerDirected,
        "scan_document": .wearerDirected,
        "smart_capture": .wearerDirected,
        "look_closely": .wearerDirected,
        "pin_frame": .wearerDirected,
        "reading_assist": .wearerDirected,
        "reading_session": .wearerDirected,
        "identify_medication": .wearerDirected,
        "identify_money": .wearerDirected,
        "live_coach": .wearerDirected,
        "live_translate": .wearerDirected,
        "teleprompter": .wearerDirected,
        "audio_recording": .wearerDirected,
        "video_recording": .wearerDirected,
        "instant_replay": .wearerDirected,
        "flashlight": .wearerDirected,
        "brightness": .wearerDirected,
        "music_control": .wearerDirected,
        "smart_home": .wearerDirected,
        "home_assistant": .wearerDirected,
        "quick_action": .wearerDirected,
        "navigate": .wearerDirected,
        "navigation_assist": .wearerDirected,
        "get_directions": .wearerDirected,
        "open_app": .wearerDirected,
        "play_podcast": .wearerDirected,
        "first_aid": .wearerDirected,
        "code_agent": .wearerDirected,
        "openclaw_skills": .wearerDirected,
        // Field Assist job tools. A private conversation never starts during a job, so these only
        // matter if one is called anyway; they write the job's record, which the wearer opened.
        "field_session": .wearerDirected,
        "project_note": .wearerDirected,
        "capture_flow": .wearerDirected,
        "procedure_runner": .wearerDirected,
        "rule_chain": .wearerDirected,
        "propose_chain": .wearerDirected,
        "propose_task": .wearerDirected,
        "van_stock": .wearerDirected,
        "reading": .wearerDirected,
        "evidence": .wearerDirected,
        "record_clip": .wearerDirected,
        "photo_log": .wearerDirected,
        "refrigerant_gauges": .wearerDirected,
        "safety_assessment": .wearerDirected,
        "equipment_lookup": .wearerDirected,
        "manual_lookup": .wearerDirected,
        "manual_capture": .wearerDirected,
        "manual_figure": .wearerDirected,
        "show_source": .wearerDirected,
        "scan_assist": .wearerDirected,
    ]

    /// For each memory-like tool with mixed actions, the forgetting actions, under every alias its
    /// `execute` switch accepts. These always run.
    static let forgetActions: [String: Set<String>] = [
        "my_memory": ["forget"],
        "brain": ["forget", "resolve_need", "resolve", "done", "close_need"],
        "social_context": ["forget", "clear", "delete"],
        "object_memory": ["forget", "remove", "delete"],
        "voice_skills": ["delete", "forget", "remove", "clear"],
        "team_learning": ["withdraw", "retract", "delete", "remove"],
    ]

    /// For each memory-like tool with mixed actions, the read actions, under every alias its
    /// `execute` switch accepts. These run too.
    static let readActions: [String: Set<String>] = [
        "my_memory": ["list", "about"],
        "brain": ["query", "search", "ask", "recall", "remember", "history", "insights", "usage", "recap",
                  "person", "dossier", "who", "encounters", "sightings", "needs", "follow_ups",
                  "followups", "todos", "status", "stats"],
        "social_context": ["recall", "about", "who", "list", "people"],
        "object_memory": ["find", "where", "locate", "list"],
        "voice_skills": ["list"],
        "team_learning": ["list", "read", "status"],
        "agent_diary": ["read", "search"],
        "edit_agent_docs": ["read", "list_personas"],
    ]

    /// The action each of those tools assumes when the call names none, mirrored from its own
    /// `execute`. A tool without a row here has no default, and a call without an action is refused.
    static let defaultActions: [String: String] = [
        "my_memory": "list",
        "brain": "query",
        "social_context": "list",
        "object_memory": "list",
        "voice_skills": "list",
        "agent_diary": "read",
    ]

    /// The kind of a native tool, or nil for one this table does not classify (a read, a
    /// messaging tool, or an external tool).
    static func kind(of tool: String) -> Kind? { kinds[tool] }

    /// Whether this call may run in a private conversation. Consulted only while one is open.
    static func decision(tool: String, args: [String: Any]) -> Decision {
        guard kinds[tool] == .memoryLike else { return .run }

        // The meeting summary is a read unless it saves the summary as a note, which it does by
        // default.
        if tool == "meeting_summary" {
            return (args["save"] as? Bool) == false ? .run : .refuse(reason: refusalReason)
        }

        let reads = readActions[tool] ?? []
        let forgets = forgetActions[tool] ?? []
        guard !reads.isEmpty || !forgets.isEmpty else {
            // A memory-like tool whose every action writes.
            return .refuse(reason: refusalReason)
        }
        let named = (args["action"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let action = (named?.isEmpty == false ? named : nil) ?? defaultActions[tool] else {
            return .refuse(reason: refusalReason)
        }
        return reads.contains(action) || forgets.contains(action) ? .run : .refuse(reason: refusalReason)
    }
}
