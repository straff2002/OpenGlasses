import Foundation

/// Native tool that lets the LLM start, pause, resume, end, and query Field Assist sessions.
///
/// Sessions ground the conversation in a domain vault (refrigeration, IT, health, etc.) and
/// emit a structured audit log. See `FieldSessionService` and `VaultRegistry`.
@MainActor
final class FieldSessionTool: NativeTool {
    private let sessionService: FieldSessionService?

    init(service: FieldSessionService? = nil) {
        sessionService = service
    }

    let name = "field_session"
    let description = """
    Start, pause, resume, end, or query a Field Assist session for grounded, domain-specific technical support \
    including installed custom vaults. Sessions load a knowledge vault and emit an audit log. \
    Use 'start' when the technician begins work on equipment, 'end' when they finish. \
    For the user's default vault, omit vault or use 'default'. Use 'vaults' to discover installed \
    vault IDs, names and the configured default. Never substitute another vault after a failure \
    without the user's choice. An equipment/asset name does not select its knowledge vault. \
    The default applies to new jobs only; an active job keeps its vault until ended.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "Action: 'start' to begin a new session, 'pause' to pause billing, 'resume' to continue, 'end' to finish, 'status' to query the active session, 'list' for history, 'vaults' for installed vault IDs/names and the configured default, 'escalate' to flag the session for a human expert, 'export' to produce a work-order PDF + audit JSON."
            ],
            "format": [
                "type": "string",
                "description": "On 'export': 'pdf', 'json', or 'both' (default). 'pdf' is the customer-facing work order; 'json' is the structured audit record."
            ],
            "vault": [
                "type": "string",
                "description": "Installed vault ID or full display name when starting. Omit or use 'default' for the configured default. Use action 'vaults' to discover choices; do not guess a generic domain instead of a custom vault."
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
        guard AIFeatureGate.isEnabled(.fieldAssist) else {
            return AIFeatureGate.disabledMessage(.fieldAssist)
        }
        guard let action = (args["action"] as? String)?.lowercased() else {
            return "No action specified. Use 'start', 'pause', 'resume', 'end', 'status', 'list', or 'escalate'."
        }

        let service = sessionService ?? FieldSessionService.shared

        switch action {
        case "vaults":
            return vaultSummary()
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
        case "export":
            return await exportSession(args: args, service: service)
        default:
            return "Unknown action '\(action)'. Use 'start', 'pause', 'resume', 'end', 'status', 'list', 'escalate', or 'export'."
        }
    }

    // MARK: - Actions

    private func startSession(args: [String: Any], service: FieldSessionService) async -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist before starting a session."
        }

        if let value = args["vault"], !(value is String), !(value is NSNull) {
            return "Could not start session: vault must be an installed ID, name, or 'default'. No session was changed."
        }
        let vaultId: String
        do {
            vaultId = try VaultSelection.resolve(args["vault"] as? String,
                                                 defaultId: Config.fieldAssistDefaultVaultId,
                                                 manifests: VaultRegistry.shared.allManifests)
        } catch {
            return "Could not start session: \(error.localizedDescription) No session was changed. \(vaultSummary()) Do not substitute another vault; ask the user to choose."
        }
        if let active = service.activeSession {
            let name = VaultRegistry.shared.manifest(id: active.vaultId)?.name ?? active.vaultId
            return "No new session was started. The active job uses \(name) [\(active.vaultId)]. The requested vault is [\(vaultId)]. Changing the default does not change an active job. Ask the user whether to finish the current job before starting another; do not end it automatically."
        }
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

    private func vaultSummary() -> String {
        let registry = VaultRegistry.shared
        let defaultId = Config.fieldAssistDefaultVaultId
        let defaultName = registry.manifest(id: defaultId)?.name ?? "Unavailable"
        let choices = registry.allManifests.map { manifest in
            "• \(manifest.name) [\(manifest.id)]" + (registry.isUnlocked(manifest) ? "" : " (locked)")
        }
        return "Configured default for new jobs: \(defaultName) [\(defaultId)]. Installed vaults:\n" + choices.joined(separator: "\n")
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
            return "No active Field Assist session. " + vaultSummary()
        }
        let vaultName = VaultRegistry.shared.manifest(id: session.vaultId)?.name ?? session.vaultId
        let runningFor = Int(Date().timeIntervalSince(session.startedAt))
        let mins = runningFor / 60
        let asset = session.assetId.map { ", asset \($0)" } ?? ""
        let pause = session.pausedAt != nil ? " [paused]" : ""
        return "Active session: \(vaultName) [\(session.vaultId)]\(asset). Running ~\(mins) min, \(session.escalations.count) escalation(s).\(pause)\n" + vaultSummary()
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
        // Route through the EscalationCoordinator so the state machine + audit logging stay in one
        // place. The live expert bridge is Phase 5; for now this records + notifies (stub).
        _ = await EscalationCoordinator.shared.requestExpert(reason: reason)
        return "Escalation logged. The expert pool has been notified. Reason: \(reason)"
    }

    private func exportSession(args: [String: Any], service: FieldSessionService) async -> String {
        let formats: Set<SessionExporter.Format>
        switch (args["format"] as? String)?.lowercased() {
        case "pdf": formats = [.pdf]
        case "json": formats = [.json]
        default: formats = [.json, .pdf]
        }
        do {
            let leases = try service.exportSession(formats: formats)
            if leases.isEmpty { return "Nothing to export — no session found." }
            let names = leases.map(\.displayName).joined(separator: ", ")
            return "Exported session record: \(names). Held in protected storage for up to an hour so you can share it; the session log itself stays on the device and can be re-exported any time."
        } catch {
            return "Could not export: \(error.localizedDescription)"
        }
    }
}
