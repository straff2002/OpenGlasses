import Foundation

/// Native tool that lets the LLM start, pause, resume, end, and query Field Assist sessions.
///
/// Sessions ground the conversation in a domain vault (refrigeration, IT, health, etc.) and
/// emit a structured audit log. See `FieldSessionService` and `VaultRegistry`.
@MainActor
final class FieldSessionTool: NativeTool {
    private let sessionService: FieldSessionService?
    /// The guided job flow, when the app has one (Plan FO P1). Starting and closing a job go
    /// through it so the thread binding, the job-number intake and the audit trail happen
    /// identically however the job was started — tool call, quick action, or (P2) the Job tab.
    /// Nil in headless contexts, where the service call alone is the whole behaviour.
    private let flow: GuidedJobFlow?

    init(service: FieldSessionService? = nil, flow: GuidedJobFlow? = nil) {
        sessionService = service
        self.flow = flow
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
    The default applies to new jobs only; an active job keeps its vault until ended. \
    Jobs ahead: 'add_upcoming_job' records a job the technician describes before going there \
    ("next job: 1007, no heat, Smith Street") — pass only the fields they actually said, word for \
    word, and never fill one in; 'brief_next_job' has the app read the cited brief aloud; \
    'brief_more' reads one section of it in full. For directions to it, use get_directions with next_job.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "Action: 'start' to begin a new session, 'set_job_reference' to record or correct its job/work-order number, 'pause' to pause billing, 'resume' to continue, 'end' to finish, 'status' to query the active session, 'list' for history, 'recall' for older current-equipment records, 'vaults' for installed vault IDs/names and the configured default, 'escalate' to flag the session for a human expert, 'export' to produce a work-order PDF + audit JSON, 'add_upcoming_job' to record a job ahead, 'brief_next_job' to have the app read the next job's brief aloud, 'brief_more' to read one section of it in full."
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
                "description": "The technician's exact job or work-order number. Required on 'set_job_reference'; optional on 'start' when they already said it (\"start job 1005\"). Pass only a number they actually gave. Do not invent or normalize it, and never take it from an asset id."
            ],
            "customer": [
                "type": "string",
                "description": "On add_upcoming_job: the customer's name, exactly as said."
            ],
            "address": [
                "type": "string",
                "description": "On add_upcoming_job: the site address, exactly as said. Never looked up or completed."
            ],
            "contact": [
                "type": "string",
                "description": "On add_upcoming_job: the site contact, exactly as said."
            ],
            "fault_report": [
                "type": "string",
                "description": "On add_upcoming_job: the fault as the technician relayed it (\"no heat, showing E200\"), verbatim."
            ],
            "model": [
                "type": "string",
                "description": "On add_upcoming_job: a machine model they named. Omit unless said."
            ],
            "serial": [
                "type": "string",
                "description": "On add_upcoming_job: a serial number they read out. Omit unless said."
            ],
            "notes": [
                "type": "string",
                "description": "On add_upcoming_job: anything else they asked to note."
            ],
            "section": [
                "type": "string",
                "description": "On brief_more: which part of the brief — 'site', 'equipment', 'fault', 'crew' or 'parts'."
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
        case "add_upcoming_job":
            return addUpcomingJob(args: args)
        case "brief_next_job":
            return await briefNextJob()
        case "brief_more":
            return await briefMore(args: args)
        default:
            return "Unknown action '\(action)'. Use 'start', 'set_job_reference', 'pause', 'resume', 'end', 'status', 'list', 'recall', 'vaults', 'escalate', 'export', 'add_upcoming_job', 'brief_next_job', or 'brief_more'."
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
        // "Start job 1005" in one step (Plan FO P1). Absent, the app asks for the number itself —
        // and the result below says so, so the model neither asks nor supplies one.
        let jobReference = (args["job_reference"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let session: FieldSession
            if let flow {
                session = try flow.startJob(vaultId: vaultId, assetId: assetId, mode: mode,
                                            jobReference: jobReference)
            } else {
                session = try service.startSession(vaultId: vaultId, assetId: assetId, mode: mode,
                                                   jobReference: jobReference)
            }
            let vaultName = VaultRegistry.shared.manifest(id: vaultId)?.name ?? vaultId
            let asset = assetId.map { " on \($0)" } ?? ""
            let modeLabel = mode == .aiOnly ? "AI-only" : "human-assisted"
            let job = session.jobReference.map { " Job \($0) is recorded." }
                ?? " No job number yet — the app asks the technician for it directly, so do not ask for one, do not offer one, and do not infer one."
            return "Started \(modeLabel) Field Assist session against the \(vaultName) vault\(asset). Session id: \(session.id.prefix(8)).\(job)"
        } catch {
            return "Could not start session: \(error.localizedDescription)"
        }
    }

    // MARK: - Jobs ahead (Plan FO P3c)

    /// Record a job ahead from what the technician said. Every field is optional and is taken
    /// exactly as the model passed it; a field it did not pass stays empty, and the brief says so.
    private func addUpcomingJob(args: [String: Any]) -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist before adding a job."
        }
        guard let flow else { return "Jobs ahead can't be recorded here." }
        func text(_ key: String) -> String? { JobSite.cleaned(args[key] as? String) }
        let job = UpcomingJob(
            jobReference: text("job_reference"),
            site: JobSite(customer: text("customer"), address: text("address"), contact: text("contact")),
            faultReport: text("fault_report").map { FaultReport(text: $0, source: .spoken) },
            equipment: [KnownEquipment(model: text("model"), serial: text("serial"))],
            notes: text("notes"),
            origin: .spoken)
        guard job.jobReference != nil || !job.site.isEmpty || job.faultReport != nil else {
            return "Nothing was recorded: a job ahead needs at least a job number, a site or a fault. Ask the technician what the job is."
        }
        guard let added = flow.addUpcomingJob(job) else { return "The job couldn't be recorded." }
        var missing: [String] = []
        if added.jobReference == nil { missing.append("no job number") }
        if added.site.address == nil { missing.append("no address") }
        if added.faultReport == nil { missing.append("no fault report") }
        let gaps = missing.isEmpty ? "" : " It has \(missing.joined(separator: ", ")); leave those empty unless the technician gives them."
        return "Added \(added.spoken) to upcoming jobs. It has not started and counts no time.\(gaps) Confirm briefly in one sentence."
    }

    /// Have the app read the next job's brief aloud. The app speaks it — the model is told not to
    /// repeat it, because a brief relayed through a model is a brief that can be paraphrased.
    private func briefNextJob() async -> String {
        guard let flow, let next = flow.nextUpcomingJob else {
            return "There is no upcoming job on this phone. Say so in one sentence."
        }
        let spoken = await flow.briefAloud(jobId: next.id)
        return spoken
            ? "The app has just read the brief for \(next.title) aloud. Do not repeat or summarise it; reply with at most a few words."
            : "The brief for \(next.title) could not be assembled."
    }

    private func briefMore(args: [String: Any]) async -> String {
        guard let flow, let next = flow.nextUpcomingJob else {
            return "There is no upcoming job on this phone."
        }
        let request = (args["section"] as? String) ?? ""
        if next.brief == nil { flow.assembleBrief(jobId: next.id) }
        guard await flow.moreOfBrief(jobId: next.id, request: request) != nil else {
            return "Ask which part: the site, the equipment, the fault, what the crew learned, or parts."
        }
        return "The app has just read that part of the brief aloud. Do not repeat it."
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
        // Through the flow when there is one, so the intake stops asking and the job's conversation
        // takes the number as its title (Plan FO P1).
        if let flow { flow.supplyJobReference(reference) } else { service.setJobReference(reference) }
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
            // Through the flow when there is one: finishing the job is one of the two things that
            // really do end its conversation (Plan FO P1).
            let session = try flow?.closeJob(outcome: outcome) ?? service.endSession(outcome: outcome)
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
