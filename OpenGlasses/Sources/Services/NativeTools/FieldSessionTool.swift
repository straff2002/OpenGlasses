import Foundation

/// Native tool that lets the LLM start, pause, resume, end, and query Field Assist sessions.
///
/// Sessions ground the conversation in a domain vault (refrigeration, IT, health, etc.) and
/// emit a structured audit log. See `FieldSessionService` and `VaultRegistry`.
@MainActor
final class FieldSessionTool: NativeTool {
    let name = "field_session"
    let description = """
    Start, pause, resume, end, or query a Field Assist session for grounded, domain-specific technical support \
    (refrigeration, IT, electrical, automotive). Sessions load a domain knowledge vault and emit an audit log. \
    Use 'start' when the technician begins work on equipment, 'end' when they finish.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "Action: 'start' to begin a new session, 'pause' to pause billing, 'resume' to continue, 'end' to finish, 'status' to query the active session, 'list' for history, 'escalate' to flag the session for a human expert."
            ],
            "vault": [
                "type": "string",
                "description": "Vault id when starting: 'refrigeration', 'health', etc. Defaults to the configured default vault when omitted."
            ],
            "asset_id": [
                "type": "string",
                "description": "Optional equipment/asset identifier (e.g. 'Unit 47B', 'Carrier 30RB s/n 1234')."
            ],
            "mode": [
                "type": "string",
                "description": "Session mode: 'ai_only' (default) or 'human_assisted' (requires expert escalation infra; reserved)."
            ],
            "outcome": [
                "type": "string",
                "description": "On 'end': 'resolved' (default), 'escalated', 'deferred', or 'cancelled'."
            ],
            "reason": [
                "type": "string",
                "description": "On 'escalate': human-readable reason for the escalation."
            ]
        ],
        "required": ["action"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let action = (args["action"] as? String)?.lowercased() else {
            return "No action specified. Use 'start', 'pause', 'resume', 'end', 'status', 'list', or 'escalate'."
        }

        let service = FieldSessionService.shared

        switch action {
        case "start":
            return await startSession(args: args, service: service)
        case "pause":
            return await pauseSession(service: service)
        case "resume":
            return await resumeSession(service: service)
        case "end":
            return await endSession(args: args, service: service)
        case "status":
            return await statusSummary(service: service)
        case "list":
            return await historySummary(service: service)
        case "escalate":
            return await escalate(args: args, service: service)
        default:
            return "Unknown action '\(action)'. Use 'start', 'pause', 'resume', 'end', 'status', 'list', or 'escalate'."
        }
    }

    // MARK: - Actions

    private func startSession(args: [String: Any], service: FieldSessionService) async -> String {
        guard Config.fieldAssistEnabled else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist before starting a session."
        }

        let vaultId = (args["vault"] as? String) ?? Config.fieldAssistDefaultVaultId
        let assetId = args["asset_id"] as? String
        let modeRaw = (args["mode"] as? String) ?? Config.fieldAssistDefaultMode
        let mode = FieldSession.Mode(rawValue: modeRaw) ?? .aiOnly

        do {
            let session = try service.startSession(vaultId: vaultId, assetId: assetId, mode: mode)
            let vaultName = VaultRegistry.shared.manifest(id: vaultId)?.name ?? vaultId
            let asset = assetId.map { " on \($0)" } ?? ""
            let modeLabel = mode == .aiOnly ? "AI-only" : "human-assisted"
            return "Started \(modeLabel) Field Assist session against the \(vaultName) vault\(asset). Session id: \(session.id.prefix(8))."
        } catch {
            return "Could not start session: \(error.localizedDescription)"
        }
    }

    private func pauseSession(service: FieldSessionService) async -> String {
        do {
            _ = try service.pauseSession()
            return "Session paused. Billing stopped."
        } catch {
            return "Could not pause: \(error.localizedDescription)"
        }
    }

    private func resumeSession(service: FieldSessionService) async -> String {
        do {
            _ = try service.resumeSession()
            return "Session resumed."
        } catch {
            return "Could not resume: \(error.localizedDescription)"
        }
    }

    private func endSession(args: [String: Any], service: FieldSessionService) async -> String {
        let outcomeRaw = (args["outcome"] as? String) ?? "resolved"
        let outcome = FieldSession.Outcome(rawValue: outcomeRaw) ?? .resolved
        do {
            let session = try service.endSession(outcome: outcome)
            let minutes = Int((session.billableSeconds / 60.0).rounded())
            return "Session ended with outcome '\(outcome.rawValue)'. Billable time: \(minutes) min. Audit log saved."
        } catch {
            return "Could not end session: \(error.localizedDescription)"
        }
    }

    private func statusSummary(service: FieldSessionService) async -> String {
        guard let session = service.activeSession else {
            return "No active Field Assist session."
        }
        let vaultName = VaultRegistry.shared.manifest(id: session.vaultId)?.name ?? session.vaultId
        let runningFor = Int(Date().timeIntervalSince(session.startedAt))
        let mins = runningFor / 60
        let asset = session.assetId.map { ", asset \($0)" } ?? ""
        let pause = session.pausedAt != nil ? " [paused]" : ""
        return "Active session: \(vaultName)\(asset). Running ~\(mins) min, \(session.escalations.count) escalation(s).\(pause)"
    }

    private func historySummary(service: FieldSessionService) async -> String {
        let recent = service.history.prefix(5)
        if recent.isEmpty { return "No prior Field Assist sessions." }
        let lines = recent.map { session -> String in
            let vault = VaultRegistry.shared.manifest(id: session.vaultId)?.name ?? session.vaultId
            let date = DateFormatter.localizedString(from: session.startedAt, dateStyle: .short, timeStyle: .short)
            let minutes = Int((session.billableSeconds / 60.0).rounded())
            return "• \(date) — \(vault), \(session.outcome.rawValue), \(minutes) min"
        }
        return "Recent sessions:\n\(lines.joined(separator: "\n"))"
    }

    private func escalate(args: [String: Any], service: FieldSessionService) async -> String {
        guard service.activeSession != nil else {
            return "No active session to escalate."
        }
        let reason = (args["reason"] as? String) ?? "Technician requested human expert."
        service.recordEscalation(reason: reason)
        // Human-assisted bridge is Phase 5; for now we record + acknowledge.
        return "Escalation logged. A human expert will be paged. Reason: \(reason)"
    }
}
