import Foundation

/// The brief before site: what is known about the next job, from sources the app can cite
/// (Plan FO §7, P3c).
///
/// **Every line cites, or the section says there is nothing on file.** There is no field in here a
/// model wrote: the brief is assembled by `JobBriefAssembler` from the job ahead, this phone's
/// history, and the vault — so "last visit 14 May, job 0993" is a fact about a record on this
/// phone, and "E200 is low refrigerant pressure" is a row in a vault table that can be opened.
///
/// It is advisory context and nothing else. Nothing in a brief becomes a task, a reading or a
/// diagnosis; the fault candidates are ranked by how strong their evidence is, and never asserted.
struct JobBrief: Codable, Equatable {

    /// The five sections, in the order they are read.
    enum SectionKind: String, Codable, CaseIterable, Equatable {
        case siteAndHistory = "site_and_history"
        case knownEquipment = "known_equipment"
        case faultCandidates = "fault_candidates"
        case crewLearnings = "crew_learnings"
        case partsAndPrerequisites = "parts_and_prerequisites"

        var title: String {
            switch self {
            case .siteAndHistory: return "Site and history"
            case .knownEquipment: return "Known equipment"
            case .faultCandidates: return "The fault report"
            case .crewLearnings: return "What the crew learned"
            case .partsAndPrerequisites: return "Parts and prerequisites"
            }
        }

        /// What the section says, out loud and on screen, when it has nothing in it. Said rather
        /// than skipped silently, so a technician can tell "nothing on file" from "not read out".
        var emptyLine: String {
            switch self {
            case .siteAndHistory: return "Nothing on file about the site, and no earlier visit on this phone."
            case .knownEquipment: return "No equipment on file for this job."
            case .faultCandidates: return "No fault report on file."
            case .crewLearnings: return "Nothing recorded about this site or these machines."
            case .partsAndPrerequisites: return "No parts or safety prerequisites on file for the candidates."
            }
        }

        /// The words a technician uses to ask for more of it: "say more about the fault".
        var spokenNames: [String] {
            switch self {
            case .siteAndHistory: return ["site", "history", "last visit", "previous visit", "customer"]
            case .knownEquipment: return ["equipment", "machine", "model", "unit"]
            case .faultCandidates: return ["fault", "faults", "error", "code", "candidates", "causes"]
            case .crewLearnings: return ["crew", "learned", "learnings", "follow-up", "follow up", "follow-ups"]
            case .partsAndPrerequisites: return ["parts", "part", "prerequisites", "safety"]
            }
        }
    }

    /// One line of the brief, with where it came from.
    struct Item: Codable, Equatable {
        let text: String
        let citation: String
    }

    struct Section: Codable, Equatable {
        let kind: SectionKind
        let items: [Item]

        var isEmpty: Bool { items.isEmpty }
    }

    let jobReference: String?
    let assembledAt: Date
    /// Always all five, in `SectionKind.allCases` order.
    let sections: [Section]
    /// A fault report was on file and nothing in the vault or its manuals matched it.
    let faultUnmatched: Bool

    enum CodingKeys: String, CodingKey {
        case jobReference = "job_reference"
        case assembledAt = "assembled_at"
        case sections
        case faultUnmatched = "fault_unmatched"
    }

    init(jobReference: String?, assembledAt: Date, sections: [Section], faultUnmatched: Bool) {
        self.jobReference = jobReference
        self.assembledAt = Date(timeIntervalSince1970: assembledAt.timeIntervalSince1970.rounded(.down))
        // Exactly the five, in order, whatever the caller handed in: a brief with a section
        // missing would read as a brief with nothing in it.
        self.sections = SectionKind.allCases.map { kind in
            sections.first { $0.kind == kind } ?? Section(kind: kind, items: [])
        }
        self.faultUnmatched = faultUnmatched
    }

    func section(_ kind: SectionKind) -> Section {
        sections.first { $0.kind == kind } ?? Section(kind: kind, items: [])
    }

    /// Every item, in reading order.
    var allItems: [Item] { sections.flatMap(\.items) }
}

// MARK: - Assembly

/// Builds a brief from what the app can cite. Pure: every source is handed in, so a brief from
/// fixtures is a test rather than a hope.
enum JobBriefAssembler {

    struct Inputs {
        var job: UpcomingJob
        var history: JobHistoryIndex
        var vaultName: String
        /// The vault's core files, as `VaultStore.readAll()` returns them.
        var coreFiles: [(filename: String, contents: String)]
        var modelIndex: VaultModelIndex
        var partsIndex: VaultPartsIndex
        var procedures: [Procedure]
        /// Manual passages for the fault report's words, **already through the evidence gate**
        /// (EJ). Empty when the vault has no manuals or nothing cleared the gate.
        var manualPassages: (String) -> [VaultRetriever.Passage]
        /// What the crew has learned, when FP exists. Empty until then; the section reads from
        /// this phone's own earlier debriefs and follow-ups meanwhile.
        var learnings: [JobBrief.Item]
        var now: Date

        init(job: UpcomingJob, history: JobHistoryIndex, vaultName: String,
             coreFiles: [(filename: String, contents: String)] = [],
             modelIndex: VaultModelIndex? = nil, partsIndex: VaultPartsIndex? = nil,
             procedures: [Procedure] = [],
             manualPassages: @escaping (String) -> [VaultRetriever.Passage] = { _ in [] },
             learnings: [JobBrief.Item] = [], now: Date = Date()) {
            self.job = job
            self.history = history
            self.vaultName = vaultName
            self.coreFiles = coreFiles
            self.modelIndex = modelIndex ?? VaultModelIndex(vaultName: vaultName, files: coreFiles)
            self.partsIndex = partsIndex ?? VaultPartsIndex(files: coreFiles)
            self.procedures = procedures
            self.manualPassages = manualPassages
            self.learnings = learnings
            self.now = now
        }
    }

    /// How many earlier visits the history section names. The newest ones; the rest are on the
    /// Job tab's past-job list.
    static let visitLimit = 3
    static let candidateLimit = 5
    static let passageLimit = 3
    static let passageCharacters = 180
    static let learningLimit = 6

    static func assemble(_ inputs: Inputs) -> JobBrief {
        let matches = inputs.history.matches(for: inputs.job)
        let faults = faultSection(inputs, matches: matches)
        return JobBrief(
            jobReference: inputs.job.jobReference,
            assembledAt: inputs.now,
            sections: [
                JobBrief.Section(kind: .siteAndHistory, items: siteItems(inputs, matches: matches)),
                JobBrief.Section(kind: .knownEquipment, items: equipmentItems(inputs, matches: matches)),
                JobBrief.Section(kind: .faultCandidates, items: faults.items),
                JobBrief.Section(kind: .crewLearnings, items: learningItems(inputs, matches: matches)),
                JobBrief.Section(kind: .partsAndPrerequisites,
                                 items: partsItems(inputs, candidates: faults.candidateTexts)),
            ],
            faultUnmatched: faults.unmatched)
    }

    // MARK: 1. Site and history

    /// Where the job's own details came from, in words.
    static func jobSourceCitation(_ job: UpcomingJob) -> String {
        switch job.origin {
        case .jobFile:
            let name = job.provenance?.fileName ?? "the job file"
            if let signer = job.provenance?.signer { return "Job file \(name), signed by \(signer)" }
            return "Job file \(name) (not signed)"
        case .spoken:
            return "Said when the job was added"
        case .typed:
            return "Typed on this phone"
        }
    }

    private static func siteItems(_ inputs: Inputs, matches: [JobHistoryIndex.Match]) -> [JobBrief.Item] {
        let job = inputs.job
        let source = jobSourceCitation(job)
        var items: [JobBrief.Item] = []
        if let customer = job.site.customer { items.append(.init(text: "Customer: \(customer).", citation: source)) }
        if let address = job.site.address { items.append(.init(text: "Address: \(address).", citation: source)) }
        if let contact = job.site.contact { items.append(.init(text: "Contact: \(contact).", citation: source)) }
        if let scheduled = job.scheduledFor {
            items.append(.init(text: "Booked for \(scheduled.formatted(date: .abbreviated, time: .shortened)).",
                               citation: source))
        }
        if let notes = job.notes { items.append(.init(text: "Notes: \(notes)", citation: source)) }
        for (index, match) in matches.prefix(visitLimit).enumerated() {
            let visit = match.visit
            let lead = index == 0 ? "Last visit" : "Earlier visit"
            let work = visit.workDone.isEmpty
                ? "no work recorded as done"
                : visit.workDone.prefix(3).joined(separator: "; ")
            items.append(.init(
                text: "\(lead) (\(match.reason.phrase)): \(visit.label), \(visit.outcomeLabel.lowercased()) — \(work).",
                citation: visit.citation))
        }
        return items
    }

    // MARK: 2. Known equipment

    private static func equipmentItems(_ inputs: Inputs, matches: [JobHistoryIndex.Match]) -> [JobBrief.Item] {
        let source = jobSourceCitation(inputs.job)
        var items: [JobBrief.Item] = []
        var described = Set<String>()
        for unit in inputs.job.equipment {
            guard let model = unit.model else {
                items.append(.init(text: "\(unit.summary): the model was not given.", citation: source))
                continue
            }
            described.formUnion(JobHistoryIndex.modelTokens(model))
            items.append(vaultLine(for: model, label: unit.summary, inputs: inputs, fallbackCitation: source))
        }
        // Machines earlier visits recorded here that the job itself does not name.
        for match in matches where match.reason != .model {
            for model in match.visit.models where JobHistoryIndex.modelTokens(model).isDisjoint(with: described) {
                described.formUnion(JobHistoryIndex.modelTokens(model))
                items.append(vaultLine(for: model, label: "\(model) (recorded on an earlier visit)",
                                       inputs: inputs, fallbackCitation: match.visit.citation))
            }
        }
        return items
    }

    private static func vaultLine(for model: String, label: String, inputs: Inputs,
                                  fallbackCitation: String) -> JobBrief.Item {
        let found = inputs.modelIndex.match(text: model)
        switch found.count {
        case 0:
            return .init(text: "\(label): not in the \(inputs.vaultName) vault.", citation: fallbackCitation)
        case 1:
            let entry = found[0]
            return .init(text: "\(label): in the vault as \(entry.heading).",
                         citation: "\(inputs.vaultName) vault › \(entry.file) › \(entry.name)")
        default:
            // Several models answer to it. Say which, and let the nameplate decide on site.
            let names = found.prefix(3).map(\.name).joined(separator: ", ")
            return .init(text: "\(label): could be any of \(found.count) models in the vault (\(names)); the nameplate will say which.",
                         citation: "\(inputs.vaultName) vault › \(found[0].file)")
        }
    }

    // MARK: 3. The fault report

    private struct FaultOutcome {
        var items: [JobBrief.Item]
        /// The candidates' own words, for the parts section to look part numbers up in.
        var candidateTexts: [String]
        var unmatched: Bool
    }

    /// One row of a vault table that names a code the report mentions.
    struct CodeRow: Equatable {
        let code: String
        let meaning: String
        let firstCheck: String?
        let file: String
        let heading: String?
    }

    private static func faultSection(_ inputs: Inputs, matches: [JobHistoryIndex.Match]) -> FaultOutcome {
        guard let report = inputs.job.faultReport else {
            return FaultOutcome(items: [], candidateTexts: [], unmatched: false)
        }
        let reportDate = report.receivedAt.formatted(date: .abbreviated, time: .omitted)
        var items = [JobBrief.Item(text: "Reported: \u{201C}\(report.text)\u{201D}",
                                   citation: "Fault report \(report.source.attribution), \(reportDate)")]

        // Ranked by evidence: a code-table row under a heading that names this job's machine,
        // then any other code-table row, then manual passages that cleared the evidence gate.
        let rows = codeRows(for: report.text, in: inputs.coreFiles)
        let equipmentWords = relevanceWords(inputs.job)
        let ranked = rows.enumerated().sorted { lhs, rhs in
            let l = relevant(lhs.element, to: equipmentWords) ? 0 : 1
            let r = relevant(rhs.element, to: equipmentWords) ? 0 : 1
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map { $0.element }

        var candidateTexts: [String] = []
        for row in ranked.prefix(candidateLimit) {
            var text = "\(row.code): \(row.meaning)"
            if let check = row.firstCheck { text += ". First check: \(check)" }
            text += "."
            candidateTexts.append(text)
            items.append(.init(text: text, citation: citation(for: row, vaultName: inputs.vaultName)))
        }
        let passages = inputs.manualPassages(report.text)
            .sorted { $0.score > $1.score }
            .prefix(passageLimit)
        for passage in passages {
            let excerpt = Self.excerpt(passage.text)
            candidateTexts.append(passage.text)
            items.append(.init(text: "The manual: \u{201C}\(excerpt)\u{201D}", citation: passage.citation))
        }

        guard !candidateTexts.isEmpty else {
            items.append(.init(text: "Nothing in the \(inputs.vaultName) vault or its manuals matches those words.",
                               citation: "Searched \(inputs.vaultName): core files and manuals"))
            return FaultOutcome(items: items, candidateTexts: [], unmatched: true)
        }

        // What was actually done on this machine before. History, never a diagnosis.
        let priorFixes = matches.prefix(visitLimit).filter { !$0.visit.workDone.isEmpty }
        for match in priorFixes {
            items.append(.init(
                text: "Recorded as done on \(match.visit.label) (\(match.reason.phrase)): "
                    + match.visit.workDone.prefix(3).joined(separator: "; ") + ". History, not a diagnosis.",
                citation: match.visit.citation))
        }
        return FaultOutcome(items: items, candidateTexts: candidateTexts, unmatched: false)
    }

    /// Code-shaped tokens a fault report mentions: a letter and a digit, two to six characters —
    /// "E223", "T01", "U0". A bare number is a pressure or a temperature, not a code.
    static func faultCodes(in text: String) -> [String] {
        let separators = CharacterSet.alphanumerics.inverted
        var seen = Set<String>()
        var codes: [String] = []
        for raw in text.components(separatedBy: separators) where (2...6).contains(raw.count) {
            let token = raw.uppercased()
            guard token.contains(where: \.isLetter), token.contains(where: \.isNumber),
                  seen.insert(token).inserted else { continue }
            codes.append(token)
        }
        return codes
    }

    /// Every table row in the core whose first cell is one of the report's codes.
    static func codeRows(for report: String,
                         in files: [(filename: String, contents: String)]) -> [CodeRow] {
        let codes = Set(faultCodes(in: report))
        guard !codes.isEmpty else { return [] }
        var rows: [CodeRow] = []
        for (filename, contents) in files {
            var heading: String?
            for line in contents.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") {
                    heading = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                    continue
                }
                guard trimmed.hasPrefix("|") else { continue }
                let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                    .dropFirst()
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard cells.count >= 2, codes.contains(cells[0].uppercased()), !cells[1].isEmpty else {
                    continue
                }
                let check = cells.count > 2 && !cells[2].isEmpty ? cells[2] : nil
                rows.append(CodeRow(code: cells[0], meaning: cells[1], firstCheck: check,
                                    file: filename, heading: heading))
            }
        }
        return rows
    }

    private static func citation(for row: CodeRow, vaultName: String) -> String {
        var parts = ["\(vaultName) vault", row.file]
        if let heading = row.heading, !heading.isEmpty { parts.append(heading) }
        return parts.joined(separator: " › ")
    }

    /// The words that say a table is about this job's machine: the makes and models the job names.
    private static func relevanceWords(_ job: UpcomingJob) -> Set<String> {
        var words = Set<String>()
        for unit in job.equipment {
            for word in (unit.model ?? "").lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            where word.count >= 3 {
                words.insert(word)
            }
        }
        return words
    }

    private static func relevant(_ row: CodeRow, to words: Set<String>) -> Bool {
        guard let heading = row.heading?.lowercased(), !words.isEmpty else { return false }
        let headingWords = Set(heading.components(separatedBy: CharacterSet.alphanumerics.inverted))
        return !headingWords.isDisjoint(with: words)
    }

    static func excerpt(_ text: String) -> String {
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > passageCharacters else { return collapsed }
        return String(collapsed.prefix(passageCharacters)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: 4. What the crew learned

    private static func learningItems(_ inputs: Inputs, matches: [JobHistoryIndex.Match]) -> [JobBrief.Item] {
        var items = inputs.learnings
        for match in matches {
            let visit = match.visit
            for followUp in visit.followUps {
                items.append(.init(text: "Follow-up left on \(visit.label): \(followUp)", citation: visit.citation))
            }
            for note in visit.debriefNotes {
                items.append(.init(text: "From the debrief of \(visit.label): \(note)", citation: visit.citation))
            }
        }
        return Array(items.prefix(learningLimit))
    }

    // MARK: 5. Parts and prerequisites

    private static func partsItems(_ inputs: Inputs, candidates: [String]) -> [JobBrief.Item] {
        guard !candidates.isEmpty else { return [] }
        let haystack = candidates.joined(separator: " ").uppercased()
        let tokens = Set(haystack.components(separatedBy: CharacterSet.alphanumerics
                                                .union(CharacterSet(charactersIn: "-")).inverted))
        var items: [JobBrief.Item] = []
        for part in inputs.partsIndex.parts where tokens.contains(part.number.uppercased()) {
            var text = "Part \(part.number): \(part.partDescription)"
            if !part.fits.isEmpty { text += " (fits \(part.fits))" }
            items.append(.init(text: text + ".",
                               citation: "\(inputs.vaultName) vault › \(part.file) › \(part.heading ?? "Parts")"))
        }
        // The safety notes of any procedure written for one of the codes the report names.
        let codes = Set(faultCodes(in: inputs.job.faultReport?.text ?? ""))
        for procedure in inputs.procedures where mentions(procedure, anyOf: codes) {
            for note in procedure.safetyNotes {
                items.append(.init(text: "Before \u{201C}\(procedure.title)\u{201D}: \(note)",
                                   citation: "\(inputs.vaultName) vault › procedure \(procedure.id)"))
            }
        }
        return items
    }

    private static func mentions(_ procedure: Procedure, anyOf codes: Set<String>) -> Bool {
        guard !codes.isEmpty else { return false }
        let text = ([procedure.title, procedure.description ?? ""] + procedure.steps.map(\.instruction))
            .joined(separator: " ")
        return !Set(faultCodes(in: text)).isDisjoint(with: codes)
    }
}

// MARK: - Speech

/// The brief, out loud (Plan FO §7). Bounded, because a brief nobody hears the end of is a brief
/// nobody heard; the rest of any section is one "say more about …" away, and the whole of it is on
/// the Job tab.
enum JobBriefSpeech {

    /// About a minute of speech.
    static let characterCap = 900
    /// How many lines of one section are read before the rest is offered.
    static let itemsPerSection = 2

    /// The whole brief, sections in order, each empty one said as empty.
    static func spoken(_ brief: JobBrief, title: String, characterCap: Int = characterCap) -> String {
        var parts = ["Brief for \(title)."]
        var used = parts[0].count
        var truncated = false
        for section in brief.sections {
            let line = sectionLine(section, limit: itemsPerSection)
            if used + line.count + 1 > characterCap {
                truncated = true
                // The heading still goes, so a technician knows the section exists.
                let short = "\(section.kind.title): say \u{201C}more about \(section.kind.spokenNames[0])\u{201D} to hear it."
                parts.append(short)
                used += short.count + 1
                continue
            }
            parts.append(line)
            used += line.count + 1
        }
        parts.append(truncated
                     ? "That's the short version."
                     : "Say \u{201C}more about\u{201D} a section, or \u{201C}take me there\u{201D} for directions.")
        return parts.joined(separator: " ")
    }

    /// Everything in one section — what "say more about the fault" reads.
    static func more(_ kind: JobBrief.SectionKind, in brief: JobBrief) -> String {
        sectionLine(brief.section(kind), limit: .max)
    }

    /// Which section a request names, or nil when it names none.
    static func section(named request: String) -> JobBrief.SectionKind? {
        let lowered = request.lowercased()
        return JobBrief.SectionKind.allCases.first { kind in
            kind.spokenNames.contains { lowered.contains($0) }
        }
    }

    private static func sectionLine(_ section: JobBrief.Section, limit: Int) -> String {
        guard !section.isEmpty else { return "\(section.kind.title): \(section.kind.emptyLine)" }
        let shown = section.items.prefix(limit).map(\.text)
        var line = "\(section.kind.title): " + shown.joined(separator: " ")
        let rest = section.items.count - shown.count
        if rest > 0 { line += " And \(rest) more." }
        return line
    }
}

// MARK: - The model's copy

/// The brief as the visit's model context carries it (Plan FO §7): a bounded block in the
/// continuity snapshot, headed and quoted like the rest of it, so the site visit starts from what
/// the technician heard on the way rather than from nothing.
///
/// A third block on the pattern of P3a's live block and P3b's debrief block, composed beside them
/// rather than inside either.
enum JobBriefContract {

    static let heading = "BRIEF BEFORE SITE:"
    static let characterLimit = 1_200
    static let lede = "Advisory context assembled by the app before the visit, each line with its source. None of it is a task, a reading or a diagnosis; the fault candidates are possibilities to check, not findings. The fault report is the office's or customer's words, unverified."

    static func lines(site: JobSite?, faultReport: FaultReport?, brief: JobBrief?) -> [String] {
        guard site?.isEmpty == false || faultReport != nil || brief != nil else { return [] }
        var protected = [heading, lede]
        if let headline = site?.headline { protected.append("SITE: " + quote(headline)) }
        if let faultReport { protected.append("FAULT REPORT: " + quote(faultReport.text)) }
        var remaining = characterLimit - protected.reduce(0) { $0 + $1.count + 1 }
        var kept: [String] = []
        if let brief {
            for section in brief.sections {
                for item in section.items {
                    let line = "BRIEF \(section.kind.rawValue.uppercased()): " + quote(item.text)
                        + " (source: " + quote(item.citation) + ")"
                    guard line.count + 1 <= remaining else { continue }
                    kept.append(line)
                    remaining -= line.count + 1
                }
            }
        }
        return protected + kept
    }

    private static func quote(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "\"[unavailable]\"" }
        return String(decoding: data, as: UTF8.self)
    }
}
