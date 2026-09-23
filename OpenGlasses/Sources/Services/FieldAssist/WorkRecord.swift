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
    /// Where the vault came from, when that is something the record has to say (Plan FS §4): a
    /// vault received from a link that was not signed by a listed publisher, or one whose
    /// publisher has since been revoked. Nil — and silent — for every other vault.
    let vaultSourceNote: String?
    let assetId: String?
    let equipment: Equipment?
    let identityFields: [DeviceIdentityField]
    let tasks: [FieldSession.Task]
    let partsRequests: [PartsRequest]
    /// Evidence recorded when no task was active — it belongs to the visit, not to nothing.
    let jobEvidence: FieldSession.Evidence
    /// The job's evidence files, described (Plan FO P2a).
    let media: [JobMediaItem]
    /// What the technician chose to send. Carried on the record so a re-send from a past job
    /// reproduces the PDF that went out the first time rather than re-deciding it.
    let evidenceSelection: EvidenceSelection?
    /// What the customer put their name to, when they were asked (Plan FO P2c). The summary it
    /// carries is frozen at the moment of signing and is **not** re-derived from this record —
    /// that is the whole point of keeping it.
    let signOff: CustomerSignOff?
    /// What was said about this job after the visit (Plan FO P3b). Appended, never merged into the
    /// record's own lines: a debrief is the technician's account, and the tasks, the readings and
    /// the time on the job above it are the visit's own facts.
    let debriefs: [Debrief]
    let escalations: [Escalation]
    let startedAt: Date
    let endedAt: Date?
    /// Exact accumulated active time. Optional so older exported records still decode.
    let billableSeconds: TimeInterval?
    let billableMinutes: Int
    let billingBasis: FieldAssistBillingBasis?
    let minutesPerBillingUnit: Int?
    let billableUnits: Int?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case jobReference = "job_reference"
        case vaultId = "vault"
        case vaultName = "vault_name"
        case vaultSourceNote = "vault_source_note"
        case assetId = "asset_id"
        case equipment
        case identityFields = "identity_fields"
        case tasks
        case partsRequests = "parts_requests"
        case jobEvidence = "job_evidence"
        case media
        case evidenceSelection = "evidence_selection"
        case signOff = "sign_off"
        case debriefs
        case escalations
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case billableSeconds = "billable_seconds"
        case billableMinutes = "billable_minutes"
        case billingBasis = "billing_basis"
        case minutesPerBillingUnit = "minutes_per_unit"
        case billableUnits = "billable_units"
    }

    // MARK: - Assembly

    /// Build the record from a session. Pure: everything it needs is already on the session, so the
    /// same session always renders the same record.
    init(session: FieldSession, vaultName: String, vaultSourceNote: String? = nil) {
        self.sessionId = session.id
        self.jobReference = session.jobReference
        self.vaultId = session.vaultId
        self.vaultName = vaultName
        self.vaultSourceNote = vaultSourceNote
        self.assetId = session.assetId
        self.equipment = session.equipment.map {
            Equipment(model: $0.modelToken, heading: $0.heading,
                      source: $0.source.rawValue, recognisedAt: $0.recognisedAt)
        }
        self.identityFields = session.identityFields
        self.tasks = session.tasks
        self.partsRequests = session.partsRequests
        self.jobEvidence = session.jobEvidence
        self.media = session.media
        self.evidenceSelection = session.evidenceSelection
        self.signOff = session.signOff
        self.debriefs = session.debriefs
        self.escalations = session.escalations.map {
            Escalation(reason: $0.reason, resolved: $0.resolvedAt != nil)
        }
        self.startedAt = session.startedAt
        self.endedAt = session.endedAt
        self.billableSeconds = session.billableSeconds
        self.billableMinutes = Int((session.billableSeconds / 60.0).rounded())
        self.billingBasis = session.billingBasis
        self.minutesPerBillingUnit = session.minutesPerBillingUnit
        self.billableUnits = session.billingBasis == .units
            ? FieldAssistBillingBasis.units(for: session.billableSeconds,
                                            minutesPerUnit: session.minutesPerBillingUnit)
            : nil
    }

    /// Hand-written so a record exported before the evidence review existed still decodes.
    ///
    /// The same rule `FieldSession.init(from:)` follows and for the same reason: the synthesized
    /// decoder throws on a missing key for a non-optional property, and `media` is a collection.
    /// A record with no catalogue simply has nothing to show at review — which is exactly what an
    /// older job is.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        jobReference = try c.decodeIfPresent(String.self, forKey: .jobReference)
        vaultId = try c.decode(String.self, forKey: .vaultId)
        vaultName = try c.decode(String.self, forKey: .vaultName)
        vaultSourceNote = try c.decodeIfPresent(String.self, forKey: .vaultSourceNote)
        assetId = try c.decodeIfPresent(String.self, forKey: .assetId)
        equipment = try c.decodeIfPresent(Equipment.self, forKey: .equipment)
        identityFields = try c.decodeIfPresent([DeviceIdentityField].self, forKey: .identityFields) ?? []
        tasks = try c.decodeIfPresent([FieldSession.Task].self, forKey: .tasks) ?? []
        partsRequests = try c.decodeIfPresent([PartsRequest].self, forKey: .partsRequests) ?? []
        jobEvidence = try c.decodeIfPresent(FieldSession.Evidence.self, forKey: .jobEvidence)
            ?? FieldSession.Evidence()
        media = try c.decodeIfPresent([JobMediaItem].self, forKey: .media) ?? []
        evidenceSelection = try c.decodeIfPresent(EvidenceSelection.self, forKey: .evidenceSelection)
        signOff = try c.decodeIfPresent(CustomerSignOff.self, forKey: .signOff)
        debriefs = try c.decodeIfPresent([Debrief].self, forKey: .debriefs) ?? []
        escalations = try c.decodeIfPresent([Escalation].self, forKey: .escalations) ?? []
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        billableSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .billableSeconds)
        billableMinutes = try c.decodeIfPresent(Int.self, forKey: .billableMinutes) ?? 0
        billingBasis = try c.decodeIfPresent(FieldAssistBillingBasis.self, forKey: .billingBasis)
        minutesPerBillingUnit = try c.decodeIfPresent(Int.self, forKey: .minutesPerBillingUnit)
        billableUnits = try c.decodeIfPresent(Int.self, forKey: .billableUnits)
    }

    // MARK: - Derived views

    /// The evidence as the report will carry it: only what the technician chose, grouped by task,
    /// Fault before Fix before unmarked. Empty when the review was skipped or never reached — the
    /// record then prints the text bullets it always has.
    var evidencePlan: EvidenceRenderPlan {
        guard let evidenceSelection, evidenceSelection.reviewed else {
            return EvidenceRenderPlan(groups: [])
        }
        return EvidenceRenderPlan.make(items: media, selection: evidenceSelection,
                                       taskTitles: tasks.map { (id: $0.id, title: $0.title) })
    }

    /// The clips the technician chose, in the order the report names them (Plan FO P2b).
    ///
    /// Empty when the review was skipped or never reached, for the same reason `evidencePlan` is:
    /// a clip that was never chosen has not been chosen, and "not chosen" is the only safe reading
    /// when what is at stake is a video of a customer's plant room leaving the device.
    var includedClips: [JobMediaItem] {
        guard let evidenceSelection, evidenceSelection.reviewed else { return [] }
        let byId = Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return evidenceSelection.includedItemIds(kind: .clip).compactMap { byId[$0] }
    }

    /// The customer's half of the record as it stands **now** — what the sign-off sheet would put
    /// in front of somebody at this moment.
    ///
    /// Not the same thing as `signOff?.summaryLines`, which is what was on the screen when a
    /// customer actually signed. The two are equal until the record moves on, and telling them
    /// apart is the reason both exist.
    var customerSummaryLines: [String] { CustomerSummary.lines(for: self) }

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
        // Said once, near the top, before anything drawn from the vault is read back: a reviewer
        // has to know the shelf was unverified before they read what came off it.
        if let vaultSourceNote { lines.append(vaultSourceNote) }
        if let equipmentLine { lines.append(equipmentLine) }
        lines.append(contentsOf: identityFields.map { "  \($0.summary)" })

        for status in Self.statusOrder {
            for task in tasks(status: status) { lines.append(Self.line(for: task)) }
        }
        if tasks.isEmpty { lines.append("No tasks were recorded on this job.") }

        let used = partsUsed
        if !used.isEmpty {
            lines.append("Parts used:")
            lines.append(contentsOf: used.map { "  \($0.summary)" })
        }

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
        lines.append("Time on job: \(durationPhrase).")
        if billingBasis == .units, let billableUnits, let minutesPerBillingUnit {
            lines.append("Billable units: \(Self.unitPhrase(billableUnits)) "
                         + "(\(minutesPerBillingUnit) minute\(minutesPerBillingUnit == 1 ? "" : "s") per unit; partial units round up).")
        }
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
            let procedure = prettyLabel(procedureId)
            parts.append(task.procedureOutcome.map {
                "Procedure \(procedure) finished as \(prettyLabel($0).lowercased())"
            } ?? "Procedure \(procedure)")
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
        // The full stop is added only when the last piece does not already end a sentence. A
        // completion note is the technician's own words and routinely arrives punctuated ("New
        // trap fitted and tested."), which used to print as "…tested..".
        let line = parts.joined(separator: ". ")
        return Self.terminated(line)
    }

    /// End the line with exactly one sentence-ending mark.
    private static func terminated(_ line: String) -> String {
        guard let last = line.last else { return line }
        return ".!?".contains(last) ? line : line + "."
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

    var durationPhrase: String {
        guard let billableSeconds else { return Self.minutesPhrase(minutes: billableMinutes) }
        return Self.durationPhrase(seconds: billableSeconds)
    }

    var billingSummary: String {
        Self.billingSummary(seconds: billableSeconds ?? Double(billableMinutes * 60),
                            basis: billingBasis ?? .minutes,
                            minutesPerUnit: minutesPerBillingUnit ?? 15)
    }

    static func durationPhrase(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        guard total >= 60 else { return "\(total) second\(total == 1 ? "" : "s")" }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        var pieces: [String] = []
        if hours > 0 { pieces.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { pieces.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if seconds > 0 { pieces.append("\(seconds) second\(seconds == 1 ? "" : "s")") }
        return pieces.joined(separator: " ")
    }

    static func unitPhrase(_ units: Int) -> String {
        "\(units) unit\(units == 1 ? "" : "s")"
    }

    static func billingSummary(seconds: TimeInterval, basis: FieldAssistBillingBasis,
                               minutesPerUnit: Int) -> String {
        switch basis {
        case .minutes:
            return durationPhrase(seconds: seconds)
        case .units:
            return unitPhrase(FieldAssistBillingBasis.units(for: seconds,
                                                            minutesPerUnit: minutesPerUnit))
        }
    }

    static func prettyLabel(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
        return words.enumerated().map { index, word in
            let lower = word.lowercased()
            if ["ai", "id", "ocr", "pdf"].contains(lower) { return lower.uppercased() }
            if lower.contains(where: \.isNumber) { return lower.uppercased() }
            if index == 0 { return lower.prefix(1).uppercased() + lower.dropFirst() }
            return lower
        }.joined(separator: " ")
    }
}
