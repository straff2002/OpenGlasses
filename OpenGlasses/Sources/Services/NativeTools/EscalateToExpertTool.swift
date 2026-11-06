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
    Page or call a human expert for the active Field Assist session when the technician asks for a person, or \
    says yes to your offer of one. A manual search that found nothing is not a reason to page: name \
    what the manuals do not cover and offer an expert, and if something looks unsafe, say so and \
    offer one. Actions: 'request' (ask for an expert, with a reason and any specialty said, e.g. \
    'furnace'), 'call' (call a named expert: when the technician names one, 'call Sam', or says yes \
    to the one offered), 'status' (current escalation state), 'resolve' (the issue is handled), \
    'cancel' (stand down). When the phone lists named experts, 'request' calls nobody: it returns one \
    sentence offering the best match by fixed rules; say it as written, and on a yes use 'call' with \
    that expert_name. 'call' starts the call and the phone asks the technician to tap Call; never say \
    it connected. With no experts listed, 'request' logs the escalation and notifies the expert pool; \
    if the organisation has set up a live-view relay, the technician's camera view is shared with the \
    expert. The 'request' result says which happened — don't promise live video beyond it.
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
            ],
            "specialty": [
                "type": "string",
                "description": "On 'request' or 'call' without a name: the kind of expert asked for, as said (e.g. 'furnace', 'heat pump', 'Lennox')."
            ],
            "expert_name": [
                "type": "string",
                "description": "On 'call': the expert's name as the technician said it or as the offer named them (e.g. 'Sam')."
            ],
            "via": [
                "type": "string",
                "description": "On 'call': 'phone' (default), 'facetime' or 'facetime_audio'."
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
        case "escalate_to_expert": return action == "request" || action == "escalate" || action == "call"
        case "field_session": return action == "escalate"
        default: return false
        }
    }

    /// The refusal for a call that pages a person, or nil when it may go on: the words ask for one,
    /// or are a short yes to an offer of one. A turn with no captured words (an agent-initiated turn
    /// or a live session) is not gated, as `TechnicianWords` documents. Checked by the router before
    /// the approval card, so a page nobody asked for puts no card in front of the technician. Pure.
    ///
    /// A call to a named expert (Plan KM P0) also goes on when the words call that expert by name
    /// ("call Sam", "try Priya") or are a short yes to a question that named them ("… Call Sam?").
    nonisolated static func refusal(said: String?, previousReply: String?, expertName: String? = nil) -> String? {
        guard let said else { return nil }
        if TechnicianRequest.asksForExpert(said)
            || TechnicianRequest.confirmsExpertOffer(said, previousReply: previousReply) { return nil }
        if let expertName,
           TechnicianRequest.asksToCall(name: expertName, said)
            || TechnicianRequest.confirmsCallOffer(name: expertName, said, previousReply: previousReply) {
            return nil
        }
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
        guard coordinator.sessionService.activeSession != nil || action == "status" else {
            return "No active Field Assist session to escalate."
        }

        switch action {
        case "request", "escalate":
            let reason = (args["reason"] as? String) ?? "Technician requested a human expert."
            if coordinator.hasNamedExperts {
                return offer(args: args, coordinator: coordinator)
            }
            let state = await coordinator.requestExpert(reason: reason)
            if case .failed(let message) = state {
                return "Escalation recorded, but paging had an issue: \(message)"
            }
            return "Escalation logged and the expert pool has been notified. \(coordinator.liveViewSummary()) \(coordinator.statusSummary())"
        case "call":
            return await call(args: args, coordinator: coordinator)
        case "status":
            if let offer = coordinator.noAnswerOffer { return "\(coordinator.statusSummary()) \(offer)" }
            return coordinator.statusSummary()
        case "resolve":
            await coordinator.resolve(note: args["note"] as? String)
            return "Escalation resolved and logged to the session audit."
        case "cancel":
            await coordinator.cancel()
            return "Escalation cancelled."
        default:
            return "Unknown action '\(action)'. Use 'request', 'call', 'status', 'resolve', or 'cancel'."
        }
    }

    // MARK: - Named experts (Plan KM P0)

    /// What the request names, for the picker: the specialty the model passed, then its reason.
    private static func requestWords(_ args: [String: Any]) -> String {
        [args["specialty"] as? String, args["reason"] as? String].compactMap { $0 }.joined(separator: " ")
    }

    private func job(_ coordinator: EscalationCoordinator) -> ExpertPicker.Job {
        let session = coordinator.sessionService.activeSession
        return .from(session: session, vault: session.flatMap { VaultRegistry.shared.manifest(id: $0.vaultId) })
    }

    /// "Get me a furnace expert", with experts listed: one sentence offering the best match. Calls
    /// nobody and records nothing — the offer is a question.
    private func offer(args: [String: Any], coordinator: EscalationCoordinator) -> String {
        guard FieldAssistEntitlement.shared.has(.fieldWork) else { return "Field Assist isn't unlocked on this device." }
        guard let pick = coordinator.offerExpert(request: Self.requestWords(args), job: job(coordinator)),
              let offered = pick.offered else {
            return "No experts are listed on this phone."
        }
        let others = pick.ordered.dropFirst().prefix(3).map { candidate in
            "\(candidate.contact.name)\(candidate.isOnCall ? "" : " (not on call)")"
        }
        let rest = others.isEmpty ? "" : " Next in turn: \(others.joined(separator: ", "))."
        return "\(pick.sentence) Nobody has been called yet. On a yes, use 'call' with expert_name '\(offered.name)'.\(rest)"
    }

    /// "Call Sam", or a yes to the offer. By name always works and skips the picker; without a
    /// name the picker's first choice is called.
    private func call(args: [String: Any], coordinator: EscalationCoordinator) async -> String {
        let experts = coordinator.expertList.contacts
        guard !experts.isEmpty else {
            return "No experts are listed in Settings → Field Assist → Experts. Use 'request' to notify the expert pool, or phone_call for someone in Contacts."
        }
        let contact: EscalationContact
        if let name = (args["expert_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            switch ExpertNameMatch.resolve(name, in: experts) {
            case .one(let match):
                contact = match
            case .several(let matches):
                return "More than one expert matches '\(name)': \(matches.map(\.name).joined(separator: ", ")). Ask which one."
            case .none:
                return "Nobody called '\(name)' is on the Experts list. For someone in Contacts, use phone_call."
            }
        } else if let next = coordinator.callMonitor.noAnswerNext {
            contact = next
        } else if let offered = coordinator.offerExpert(request: Self.requestWords(args), job: job(coordinator))?.offered {
            contact = offered
        } else {
            return "No experts are listed on this phone."
        }
        let via = CallVia(spoken: args["via"] as? String) ?? CallRoute.defaultVia(for: contact)
        let reason = (args["reason"] as? String) ?? "Called \(contact.name)"
        switch await coordinator.callExpert(contact, via: via, reason: reason) {
        case .refused(let message):
            return message
        case .placed(let called, let via):
            let name = ExpertPicker.spokenName(called, among: experts)
            let how = via == .phone ? "Calling \(name)." : "Starting a FaceTime call to \(name)."
            return "\(how) Your phone will ask you to tap Call."
        }
    }
}
