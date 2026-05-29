import Foundation

/// Starts/stops Low-Vision Navigation Assist (Plan J): spoken hazard/landmark guidance while walking.
/// Gated by the Accessibility tier. The loop lives in `NavigationAssistService` (deps configured by
/// AppState).
@MainActor
final class NavigationAssistTool: NativeTool {
    let name = "navigation_assist"
    let description = """
    Spoken walking guidance for low-vision users: periodically describes hazards and landmarks \
    (steps, drop-offs, doors, obstacles, oncoming people) using clock positions. Actions: 'start', \
    'stop', 'status'. Use for "guide me", "navigation mode", "help me walk". This is an assistive \
    aid, not a replacement for a cane or guide dog.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "description": "'start', 'stop', or 'status'."]
        ],
        "required": ["action"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard Config.accessibilityModeEnabled else {
            return "Navigation Assist is part of the Accessibility tier — enable it in Settings → Accessibility."
        }
        let action = (args["action"] as? String)?.lowercased() ?? "status"
        let service = NavigationAssistService.shared

        switch action {
        case "start":
            guard service.isConfigured else {
                return "Navigation Assist isn't available — the camera or model isn't ready."
            }
            guard service.start() else { return "Could not start Navigation Assist." }
            return "Navigation Assist on. I'll call out hazards and landmarks as you walk. This is an aid, not a replacement for your cane or guide dog. Say 'stop' to end."
        case "stop":
            service.stop()
            return "Navigation Assist off."
        case "status":
            return service.isActive ? "Navigation Assist is running." : "Navigation Assist is off."
        default:
            return "Unknown action '\(action)'. Use 'start', 'stop', or 'status'."
        }
    }
}
