import CryptoKit
import Foundation

/// The field-mode tool profile (Plan GD3): during a Field Assist job, only the tools a job uses are
/// offered to the model.
///
/// About 120 native tools exist, and every request carried all of their schemas — roughly 10k
/// tokens a turn the field tester's jobs never used (Plan GB's cost table, rank 4). This is one
/// fixed allowlist: the job's own tools plus the general essentials a technician reaches for on
/// site. It is applied where every provider's declarations are filtered
/// (`ToolDeclarations.declarableNames`) **and** to the prompt's tool list, so a tool is either
/// declared and listed or neither. HIPAA filtering still runs first; the profile only narrows.
///
/// On by default during a job; `Config.fieldToolProfileEnabled` (the Developer panel) turns it off.
enum FieldToolProfile {

    /// The tools a field job is offered — the job's tools, then the essentials.
    static let names: Set<String> = [
        "field_session", "manual_lookup", "manual_figure", "equipment_lookup", "procedure_runner",
        "reading", "evidence", "parts_request", "deliver_report", "escalate_to_expert", "team_learning",
        "capture_photo", "record_clip", "photo_log", "pin_frame", "smart_capture", "vision_assess",
        "look_closely", "scan_document", "scan_code", "scan_badge", "qr_context", "domain_calc",
        "convert_units", "calculate", "capture_flow", "safety_assessment", "first_aid",
        "emergency_info", "task", "propose_task", "reminder", "set_timer", "save_note", "list_notes",
        "session_search", "summarize_conversation", "new_topic", "yield_to_human",
        "discover_capabilities", "get_datetime", "get_weather", "where_am_i", "navigate",
        "get_directions", "find_nearby", "phone_call", "lookup_contact", "send_message",
        "web_search", "flashlight", "device_info", "teleprompter", "playbook",
    ]

    /// The names to declare and list. `all` unchanged unless a job is open **and** the profile is
    /// on; then the sorted intersection with `names`. Pure.
    static func declaredNames(all: [String], fieldJobActive: Bool, enabled: Bool) -> [String] {
        guard fieldJobActive && enabled else { return all }
        return all.filter(names.contains).sorted()
    }

    /// Whether a Field Assist job is open right now — a paused one included, since it is still the
    /// job.
    @MainActor
    static var fieldJobActive: Bool { FieldSessionService.shared.activeSession != nil }

    /// `declaredNames` with the app's own flags, for the prompt's tool list.
    @MainActor
    static func current(_ all: [String]) -> [String] {
        let enabled = Config.fieldToolProfileEnabled
        return declaredNames(all: all, fieldJobActive: enabled && fieldJobActive, enabled: enabled)
    }

    /// A short, stable digest of a declared list — what the log records instead of the names.
    static func digest(_ names: [String]) -> String {
        let hash = SHA256.hash(data: Data(names.sorted().joined(separator: ",").utf8))
        return hash.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
