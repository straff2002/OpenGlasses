import Foundation

/// Which native tools still work when the conversation is on the phone without signal (Plan GE P0).
///
/// Every registered native tool is classified here. `OfflineToolPolicyTests` scrapes the tool
/// sources and walks a headless `NativeToolRegistry`, and fails on any tool missing from the table,
/// so a new tool cannot silently land in the offline set — it has to be placed deliberately.
///
/// On the phone only ``Availability/local`` and ``Availability/degraded`` tools are offered to the
/// model. Anything not in the table — MCP tools, agent-gateway tools, skill-pack gateway bindings —
/// is never offered offline: they live on the other side of the network by definition.
enum OfflineToolPolicy {

    enum Availability: String, Equatable, Sendable {
        /// Works entirely on the phone.
        case local
        /// Works, but thinner without signal (an address becomes coordinates, a translation is done
        /// by the smaller on-device model, streaming music is unavailable).
        case degraded
        /// Needs the network to do anything useful.
        case needsNetwork
    }

    /// The classification, by tool name.
    static let table: [String: Availability] = [
        // Local — the phone does the whole job.
        "agent_diary": .local,
        "audio_recording": .local,
        "brain": .local,
        "brightness": .local,
        "calculate": .local,
        "calendar": .local,
        "capture_flow": .local,
        "contextual_note": .local,
        "convert_units": .local,
        "copy_to_clipboard": .local,
        "define_word": .local,
        "device_info": .local,
        "discover_capabilities": .local,
        "document_knowledge": .local,
        "domain_calc": .local,
        "edit_agent_docs": .local,
        "emergency_info": .local,
        "equipment_lookup": .local,
        "evidence": .local,
        "face_recognition": .local,
        "field_session": .local,
        "first_aid": .local,
        "fitness_coach": .local,
        "flashlight": .local,
        "geofence": .local,
        "get_datetime": .local,
        "health_check": .local,
        "health_summary": .local,
        "health_vault": .local,
        "list_notes": .local,
        "list_saved_locations": .local,
        "lookup_contact": .local,
        "manage_schedule": .local,
        "manual_figure": .local,
        "manual_lookup": .local,
        "memory_search": .local,
        "my_memory": .local,
        "network_calc": .local,
        "new_topic": .local,
        "notes_vault": .local,
        "object_memory": .local,
        "open_app": .local,
        "parking": .local,
        "photo_log": .local,
        "pin_frame": .local,
        "pomodoro": .local,
        "procedure_runner": .local,
        "processing_summary": .local,
        "project_note": .local,
        "propose_task": .local,
        "quick_action": .local,
        "reading": .local,
        "reading_session": .local,
        "record_clip": .local,
        "reminder": .local,
        "save_location": .local,
        "save_note": .local,
        "scan_badge": .local,
        "scan_code": .local,
        "scan_document": .local,
        "session_search": .local,
        "set_alarm": .local,
        "set_timer": .local,
        "social_context": .local,
        "step_count": .local,
        "study": .local,
        "task": .local,
        "teleprompter": .local,
        "video_recording": .local,
        "voice_skills": .local,
        "yield_to_human": .local,

        // Degraded — useful offline, but less than with signal.
        "ask_local_phrase": .degraded,     // the smaller on-device model does the translating
        "capture_photo": .degraded,        // captures fine; seeing it needs a vision model
        "daily_briefing": .degraded,       // calendar and reminders, no weather
        "golf_mode": .degraded,
        "identify_color": .degraded,
        "live_translate": .degraded,
        "look_closely": .degraded,
        "meeting_summary": .degraded,
        "memory_rewind": .degraded,
        "music_control": .degraded,        // downloaded music only
        "parts_request": .degraded,        // recorded now, sent when the technician sends it
        "phone_call": .degraded,           // no signal may mean no calls either
        "playbook": .degraded,             // HTTP steps wait for the network
        "qr_context": .degraded,           // scans; remote context needs the network
        "reading_assist": .degraded,
        "run_shortcut": .degraded,
        "scan_assist": .degraded,
        "send_message": .degraded,         // the composer opens; delivery waits for signal
        "smart_capture": .degraded,
        "smart_home": .degraded,           // HomeKit on the home network only
        "summarize_conversation": .degraded,
        "translate": .degraded,
        "translate_sign_menu": .degraded,
        "where_am_i": .degraded,           // coordinates, no street address

        // Needs the network.
        "aircraft_overhead": .needsNetwork,
        "analyze_food": .needsNetwork,     // needs a photo and a vision model
        "asian_messaging": .needsNetwork,
        "chinese_app": .needsNetwork,
        "code_agent": .needsNetwork,
        "convert_currency": .needsNetwork,
        "deliver_report": .needsNetwork,
        "escalate_to_expert": .needsNetwork,
        "find_nearby": .needsNetwork,
        "get_directions": .needsNetwork,
        "get_news": .needsNetwork,
        "get_weather": .needsNetwork,
        "home_assistant": .needsNetwork,
        "identify_medication": .needsNetwork,
        "identify_money": .needsNetwork,
        "identify_song": .needsNetwork,
        "live_coach": .needsNetwork,
        "medical_export": .needsNetwork,
        "navigate": .needsNetwork,
        "navigation_assist": .needsNetwork,
        "openclaw_skills": .needsNetwork,
        "safety_assessment": .needsNetwork,
        "send_via": .needsNetwork,
        "vehicle_status": .needsNetwork,
        "vision_assess": .needsNetwork,
        "web_search": .needsNetwork,
    ]

    /// The classification for a tool, or nil when it is not in the table.
    static func availability(of name: String) -> Availability? { table[name] }

    /// Whether the tool may be offered while the conversation is on the phone. Unclassified names —
    /// MCP, gateway and skill-pack tools among them — are never offered.
    static func isOfferedOffline(_ name: String) -> Bool {
        switch table[name] {
        case .local, .degraded: return true
        case .needsNetwork, .none: return false
        }
    }

    /// `names` narrowed to what may be offered on the phone, order kept.
    static func offlineNames(_ names: [String]) -> [String] {
        names.filter(isOfferedOffline)
    }
}
