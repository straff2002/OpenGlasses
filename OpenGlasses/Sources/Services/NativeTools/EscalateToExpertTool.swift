import Foundation

/// Native tool for the AI → human-expert escalation flow within a Field Assist session.
///
/// Requesting an expert records the escalation, starts the live view when the organisation has set
/// up a transport (Settings → Field Assist; the app ships no relay), and pages the pool. The
/// 'request' result says whether the live view came up, so the model never promises video it can't
/// see. For a quick one-shot escalation, `field_session` with action 'escalate' routes through the
/// same coordinator.
@MainActor
final class EscalateToExpertTool: NativeTool {
    let name = "escalate_to_expert"
    let description = """
    Page a human expert for the active Field Assist session when the technician asks for a person, or \
    says yes to your offer of one. A manual search that found nothing is not a reason to page: name \
    what the manuals do not cover and offer an expert, and if something looks unsafe, say so and \
    offer one. Actions: 'request' (page an expert with a reason), \
    'status' (current escalation state), 'resolve' (the issue is handled), 'cancel' (stand down). \
    If the organisation has set up a live-view relay, the technician's camera view is shared with the \
    expert; otherwise the escalation is logged and the expert pool is notified with the job record. \
    The 'request' result says which happened — don't promise live video beyond it.
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

    // MARK: - Who asked (Plan KE P1)

    /// What a turn that asked for nobody is told instead of a page. The model asked for an expert
    /// on a retrieval miss in six replays of six, the technician cancelled the card, and the
    /// diagnosis stopped there.
    nonisolated static let notRequested = "Not requested: name what the manuals do not cover and offer an expert."

    /// Whether this call pages a person: this tool's `request`, or `field_session` `escalate`, the
    /// same coordinator by another door. The rest of this tool reports or stands down.
    nonisolated static func pagesAnExpert(tool: String, args: [String: Any]) -> Bool {
        let action = (args["action"] as? String)?.lowercased()
        switch tool {
        case "escalate_to_expert": return action == "request" || action == "escalate"
        case "field_session": return action == "escalate"
        default: return false
        }
    }

    /// The refusal for a call that pages a person, or nil when it may go on: the words ask for one,
    /// or are a short yes to an offer of one. A turn with no captured words (an agent-initiated turn
    /// or a live session) is not gated, as `TechnicianWords` documents. Checked by the router before
    /// the approval card, so a page nobody asked for puts no card in front of the technician. Pure.
    nonisolated static func refusal(said: String?, previousReply: String?) -> String? {
        guard let said else { return nil }
        if TechnicianRequest.asksForExpert(said)
            || TechnicianRequest.confirmsExpertOffer(said, previousReply: previousReply) { return nil }
        return notRequested
    }

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
            return "Escalation logged and the expert pool has been notified. \(coordinator.liveViewSummary()) \(coordinator.statusSummary())"
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
