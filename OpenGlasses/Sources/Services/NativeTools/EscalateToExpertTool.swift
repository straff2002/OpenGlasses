import Foundation

/// Native tool for the AI → human-expert escalation flow within a Field Assist session.
///
/// Phase 3 is architecture-only: requesting an expert records the escalation and pages the pool
/// (stub), but the live video bridge lands in Phase 5. The tool exposes the full state machine so
/// the conversational flow is in place now. For a quick one-shot escalation, `field_session` with
/// action 'escalate' routes through the same coordinator.
@MainActor
final class EscalateToExpertTool: NativeTool {
    let name = "escalate_to_expert"
    let description = """
    Escalate the active Field Assist session to a human expert when the AI cannot safely resolve the \
    issue or the technician asks for a person. Actions: 'request' (page an expert with a reason), \
    'status' (current escalation state), 'resolve' (the issue is handled), 'cancel' (stand down). \
    Live expert video is not available yet — escalation is logged and the expert pool is notified.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "'request', 'status', 'resolve', or 'cancel'."
            ],
            "reason": [
                "type": "string",
                "description": "On 'request': why a human expert is needed (e.g. 'readings contradict the manual flowchart')."
            ],
            "note": [
                "type": "string",
                "description": "On 'resolve': optional note about how it was resolved."
            ]
        ],
        "required": ["action"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        guard let action = (args["action"] as? String)?.lowercased() else {
            return "No action specified. Use 'request', 'status', 'resolve', or 'cancel'."
        }

        let coordinator = EscalationCoordinator.shared
        guard FieldSessionService.shared.activeSession != nil || action == "status" else {
            return "No active Field Assist session to escalate."
        }

        switch action {
        case "request", "escalate":
            let reason = (args["reason"] as? String) ?? "Technician requested a human expert."
            let state = await coordinator.requestExpert(reason: reason)
            if case .failed(let message) = state {
                return "Escalation recorded, but paging had an issue: \(message)"
            }
            return "Escalation logged and the expert pool has been notified. \(coordinator.statusSummary())"
        case "status":
            return coordinator.statusSummary()
        case "resolve":
            await coordinator.resolve(note: args["note"] as? String)
            return "Escalation resolved and logged to the session audit."
        case "cancel":
            await coordinator.cancel()
            return "Escalation cancelled."
        default:
            return "Unknown action '\(action)'. Use 'request', 'status', 'resolve', or 'cancel'."
        }
    }
}
