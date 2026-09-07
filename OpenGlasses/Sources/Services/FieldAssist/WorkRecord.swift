import Foundation

/// What the visit amounts to: what was recommended, what the technician decided, what was actually
/// done and on what evidence, and what base is being asked for.
///
/// Assembled **deterministically** from the session — no model is asked to summarise anything. A
/// paraphrase may sit beside this, labelled as a paraphrase; it is never the record. Two sessions
/// with the same tasks and the same evidence produce the same lines, which is what makes the
/// read-back something a technician can confirm and a reviewer can check.
struct WorkRecord: Codable, Equatable {

    /// The machine, flattened out of the session's identity so the record stands alone.
    struct Equipment: Codable, Equatable {
        let model: String
        let heading: String
        let source: String
        let recognisedAt: Date
    }

    struct Escalation: Codable, Equatable {
        let reason: String
        let resolved: Bool
    }

    let sessionId: String
    let jobReference: String?
    let vaultId: String
    let vaultName: String
    let assetId: String?
    let equipment: Equipment?
    let identityFields: [DeviceIdentityField]
    let tasks: [FieldSession.Task]
    let partsRequests: [PartsRequest]
    /// Evidence recorded when no task was active — it belongs to the visit, not to nothing.
    let jobEvidence: FieldSession.Evidence
    let escalations: [Escalation]
    let startedAt: Date
    let endedAt: Date?
    let billableMinutes: Int

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case jobReference = "job_reference"
        case vaultId = "vault"
        case vaultName = "vault_name"
        case assetId = "asset_id"
        case equipment
        case identityFields = "identity_fields"
        case tasks
        case partsRequests = "parts_requests"
        case jobEvidence = "job_evidence"
        case escalations
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case billableMinutes = "billable_minutes"
    }

    // MARK: - Assembly

    /// Build the record from a session. Pure: everything it needs is already on the session, so the
    /// same session always renders the same record.
    init(session: FieldSession, vaultName: String) {
        self.sessionId = session.id
        self.jobReference = session.jobReference
        self.vaultId = session.vaultId
        self.vaultName = vaultName
        self.assetId = session.assetId
        self.equipment = session.equipment.map {
            Equipment(model: $0.modelToken, heading: $0.heading,
                      source: $0.source.rawValue, recognisedAt: $0.recognisedAt)
        }
        self.identityFields = session.identityFields
        self.tasks = session.tasks
        self.partsRequests = session.partsRequests
        self.jobEvidence = session.jobEvidence
        self.escalations = session.escalations.map {
            Escalation(reason: $0.reason, resolved: $0.resolvedAt != nil)
        }
        self.startedAt = session.startedAt
        self.endedAt = session.endedAt
        self.billableMinutes = Int((session.billableSeconds / 60.0).rounded())
    }

    // MARK: - Derived views

    func tasks(status: FieldSession.Task.Status) -> [FieldSession.Task] {
        tasks.filter { $0.status == status }
    }

    /// Parts on tasks that were actually carried out — what came off the van, as opposed to what
    /// was asked for.
    var partsUsed: [TaskPart] {
        var seen = Set<String>()
        return tasks(status: .done).flatMap(\.parts).filter { seen.insert($0.number).inserted }
    }

    /// Every page anyone actually put on screen during the visit, task-attached or not.
    var pagesVerified: [String] {
        var seen = Set<String>()
        let all = tasks.flatMap(\.evidence.pagesVerified) + jobEvidence.pagesVerified
        return all.filter { seen.insert($0).inserted }
    }

    /// Every capture record taken during the visit.
    var readings: [String] {
        var seen = Set<String>()
        let all = tasks.flatMap(\.evidence.readings) + jobEvidence.readings
        return all.filter { seen.insert($0).inserted }
    }

    /// Recommendations the technician turned down or put off. Kept because "recommended, not done"
    /// is information, not an absence.
    var notDone: [FieldSession.Task] {
        tasks.filter { $0.status == .declined || $0.status == .deferred || $0.status == .abandoned }
    }

    // MARK: - The read-back

    /// The record in plain language, one line at a time — what the assistant speaks when the
    /// technician says "read back the job", and what the export prints.
    var summaryLines: [String] {
        var lines: [String] = [headerLine]
        if let equipmentLine { lines.append(equipmentLine) }
        lines.append(contentsOf: identityFields.map { "  \($0.summary)" })

        for status in Self.statusOrder {
            for task in tasks(status: status) { lines.append(Self.line(for: task)) }
        }
        if tasks.isEmpty { lines.append("No tasks were recorded on this job.") }

        if !jobEvidence.isEmpty, let phrase = Self.evidencePhrase(jobEvidence) {
            lines.append("Against the job itself: \(phrase).")
        }
        if !partsRequests.isEmpty {
            lines.append("Parts requested:")
            lines.append(contentsOf: partsRequests.map { "  \($0.summary)" })
        }
        let pages = pagesVerified
        if !pages.isEmpty {
            lines.append("Pages verified against the manufacturer's document: "
                         + pages.joined(separator: "; ") + ".")
        }
        if escalations.isEmpty {
            lines.append("No escalations.")
        } else {
            for escalation in escalations {
                lines.append("Escalated: \(escalation.reason)"
                             + (escalation.resolved ? " (resolved)." : " (open)."))
            }
        }
        lines.append("Time on site: \(Self.minutesPhrase(minutes: billableMinutes)).")
        return lines
    }

    /// The record as one block of speakable text.
    var summary: String { summaryLines.joined(separator: "\n") }

    private var headerLine: String {
        let job = jobReference.flatMap { $0.isEmpty ? nil : $0 }
        return job.map { "Job \($0) — \(vaultName)." } ?? "\(vaultName) — no job reference."
    }

    /// The machine, when the session identified one. A session that never did prints **no**
    /// equipment line — the same rule the work order's own summary follows, so the two halves of
    /// one PDF cannot contradict each other about whether the machine was known. The work order's
    /// asset id is not the machine and says so on its own line.
    private var equipmentLine: String? {
        guard let equipment else {
            guard let assetId, !assetId.isEmpty else { return nil }
            return "Work order asset: \(assetId); no machine was identified."
        }
        let phrase = EquipmentIdentity.Source(rawValue: equipment.source)?.provenancePhrase
            ?? equipment.source
        var line = "Equipment: \(equipment.model) (\(phrase))"
        if let assetId, !assetId.isEmpty { line += ", work order asset \(assetId)" }
        return line + "."
    }

    // MARK: - JSON

    /// The record as structured JSON — the shape a job system consumes. Sorted keys and ISO-8601
    /// dates, so the bytes are stable for the same record.
    var json: Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    var jsonString: String { String(data: json, encoding: .utf8) ?? "{}" }

    // MARK: - Rendering helpers

    /// Closed work first, then what is still open, then what was turned down: the order a
    /// technician confirms in and a reviewer reads in.
    static let statusOrder: [FieldSession.Task.Status] = [
        .done, .inProgress, .accepted, .recommended, .deferred, .declined, .abandoned
    ]

    static func label(for status: FieldSession.Task.Status) -> String {
        switch status {
        case .done: return "Done"
        case .inProgress: return "In progress"
        case .accepted: return "Accepted, not started"
        case .recommended: return "Recommended, no decision yet"
        case .deferred: return "Deferred"
        case .declined: return "Declined"
        case .abandoned: return "Abandoned"
        }
    }

    static func line(for task: FieldSession.Task) -> String {
        var head = "\(label(for: task.status)): \(task.title)"
        if task.origin == .operatorAdded { head += " (added by the technician)" }
        var parts = [head]
        if let why = task.why, !why.isEmpty { parts.append("Why: \(why)") }
        if let procedureId = task.procedureId {
            parts.append(task.procedureOutcome.map { "Procedure \(procedureId) finished as \($0)" }
                         ?? "Procedure \(procedureId)")
        }
        if let note = task.completionNote, !note.isEmpty { parts.append("Note: \(note)") }
        if !task.parts.isEmpty {
            parts.append("Parts: " + task.parts.map(\.summary).joined(separator: "; "))
        }
        if let evidence = evidencePhrase(task.evidence) { parts.append(evidence) }
        if let citation = task.citation, !citation.isEmpty { parts.append("Cited \(citation)") }
        if let elapsed = task.elapsed {
            parts.append(minutesPhrase(minutes: Int((elapsed / 60.0).rounded())))
        }
        return parts.joined(separator: ". ") + "."
    }

    /// "1 reading, 2 photos, 1 page verified" — nil when nothing was recorded.
    static func evidencePhrase(_ evidence: FieldSession.Evidence) -> String? {
        var pieces: [String] = []
        if !evidence.readings.isEmpty { pieces.append(count(evidence.readings.count, "reading")) }
        if !evidence.photos.isEmpty { pieces.append(count(evidence.photos.count, "photo")) }
        if !evidence.citationsOpened.isEmpty {
            pieces.append(count(evidence.citationsOpened.count, "citation") + " opened")
        }
        if !evidence.pagesVerified.isEmpty {
            pieces.append(count(evidence.pagesVerified.count, "page") + " verified")
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: ", ")
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    static func minutesPhrase(minutes: Int) -> String {
        switch minutes {
        case ..<1: return "under a minute"
        case 1: return "1 minute"
        default: return "\(minutes) minutes"
        }
    }
}
