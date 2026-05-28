import Foundation

/// Starts/stops a Live Coach (Plan C) session: real-time, one-sentence coaching feedback on what the
/// glasses see, for a chosen domain. The loop, dedup, and throttling live in `LiveCoachService`.
@MainActor
final class LiveCoachTool: NativeTool {
    let name = "live_coach"
    let description = """
    Real-time coaching feedback from the glasses camera. Use when the user wants ongoing guidance on \
    an activity ("coach my squat form", "watch my knife technique", "help with my guitar chords"). \
    Actions: 'start' (with a domain), 'stop', 'status'. Domains: sports_tactics, cooking_form, \
    posture, guitar, climbing, custom (needs custom_prompt). Params: interval_seconds (1–10, default 2), \
    max_words (default 20), max_duration_minutes (default 30).
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "description": "'start', 'stop', or 'status'."],
            "domain": ["type": "string", "description": "sports_tactics | cooking_form | posture | guitar | climbing | custom"],
            "custom_prompt": ["type": "string", "description": "Required when domain=custom: what to coach on."],
            "interval_seconds": ["type": "integer", "description": "Seconds between checks (1–10, default 2)."],
            "max_words": ["type": "integer", "description": "Max words per feedback (default 20)."],
            "max_duration_minutes": ["type": "integer", "description": "Auto-stop after this many minutes (default 30)."]
        ],
        "required": ["action"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String)?.lowercased() ?? "status"
        let service = LiveCoachService.shared

        switch action {
        case "start":
            guard service.isConfigured else {
                return "Live Coach isn't available — the camera or model isn't ready."
            }
            let domainRaw = (args["domain"] as? String) ?? "posture"
            guard let domain = LiveCoachDomain(rawValue: domainRaw) else {
                return "Unknown domain '\(domainRaw)'. Use sports_tactics, cooking_form, posture, guitar, climbing, or custom."
            }
            let customPrompt = args["custom_prompt"] as? String
            if domain == .custom, (customPrompt?.isEmpty ?? true) {
                return "For a custom coaching session, provide 'custom_prompt' describing what to watch for."
            }
            let interval = Double((args["interval_seconds"] as? Int) ?? 2)
            let maxWords = (args["max_words"] as? Int) ?? 20
            let maxDuration = Double((args["max_duration_minutes"] as? Int) ?? 30)

            let started = service.start(domain: domain, customPrompt: customPrompt,
                                        intervalSeconds: interval, maxWords: maxWords, maxDurationMinutes: maxDuration)
            guard started else { return "Could not start Live Coach." }
            return "Live Coach started for \(domain.rawValue.replacingOccurrences(of: "_", with: " ")). I'll give you brief feedback every \(Int(interval))s. Say 'stop coaching' to end."
        case "stop":
            service.stop()
            return "Live Coach stopped."
        case "status":
            return service.statusSummary()
        default:
            return "Unknown action '\(action)'. Use 'start', 'stop', or 'status'."
        }
    }
}
