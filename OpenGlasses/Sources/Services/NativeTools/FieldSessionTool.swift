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
    Start, pause, resume, end, update, or query a Field Assist session for grounded, domain-specific technical support \
    including installed custom vaults. Sessions load a knowledge vault and emit an audit log. \
    Use 'start' when the technician begins work on equipment, 'set_job_reference' whenever the \
    technician gives or corrects a job/work-order number, and 'end' when they finish. Only confirm \
    that a job reference was recorded after this tool action succeeds. \
    Use 'recall' to retrieve older technician reports, readings and task results for the current \
    equipment when they are absent from the working context. Reports are not independently \
    verified. Read subsequent records for corrections; paginate until the relevant record is complete. \
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
                "description": "Action: 'start' to begin a new session, 'set_job_reference' to record or correct its job/work-order number, 'pause' to pause billing, 'resume' to continue, 'end' to finish, 'status' to query the active session, 'list' for history, 'recall' for older current-equipment records, 'vaults' for installed vault IDs/names and the configured default, 'escalate' to flag the session for a human expert, 'export' to produce a work-order PDF + audit JSON."
            ],
            "format": [
                "type": "string",
                "description": "On 'export': 'pdf', 'json', or 'both' (default). 'pdf' is the customer-facing work order; 'json' is the structured audit record."
            ],
            "query": [
                "type": "string",
                "description": "On recall: phrase or source ID to find. Empty retrieves all current-equipment records chronologically."
            ],
            "offset": [
                "type": "integer",
                "description": "On recall: character offset from the previous page's continuation, default 0. Keep the same query."
            ],
            "vault": [
                "type": "string",
                "description": "Installed vault ID or full display name when starting. Omit or use 'default' for the configured default. Use action 'vaults' to discover choices; do not guess a generic domain instead of a custom vault."
            ],
            "asset_id": [
                "type": "string",
                "description": "Optional equipment/asset identifier (e.g. 'Unit 47B', 'Carrier 30RB s/n 1234')."
            ],
            "job_reference": [
                "type": "string",
                "description": "Required on 'set_job_reference': the technician's exact job or work-order number. Do not invent or normalize it."
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
            return "No action specified. Use 'start', 'pause', 'resume', 'end', 'status', 'list', 'recall', 'vaults', 'escalate', or 'export'."
        }

        let service = sessionService ?? FieldSessionService.shared

        switch action {
        case "vaults":
            return vaultSummary()
        case "recall":
            return service.recallContinuity(query: args["query"] as? String, offset: args["offset"] as? Int ?? 0)
        case "start":
            return await startSession(args: args, service: service)
        case "set_job_reference":
            return setJobReference(args: args, service: service)
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
            return "Unknown action '\(action)'. Use 'start', 'set_job_reference', 'pause', 'resume', 'end', 'status', 'list', 'recall', 'vaults', 'escalate', or 'export'."
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

    private func setJobReference(args: [String: Any], service: FieldSessionService) -> String {
        guard service.activeSession != nil else {
            return "Could not record job reference: no Field Assist session is active."
        }
        guard let supplied = args["job_reference"] as? String else {
            return "Could not record job reference: job_reference must be the technician's exact job or work-order number."
        }
        let reference = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else {
            return "Could not record job reference: job_reference cannot be empty."
        }
        service.setJobReference(reference)
        guard service.activeSession?.jobReference == reference else {
            return "Could not record job reference."
        }
        return "Job reference \(reference) is recorded for this active session and will be included in its submitted record."
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
            let billing = WorkRecord.billingSummary(
                seconds: session.billableSeconds, basis: session.billingBasis,
                minutesPerUnit: session.minutesPerBillingUnit)
            return "Session ended. Status: \(outcome.displayName). Billable time: \(billing). Audit log saved."
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
        return "Active session: \(vaultName) [\(session.vaultId)]\(asset). Running about \(WorkRecord.minutesPhrase(minutes: mins)), \(session.escalations.count) escalation(s).\(pause)\n" + vaultSummary()
    }

    private func historySummary(service: FieldSessionService) async -> String {
        let recent = service.history.prefix(5)
        if recent.isEmpty { return "No prior Field Assist sessions." }
        let lines = recent.map { session -> String in
            let vault = VaultRegistry.shared.manifest(id: session.vaultId)?.name ?? session.vaultId
            let date = DateFormatter.localizedString(from: session.startedAt, dateStyle: .short, timeStyle: .short)
            let billing = WorkRecord.billingSummary(
                seconds: session.billableSeconds, basis: session.billingBasis,
                minutesPerUnit: session.minutesPerBillingUnit)
            return "• \(date) — \(vault), \(session.outcome.displayName), \(billing)"
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
