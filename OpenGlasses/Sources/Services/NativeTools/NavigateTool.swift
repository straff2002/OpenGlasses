import Foundation

/// Plan CA — hands-free walking directions: "navigate to Blue Bottle Coffee", "stop
/// navigation", "how far to go?". Thin voice adapter over `WalkingRouteService` (resolved via
/// `AppStateProvider` at execution time — the service is per-app-state).
struct NavigateTool: NativeTool {
    let name = "navigate"
    let description = """
        Start turn-by-turn WALKING directions to a place — each turn appears on the glasses \
        display and is spoken at the right moment. Use for "navigate to / take me to / walk me \
        to / directions to <place>". Actions: 'start' (requires destination), 'stop', 'status' \
        (remaining distance). Walking only; driving belongs to CarPlay.
        """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "Action: 'start' (default), 'stop', or 'status'."
            ],
            "destination": [
                "type": "string",
                "description": "Where to walk to — a place name or address (required for 'start')."
            ]
        ],
        "required": [] as [String]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let appState = AppStateProvider.shared else {
            return "Navigation isn't available right now."
        }
        let action = (args["action"] as? String ?? "start").lowercased()

        switch action {
        case "stop", "cancel", "end":
            guard appState.walkingRoute.state != .idle else { return "Navigation isn't running." }
            appState.walkingRoute.stop(announce: false)
            return "Navigation stopped."
        case "status", "eta", "remaining":
            return appState.walkingRoute.statusSummary()
        default:
            guard let destination = (args["destination"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !destination.isEmpty else {
                return "Where to? Give me a destination."
            }
            do {
                return try await appState.walkingRoute.start(destination: destination)
            } catch {
                return error.localizedDescription
            }
        }
    }
}
