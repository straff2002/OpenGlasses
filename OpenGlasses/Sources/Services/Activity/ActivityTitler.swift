import Foundation

/// A trail row's words for one tool call: the title, and — when the wearer was shown an approval
/// line — that line as the detail.
struct ActivityTitle: Equatable, Sendable {
    let title: String
    let detail: String?
}

/// Titles for the trail (Plan IW): one fixed, past-tense, second-person template per side-effecting
/// native tool, sharpened by the action key where a tool has several actions.
///
/// The model never writes a title. Where the call went through an approval, the approval line the
/// wearer saw (`ToolEffectClassifier.approvalSummary`) becomes the detail, so the row shows exactly
/// what was approved — minus any quoted message body, because the trail holds the assistant's
/// actions, never the wearer's words. Reads get no title at all: the trail is actions, not a
/// transcript. `ActivityTitlerTests` walks the real registry and fails on any side-effecting tool
/// without a template here.
enum ActivityTitler {

    struct Template: Sendable {
        let title: String
        /// Sharper titles for particular actions (aliases listed as their own keys).
        let actions: [String: String]
        /// Actions of a side-effecting tool that only read, and so are not recorded.
        let reads: Set<String>

        init(_ title: String, actions: [String: String] = [:], reads: Set<String> = []) {
            self.title = title
            self.actions = actions
            self.reads = reads
        }
    }

    /// The title, or nil when the call only reads.
    static func title(tool: String, actionKey: String?, approvalSummary: String? = nil,
                      effectClass: ToolEffectClass) -> ActivityTitle? {
        guard effectClass != .readOnly else { return nil }
        let action = actionKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let title: String
        if let template = templates[tool] {
            if let action, template.reads.contains(action) { return nil }
            title = action.flatMap { template.actions[$0] } ?? template.title
        } else {
            title = genericTitle(tool: tool)
        }
        return ActivityTitle(title: ActivityEntry.clamp(title, to: ActivityEntry.titleLength),
                             detail: approvalSummary.flatMap(approvedDetail))
    }

    static func hasTemplate(for tool: String) -> Bool { templates[tool] != nil }

    /// What a tool with no template gets — an MCP server's tool, a user-authored HTTP tool, a skill
    /// pack. Deliberately plain: it names the tool rather than guessing what it did.
    static func genericTitle(tool: String) -> String {
        let readable = tool.replacingOccurrences(of: "__", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return "Used the \(readable.isEmpty ? "unnamed" : readable) tool"
    }

    /// "You approved: Send a message to Mum" — cut before any quoted body.
    static func approvedDetail(_ summary: String) -> String? {
        var line = summary
        if let quote = line.firstIndex(where: { $0 == "“" || $0 == "\"" }) {
            line = String(line[..<quote])
        }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = line.last, last == ":" || last == "," {
            line.removeLast()
            line = line.trimmingCharacters(in: .whitespaces)
        }
        guard !line.isEmpty else { return nil }
        return ActivityEntry.clamp("You approved: " + line, to: ActivityEntry.detailLength)
    }

    // MARK: - Templates

    static let templates: [String: Template] = [
        // Notes, memory and the assistant's own stores
        "save_note": .init("Saved a note for you"),
        "notes_vault": .init("Added a note to your vault", reads: ["query", "recall"]),
        "health_vault": .init("Logged a health entry for you", reads: ["query"]),
        "contextual_note": .init("Saved a note about where you are"),
        "project_note": .init("Saved a project note", actions: ["clear": "Cleared your project notes"],
                              reads: ["list"]),
        "playbook": .init("Updated a playbook", actions: [
            "start": "Started a playbook", "finish": "Finished a playbook",
            "create": "Made a new playbook", "add_note": "Added a note to the playbook",
            "add_result": "Recorded a result in the playbook", "skip": "Skipped a playbook step",
        ], reads: ["list", "status"]),
        "meeting_summary": .init("Saved a meeting summary as a note"),
        "social_context": .init("Updated what you've noted about someone"),
        "brain": .init("Updated your memory", actions: [
            "save_need": "Noted something you need to follow up",
            "resolve_need": "Marked a follow-up as done", "link": "Linked two things in your memory",
            "forget": "Forgot something you asked me to",
        ], reads: ["query", "recall", "insights", "person", "encounters", "needs", "status"]),
        "my_memory": .init("Updated what I remember about you", actions: [
            "forget": "Forgot something you asked me to", "correct": "Corrected something I remembered",
        ], reads: ["list", "about"]),
        "agent_diary": .init("Wrote in my diary"),
        "edit_agent_docs": .init("Updated my instructions"),
        // Plan IW P1. Proposing, revising and declining a goal change nothing stored — the goal is
        // kept only on 'accept' — so they are not actions here.
        "goals": .init("Changed a goal", actions: [
            "accept": "Added a goal for you", "step_done": "Marked a goal step done",
            "skip": "Skipped a goal step", "complete": "Marked a goal done", "pause": "Paused a goal",
            "resume": "Picked a goal back up", "abandon": "Set a goal aside", "edit": "Changed a goal",
        ], reads: ["list", "status", "next", "add", "revise", "decline"]),
        "manage_schedule": .init("Changed a scheduled task", actions: [
            "create": "Scheduled a task for you", "enable": "Turned on a scheduled task",
            "disable": "Turned off a scheduled task", "delete": "Deleted a scheduled task",
        ], reads: ["list"]),
        "document_knowledge": .init("Added a document to your library", actions: [
            "forget": "Removed a document from your library",
        ], reads: ["query", "list"]),
        "voice_skills": .init("Saved a voice skill", actions: [
            "delete": "Deleted a voice skill", "clear": "Cleared your voice skills",
        ], reads: ["list"]),
        "object_memory": .init("Remembered where you put something", actions: [
            "forget": "Forgot where something was",
        ], reads: ["find", "where", "locate", "list"]),
        "copy_to_clipboard": .init("Copied something to your clipboard"),
        "new_topic": .init("Started a new topic"),
        "pin_frame": .init("Pinned a picture from the camera"),
        "reading": .init("Recorded a reading", actions: ["correct_reading": "Corrected a reading"]),
        "face_recognition": .init("Changed face recognition", actions: [
            "remember": "Remembered a face you asked me to", "forget": "Forgot a face you asked me to",
            "on": "Turned face recognition on", "off": "Turned face recognition off",
            "toggle": "Switched face recognition",
        ], reads: ["list", "status"]),

        // Time and places
        "calendar": .init("Changed your calendar", actions: [
            "create": "Added an event to your calendar", "add": "Added an event to your calendar",
        ], reads: ["today", "schedule", "next", "upcoming", "week", "this_week", "tomorrow"]),
        "reminder": .init("Changed your reminders", actions: [
            "create": "Set a reminder for you", "add": "Set a reminder for you",
            "set": "Set a reminder for you", "complete": "Completed a reminder",
            "done": "Completed a reminder", "finish": "Completed a reminder",
        ], reads: ["list", "show"]),
        "set_alarm": .init("Set an alarm for you", actions: [
            "cancel_all": "Cancelled your alarms", "cancel": "Cancelled your alarms",
            "clear": "Cancelled your alarms",
        ], reads: ["list", "show"]),
        "set_timer": .init("Started a timer for you"),
        "pomodoro": .init("Changed your focus session", actions: [
            "start": "Started a focus session", "begin": "Started a focus session",
            "focus": "Started a focus session", "start_break": "Started a break",
            "break": "Started a break", "stop": "Ended your focus session",
            "cancel": "Ended your focus session", "end": "Ended your focus session",
        ], reads: ["status", "check"]),
        "save_location": .init("Saved a place for you"),
        "geofence": .init("Changed your place alerts", actions: [
            "create": "Set an alert for when you reach a place",
            "delete": "Removed a place alert", "clear": "Removed your place alerts",
        ], reads: ["list"]),
        "parking": .init("Saved where you parked", actions: [
            "photo": "Saved a photo of your parking spot", "update": "Corrected where you parked",
            "directions": "Started directions back to your car",
            "clear": "Cleared your parking spot", "forget": "Cleared your parking spot",
            "found": "Cleared your parking spot",
        ], reads: ["where", "history", "list"]),
        "get_directions": .init("Opened directions for you"),
        "navigate": .init("Started navigation for you"),
        "navigation_assist": .init("Started walking guidance for you"),

        // Messages, calls and reports — these reach another person
        "send_message": .init("Sent a message for you"),
        "send_via": .init("Sent a message for you"),
        "phone_call": .init("Started a call for you"),
        "asian_messaging": .init("Opened a message for you to send"),
        "chinese_app": .init("Opened an app for you"),
        "escalate_to_expert": .init("Asked an expert to join you"),
        "deliver_report": .init("Sent a report for you"),
        "medical_export": .init("Exported your clinical data", actions: [
            "share": "Shared your clinical data",
        ], reads: ["status"]),

        // Apps, devices and the home
        "open_app": .init("Opened an app for you"),
        "play_podcast": .init("Started a podcast for you"),
        "music_control": .init("Changed what's playing", actions: [
            "play": "Started your music", "resume": "Started your music",
            "pause": "Paused your music", "stop": "Paused your music",
            "next": "Skipped to the next track", "skip": "Skipped to the next track",
            "add_to_library": "Added something to your music library",
        ], reads: ["now_playing", "current", "what_is_playing", "search", "devices"]),
        "smart_home": .init("Changed something in your home", actions: [
            "on": "Turned something on in your home", "off": "Turned something off in your home",
            "lock": "Locked a door for you", "unlock": "Unlocked a door for you",
            "scene": "Set a scene in your home",
        ], reads: ["list", "list_scenes"]),
        "home_assistant": .init("Sent a command to your home", actions: [
            "run_automation": "Ran a home automation for you",
        ], reads: ["get_state", "list_entities"]),
        "quick_action": .init("Ran a quick action for you", reads: ["list"]),
        "run_shortcut": .init("Ran a Shortcut for you"),
        "flashlight": .init("Switched the torch for you"),
        "brightness": .init("Changed your screen brightness"),
        "openclaw_skills": .init("Used a gateway skill for you"),
        "execute": .init("Gave your gateway a task"),
        "code_agent": .init("Changed a coding-agent run", actions: [
            "start": "Started a coding-agent run", "cancel": "Cancelled a coding-agent run",
            "confirm": "Approved a coding-agent step", "deny": "Declined a coding-agent step",
            "answer": "Answered a coding agent's question", "retry": "Retried a coding-agent run",
        ], reads: ["status"]),

        // Camera, recording and reading
        "capture_photo": .init("Took a photo for you"),
        "photo_log": .init("Logged a photo for you"),
        "refrigerant_gauges": .init("Read the gauges for you"),
        "audio_recording": .init("Changed an audio recording", actions: [
            "start": "Started recording audio", "stop": "Stopped recording audio",
        ], reads: ["status"]),
        "video_recording": .init("Changed a video recording", actions: [
            "start": "Started recording video", "stop": "Stopped recording video",
        ], reads: ["status"]),
        "record_clip": .init("Recorded a clip for you", actions: ["stop": "Stopped the clip"],
                             reads: ["status"]),
        "instant_replay": .init("Kept a replay for you", reads: ["status"]),
        "scan_document": .init("Scanned a document for you"),
        "smart_capture": .init("Captured what you're looking at"),
        "remember_scene": .init("Remembered a scene for you"),
        "look_closely": .init("Took a closer look with the camera"),
        "reading_assist": .init("Read what's in front of you"),
        "reading_session": .init("Started a reading session"),
        "identify_medication": .init("Checked a medication with the camera"),
        "identify_money": .init("Checked a note with the camera"),
        "live_translate": .init("Started live translation"),
        "teleprompter": .init("Changed the teleprompter"),
        "study": .init("Changed your study session"),
        "safety_assessment": .init("Ran a safety check with the camera"),
        "first_aid": .init("Started first-aid guidance"),
        "live_coach": .init("Changed live coaching"),
        "fitness_coach": .init("Updated your workout", actions: [
            "start_workout": "Started a workout", "stop_workout": "Finished your workout",
            "log_exercise": "Logged an exercise", "step_goal": "Set your step goal",
        ], reads: ["workout_history", "check_form"]),
        "golf_mode": .init("Changed golf mode"),

        // Field work: a technician's day
        "field_session": .init("Updated your job session", actions: [
            "start": "Started a job session", "set_job_reference": "Recorded the job number",
            "next_unit": "Moved on to the next unit", "pause": "Paused your job session",
            "resume": "Resumed your job session", "end": "Ended your job session",
            "escalate": "Escalated the job",
        ], reads: ["status", "list", "vaults", "recall"]),
        "parts_request": .init("Requested a part for you"),
        "van_stock": .init("Updated your van stock", actions: [
            "load": "Loaded parts onto your van", "use": "Recorded a part used from your van",
            "remove": "Took a part off your van stock", "undo": "Undid a van stock change",
            "top_up": "Topped up your van stock", "set_standard": "Set a standard van stock level",
            "send_to_base": "Sent your van stock to the office",
        ], reads: ["check", "low", "count", "unrecorded"]),
        "task": .init("Updated a job task", actions: [
            "add": "Added a task to the job", "accept": "Accepted a job task",
            "decline": "Declined a job task", "defer": "Put off a job task",
            "start": "Started a job task", "done": "Finished a job task",
            "abandon": "Dropped a job task",
        ]),
        "propose_task": .init("Suggested a task for the job"),
        "evidence": .init("Changed what goes in the work record"),
        "team_learning": .init("Saved a note for your team", actions: [
            "amend": "Changed a team note", "withdraw": "Withdrew a team note",
        ], reads: ["list"]),
        "capture_flow": .init("Recorded an answer in a checklist", actions: [
            "start": "Started a checklist", "finish": "Finished a checklist",
            "cancel": "Cancelled a checklist", "skip": "Skipped a checklist question",
        ], reads: ["list", "status"]),
        "procedure_runner": .init("Moved through a procedure", actions: [
            "start": "Started a procedure", "complete": "Finished a procedure",
        ], reads: ["list", "status", "repeat"]),
        "scan_badge": .init("Scanned a badge for you"),
        "scan_assist": .init("Changed a scan", actions: [
            "start": "Started a scan", "stop": "Finished a scan", "pause": "Paused a scan",
            "resume": "Resumed a scan",
        ], reads: ["status"]),
        "manual_capture": .init("Saved pages from a manual"),
        "manual_figure": .init("Showed a figure from a manual"),
        "manual_lookup": .init("Looked something up in a manual with the camera"),
        "equipment_lookup": .init("Identified equipment with the camera"),
        "show_source": .init("Showed you where an answer came from"),
        "table_lookup": .init("Looked up a value in a manual's table"),
        "rule_chain": .init("Worked through a rule chain", actions: [
            "start": "Started a rule chain", "answer": "Answered a rule chain's question",
            "stop": "Stopped a rule chain", "keep": "Kept a rule chain on this phone",
            "share": "Shared the kept rule chains",
        ], reads: ["list", "status"]),
        "propose_chain": .init("Proposed a rule chain", actions: [
            "change": "Changed a step of a proposed rule chain", "withdraw": "Withdrew a proposed rule chain",
        ], reads: ["show"]),
    ]
}
