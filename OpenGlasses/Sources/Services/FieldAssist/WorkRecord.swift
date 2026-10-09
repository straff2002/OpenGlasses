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
        /// What the technician said the model was — or, for a unit recorded before that was kept,
        /// the vault's spelling it has always printed (Plan GB P2).
        let model: String
        let heading: String
        let source: String
        let recognisedAt: Date
        /// The vault section the model matched, when it is not simply what was said. Absent from
        /// the JSON otherwise, so an older record encodes exactly as it did.
        var vaultSection: String? = nil
        /// True for a unit the technician named that the loaded manuals do not cover.
        var outOfVault: Bool? = nil

        init(model: String, heading: String, source: String, recognisedAt: Date,
             vaultSection: String? = nil, outOfVault: Bool? = nil) {
            self.model = model
            self.heading = heading
            self.source = source
            self.recognisedAt = recognisedAt
            self.vaultSection = vaultSection
            self.outOfVault = outOfVault
        }

        init(_ identity: EquipmentIdentity) {
            self.init(model: identity.stated, heading: identity.heading,
                      source: identity.source.rawValue, recognisedAt: identity.recognisedAt,
                      vaultSection: identity.vaultSectionIfDifferent,
                      outOfVault: identity.isOutOfVault ? true : nil)
        }
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
    /// Where the job was and what was reported wrong, when both were known before the visit
    /// (Plan FO P3c). The report is the office's words, printed as theirs — never as a finding.
    let site: JobSite?
    let faultReport: FaultReport?
    /// The job file the visit came from, when it came from one (Plan FO §8).
    let jobFile: JobFileProvenance?
    let escalations: [Escalation]
    let startedAt: Date
    let endedAt: Date?
    /// Exact accumulated active time. Optional so older exported records still decode.
    let billableSeconds: TimeInterval?
    let billableMinutes: Int
    let billingBasis: FieldAssistBillingBasis?
    let minutesPerBillingUnit: Int?
    let billableUnits: Int?
    /// The machines the job covered and which tasks were done on each (Plan GB P2). **Only when
    /// there were two or more** — a job on one machine, or on none, carries no `units` key at all,
    /// so its JSON and its lines are byte for byte what they were (FO).
    let units: [UnitLedger.Unit]?
    /// Values the technician read out, with their corrections (Plan GB P3). Absent when there were
    /// none, so an older record encodes as it always did.
    let spokenReadings: [SpokenReading]?
    /// What the job cost in model usage (Plan GD1): requests, tokens and the estimated dollars.
    /// Internal — the JSON and the Job tab carry it; the customer summary and the work order's
    /// printed lines never do. Nil, and absent from the JSON, when nothing was recorded against the
    /// job, so an older record encodes exactly as it did.
    let usage: JobUsageSummary?
    /// Team-learning candidates filed on this job (Plan FP P1): that each was filed, and that it is
    /// not in use — id, status, machine and date, never the words. Internal, like `usage`: no
    /// customer summary and no printed work-order line carries it, and a customer-audience export
    /// leaves it out (`SessionExporter.buildExport`; contract §8). Nil, and absent from the JSON,
    /// on a job that filed none, so an older record encodes exactly as it did.
    var teamLearnings: [LearningCandidateReference]?

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
        case site
        case faultReport = "fault_report"
        case jobFile = "job_file"
        case escalations
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case billableSeconds = "billable_seconds"
        case billableMinutes = "billable_minutes"
        case billingBasis = "billing_basis"
        case minutesPerBillingUnit = "minutes_per_unit"
        case billableUnits = "billable_units"
        case units
        case spokenReadings = "spoken_readings"
        case usage
        case teamLearnings = "team_learnings"
    }

    // MARK: - Assembly

    /// Build the record from a session. Pure: everything it needs is already on the session, so the
    /// same session always renders the same record.
    init(session: FieldSession, vaultName: String, vaultSourceNote: String? = nil,
         usage: JobUsageSummary? = nil) {
        self.sessionId = session.id
        self.jobReference = session.jobReference
        self.vaultId = session.vaultId
        self.vaultName = vaultName
        self.vaultSourceNote = vaultSourceNote
        self.assetId = session.assetId
        self.equipment = session.equipment.map(Equipment.init)
        self.identityFields = session.identityFields
        self.tasks = session.tasks
        self.partsRequests = session.partsRequests
        self.jobEvidence = session.jobEvidence
        self.media = session.media
        self.evidenceSelection = session.evidenceSelection
        self.signOff = session.signOff
        self.debriefs = session.debriefs
        self.site = session.site
        self.faultReport = session.faultReport
        self.jobFile = session.jobFile
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
        let ledger = UnitLedger(session: session)
        self.units = ledger.isMultiUnit ? ledger.units : nil
        self.spokenReadings = session.spokenReadings.isEmpty ? nil : session.spokenReadings
        self.usage = Self.nonEmpty(usage)
        self.teamLearnings = (session.teamLearnings ?? []).isEmpty ? nil : session.teamLearnings
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
        site = try c.decodeIfPresent(JobSite.self, forKey: .site)
        faultReport = try c.decodeIfPresent(FaultReport.self, forKey: .faultReport)
        jobFile = try c.decodeIfPresent(JobFileProvenance.self, forKey: .jobFile)
        escalations = try c.decodeIfPresent([Escalation].self, forKey: .escalations) ?? []
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        billableSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .billableSeconds)
        billableMinutes = try c.decodeIfPresent(Int.self, forKey: .billableMinutes) ?? 0
        billingBasis = try c.decodeIfPresent(FieldAssistBillingBasis.self, forKey: .billingBasis)
        minutesPerBillingUnit = try c.decodeIfPresent(Int.self, forKey: .minutesPerBillingUnit)
        billableUnits = try c.decodeIfPresent(Int.self, forKey: .billableUnits)
        units = try c.decodeIfPresent([UnitLedger.Unit].self, forKey: .units)
        spokenReadings = try c.decodeIfPresent([SpokenReading].self, forKey: .spokenReadings)
        usage = Self.nonEmpty(try c.decodeIfPresent(JobUsageSummary.self, forKey: .usage))
        teamLearnings = try c.decodeIfPresent([LearningCandidateReference].self, forKey: .teamLearnings)
    }

    /// A summary with no requests is no summary: kept out of the record, so the synthesized encoder
    /// writes no `usage` key for it.
    private static func nonEmpty(_ usage: JobUsageSummary?) -> JobUsageSummary? {
        guard let usage, !usage.isEmpty else { return nil }
        return usage
    }

    // MARK: - Derived views

    /// The evidence as the report will carry it: only what the technician chose, grouped by task,
    /// Fault before Fix before unmarked. Empty when the review was skipped or never reached — the
    /// record then prints the text bullets it always has.
    var evidencePlan: EvidenceRenderPlan {
        // A choice made on the Job tab or by voice counts without the close review (Plan GB P3).
        guard let evidenceSelection = EvidenceSelectionPolicy.effective(evidenceSelection) else {
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
        guard let evidenceSelection = EvidenceSelectionPolicy.effective(evidenceSelection) else { return [] }
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

    /// "Model usage: $0.42 · 12 requests" — the technician's line (Plan GD1), nil when the job
    /// recorded no model usage. Deliberately **not** one of `summaryLines`: those are the lines the
    /// work order prints for the customer, and what the job cost in model usage is not theirs.
    var usageLine: String? { JobTabModel.usageLine(usage) }

    func tasks(status: FieldSession.Task.Status) -> [FieldSession.Task] {
        tasks.filter { $0.status == status }
    }

    /// Parts on tasks that were actually carried out — what came off the van, as opposed to what
    /// was asked for.
    var partsUsed: [TaskPart] {
        var seen = Set<String>()
        return tasks(status: .done).flatMap(\.parts).filter { seen.insert($0.number).inserted }
    }

    /// The visit's manual pages, counted and listed from one set (Plan GB P0).
    var evidenceRollup: EvidenceRollup { EvidenceRollup(tasks: tasks, jobEvidence: jobEvidence) }

    /// Every page verified during the visit, task-attached or not.
    var pagesVerified: [String] { evidenceRollup.verifiedPages }

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
        // What was known before the visit (Plan FO P3c), each line absent when nothing was — so a
        // job born on site prints exactly what it always has.
        if let headline = site?.headline { lines.append("Site: \(headline).") }
        if let faultReport {
            lines.append("Reported fault (\(faultReport.source.attribution), not a finding): "
                         + "\u{201C}\(faultReport.text)\u{201D}")
        }
        if let jobFile { lines.append(jobFile.recordLine) }
        if let units, units.count >= 2 {
            // Several machines (Plan GB P2): each unit's work under its own heading, so two
            // furnaces do not read as one.
            lines.append("Units on this job: \(units.count).")
            lines.append(contentsOf: identityFields.map { "  \($0.summary)" })
            var placed = Set<String>()
            for unit in units {
                lines.append(unit.headerLine)
                for status in Self.statusOrder {
                    for task in tasks(status: status) where unit.taskIds.contains(task.id) {
                        placed.insert(task.id)
                        lines.append("  " + Self.line(for: task))
                    }
                }
                if unit.taskIds.isEmpty { lines.append("  No tasks were recorded on this unit.") }
            }
            for status in Self.statusOrder {
                for task in tasks(status: status) where !placed.contains(task.id) {
                    lines.append(Self.line(for: task))
                }
            }
        } else {
            if let equipmentLine { lines.append(equipmentLine) }
            lines.append(contentsOf: identityFields.map { "  \($0.summary)" })

            for status in Self.statusOrder {
                for task in tasks(status: status) { lines.append(Self.line(for: task)) }
            }
            if tasks.isEmpty { lines.append("No tasks were recorded on this job.") }
        }

        // As the technician reported them — each once, corrections folded in (Plan GB P3).
        let chains = SpokenReadingLedger.chains(spokenReadings ?? [])
        if !chains.isEmpty {
            lines.append("Readings reported by the technician:")
            lines.append(contentsOf: chains.map { "  " + SpokenReadingLedger.line(for: $0) })
        }

        let used = partsUsed
        if !used.isEmpty {
            lines.append("Parts used:")
            lines.append(contentsOf: used.map { "  \($0.summary)" })
        }

        // The job's own pages are not counted here: they are listed below with every task's
        // pages, and a count beside a list drawn from a different set is how job 1011's report
        // said "5 pages verified" above a list of six (Plan GB P0).
        if let phrase = evidenceRollup.jobPhrase {
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
        // What was said, then — only when it differs — the vault section it matched (Plan GB P2).
        var line: String
        if let section = equipment.vaultSection {
            line = "Equipment: \(equipment.model) (vault section \(section); \(phrase))"
        } else if equipment.outOfVault == true {
            line = "Equipment: \(equipment.model) (not in the vault; \(phrase))"
        } else {
            line = "Equipment: \(equipment.model) (\(phrase))"
        }
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
        // A check still owed says so, whatever its status word would be (Plan GB P3).
        var head = task.awaitsVerification ? "Not yet verified: \(task.title)"
            : "\(label(for: task.status)): \(task.title)"
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
        // Every piece ends its own sentence before the pieces are joined. A completion note is
        // the technician's own words and routinely arrives punctuated ("New trap fitted and
        // tested."), and a joiner that added ". " after it printed "airflow.. Note:" in the middle
        // of a line as well as "…tested.." at its end (Plan GB P0).
        return parts.map(Self.terminated).joined(separator: " ")
    }

    /// End the line with exactly one sentence-ending mark.
    static func terminated(_ line: String) -> String {
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
