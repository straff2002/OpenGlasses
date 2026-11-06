import Foundation

// Plan KM §5, P3 — coaching steps, on the technician's side.
//
// A coaching reply is instructions written by someone else. It reaches the assistant only when it
// answers a handover this phone sent, on the job that is still open, from the expert it went to —
// and the only way in is the token below: `AcceptedCoaching` can be made by `CoachingReplyMatch`
// and nothing else, and `FieldSessionService.loadCoaching(_:)` takes nothing else. The reply file's
// own type (`ExpertCoachingReply`) has no route to the job, the runner or the prompt.

/// What a coaching step hit in the vault's safety file (Plan KM §5): the words, the file, and the
/// rule that is read **before** the step. A step never overrides it.
struct CoachingStepSafety: Codable, Equatable, Sendable {
    /// The matched words, as `LearningSafetyCheck` found them.
    let terms: [String]
    /// The safety file the rule came from, or nil when only the fixed hazard list matched.
    let file: String?
    /// What is read first: the safety file's own heading and words for it, or — when no section
    /// names it — the standing rule.
    let rule: String
}

/// Coaching steps an expert sent, as the job keeps them (Plan KM P3).
///
/// **Made only by `CoachingReplyMatch`**, from a reply that answered this job's own handover; the
/// job's file is the only other place one comes from. The steps are the expert's words exactly as
/// they arrived, each with what it hit in the vault's safety file. The expert is named as the job's
/// own sent record names them, with the kind the organisation's list gives them.
struct ExpertCoachingReceived: Codable, Equatable, Sendable, Identifiable {

    struct Step: Codable, Equatable, Sendable {
        /// From 1.
        let number: Int
        /// As the expert wrote it. Read as written, never reworded.
        let instruction: String
        let reading: CoachingStep.Reading?
        let stopIf: String?
        /// Set when the step hit the safety file: read with that rule first, and flagged.
        let safety: CoachingStepSafety?
    }

    let coachingId: String
    /// The id the runner, the job's log and the record know it by: "coaching-1", "coaching-2".
    let procedureId: String
    let handoverId: String
    /// As the job's sent record names them, with the kind on the organisation's list.
    let expert: ExpertSnapshot
    let generationsSeen: [Int]
    let steps: [Step]
    let matchedBy: ExpertReplyReceived.MatchedBy
    let receivedAt: Date
    /// When the technician offered the steps as a team learning, once they have.
    var offeredAsTeamLearningAt: Date?

    var id: String { coachingId }

    /// "Sam Okafor (staff expert)".
    var credit: String { CoachingCredit.text(name: expert.name, kind: expert.kind) }

    var flaggedSteps: [Step] { steps.filter { $0.safety != nil } }

    fileprivate init(coachingId: String, procedureId: String, handoverId: String, expert: ExpertSnapshot,
                     generationsSeen: [Int], steps: [Step], matchedBy: ExpertReplyReceived.MatchedBy, receivedAt: Date) {
        self.coachingId = coachingId
        self.procedureId = procedureId
        self.handoverId = handoverId
        self.expert = expert
        self.generationsSeen = generationsSeen
        self.steps = steps
        self.matchedBy = matchedBy
        self.receivedAt = receivedAt
    }
}

/// The only key to the job: a coaching reply that answered this job's own handover. **Its init is
/// private to this file**, so nothing but `CoachingReplyMatch.match` can make one, and the loader
/// (`FieldSessionService.loadCoaching`) takes nothing else — a crafted file has no other way in.
struct AcceptedCoaching: Equatable {
    let sessionId: String
    let received: ExpertCoachingReceived

    fileprivate init(sessionId: String, received: ExpertCoachingReceived) {
        self.sessionId = sessionId
        self.received = received
    }
}

/// "Sam Okafor (contracted expert)", "Sam Okafor (staff expert)": how a walkthrough is credited.
enum CoachingCredit {
    static func text(name: String, kind: EscalationContact.Kind) -> String {
        switch kind {
        case .staff: return "\(name) (staff expert)"
        case .contracted: return "\(name) (contracted expert)"
        }
    }
}

/// Whether a coaching reply may go on the open job (Plan KM §5, P3). Pure.
///
/// **Loaded only when** this phone is not in Medical Compliance mode, the reply answers a handover
/// the **open** job sent (a job that is closed, or locked for the organisation's departure, takes
/// nothing), it is from the expert that handover went to — the list entry, the same card, only
/// generations sent (`ExpertReplyMatch.verify`) — and its steps are not already on the job.
/// Anything else is a file this phone didn't ask for, refused by name, and never loaded.
enum CoachingReplyMatch {

    enum Refusal: Error, Equatable {
        case medicalMode
        /// No job on this phone sent that handover.
        case unknownHandover
        /// A job on this phone sent it, but that job is no longer open.
        case jobClosed
        case otherSender
        case cardMismatch
        case generationNotSent
        /// The same steps are already on the job.
        case alreadyOnJob(procedureId: String)

        var message: String {
            switch self {
            case .medicalMode:
                return "Coaching steps aren't loaded in Medical Compliance mode."
            case .unknownHandover:
                return "That coaching doesn't answer a job this phone sent to an expert. It's a file this phone didn't ask for, so its steps weren't loaded."
            case .jobClosed:
                return "That coaching is for a job that's no longer open, so its steps weren't loaded."
            case .otherSender, .cardMismatch:
                return "That coaching isn't from the expert the job went to. It's a file this phone didn't ask for, so its steps weren't loaded."
            case .generationNotSent:
                return "That coaching mentions an update this phone never sent. It's a file this phone didn't ask for, so its steps weren't loaded."
            case .alreadyOnJob:
                return "Those coaching steps are already on the job."
            }
        }

        init(_ refusal: ExpertReplyMatch.Refusal) {
            switch refusal {
            case .unknownHandover: self = .unknownHandover
            case .otherSender: self = .otherSender
            case .cardMismatch: self = .cardMismatch
            case .generationNotSent: self = .generationNotSent
            }
        }
    }

    /// - Parameters:
    ///   - openJob: the job open on this phone, or nil.
    ///   - otherJobs: the rest this phone holds, only to tell "closed" from "unknown".
    ///   - organisationExperts: the organisation's list, for the expert's kind.
    ///   - coreFiles: the open job's vault core files, for the safety check.
    static func match(_ reply: ExpertCoachingReply, openJob: FieldSession?, otherJobs: [FieldSession],
                      lockedSessionIds: Set<String>, organisationExperts: [EscalationContact],
                      coreFiles: [(filename: String, contents: String)], medicalMode: Bool,
                      now: Date) -> Result<AcceptedCoaching, Refusal> {
        if medicalMode { return .failure(.medicalMode) }
        guard let job = openJob, job.endedAt == nil, !lockedSessionIds.contains(job.id),
              ExpertReplyMatch.session(sending: reply.handoverId, in: [job]) != nil else {
            let elsewhere = ExpertReplyMatch.session(sending: reply.handoverId, in: otherJobs + [openJob].compactMap { $0 })
            return .failure(elsewhere == nil ? .unknownHandover : .jobClosed)
        }
        let verified: (expert: ExpertSnapshot, matchedBy: ExpertReplyReceived.MatchedBy)
        switch ExpertReplyMatch.verify(handoverId: reply.handoverId, expert: reply.expert,
                                       generationsSeen: reply.generationsSeen, on: job) {
        case .failure(let refusal): return .failure(Refusal(refusal))
        case .success(let value): verified = value
        }
        let held = job.expertCoaching ?? []
        if let already = held.first(where: { $0.coachingId == reply.coachingId }) {
            return .failure(.alreadyOnJob(procedureId: already.procedureId))
        }
        // The kind the organisation gives them: contracted if the sent record or the list says so.
        let listed = organisationExperts.first { $0.id == verified.expert.id }
        let kind: EscalationContact.Kind = verified.expert.kind == .contracted || listed?.kind == .contracted
            ? .contracted : .staff
        let expert = ExpertSnapshot(id: verified.expert.id, name: verified.expert.name, kind: kind)
        let steps = reply.steps.enumerated().map { index, step in
            ExpertCoachingReceived.Step(number: index + 1, instruction: step.instruction, reading: step.reading,
                                        stopIf: step.stopIf, safety: CoachingSafety.assess(step, coreFiles: coreFiles))
        }
        let received = ExpertCoachingReceived(
            coachingId: reply.coachingId, procedureId: CoachingProcedure.procedureId(ordinal: held.count + 1),
            handoverId: reply.handoverId, expert: expert,
            generationsSeen: Array(Set(reply.generationsSeen)).sorted(), steps: steps,
            matchedBy: verified.matchedBy, receivedAt: now)
        return .success(AcceptedCoaching(sessionId: job.id, received: received))
    }

    /// What the technician is told when the steps are on the job.
    static func confirmation(_ received: ExpertCoachingReceived) -> String {
        let count = received.steps.count == 1 ? "1 step" : "\(received.steps.count) steps"
        var line = "\(received.credit) sent \(count) for this job. Say \u{201C}walk \(CoachingProcedure.firstName(received.expert.name))'s steps\u{201D} to go through them."
        let flagged = received.flaggedSteps.count
        if flagged > 0 {
            line += flagged == 1
                ? " One step touches the safety rules; its rule is read first."
                : " \(flagged) steps touch the safety rules; each one's rule is read first."
        }
        return line
    }
}

/// Every coaching step through `LearningSafetyCheck`'s matcher (Plan KM §5). Pure.
///
/// A step that collides is read with **the rule first**: the section of the vault's safety file
/// whose heading — or failing that whose words — the match came from, in the file's own words; or,
/// when the match came only from the fixed hazard list and no section names it, the standing rule.
/// A step never overrides a safety rule, and the record flags every step that hit one.
enum CoachingSafety {

    static let ruleLimit = 400

    static func assess(_ step: CoachingStep, coreFiles: [(filename: String, contents: String)]) -> CoachingStepSafety? {
        let finding = LearningSafetyCheck.check(finding: step.instruction, symptom: step.stopIf,
                                                fix: step.reading?.quantity, coreFiles: coreFiles)
        guard finding.collides else { return nil }
        let terms = Set(finding.terms)
        if let section = section(matching: terms, in: coreFiles) {
            return CoachingStepSafety(terms: finding.terms, file: section.file, rule: section.rule)
        }
        return CoachingStepSafety(terms: finding.terms, file: nil, rule: standingRule(terms: finding.terms))
    }

    /// "This step touches gas and ignition. The vault's safety rules for them come first, and no
    /// coaching step overrides one."
    static func standingRule(terms: [String]) -> String {
        let listed: String
        switch terms.count {
        case 0: listed = "the safety rules"
        case 1: listed = terms[0]
        default: listed = terms.dropLast().joined(separator: ", ") + " and " + terms[terms.count - 1]
        }
        return "This step touches \(listed). The vault's safety rules for it come first, and no coaching step overrides one."
    }

    /// The first safety-file section a term names: by heading first, then by its words.
    static func section(matching terms: Set<String>,
                        in coreFiles: [(filename: String, contents: String)]) -> (file: String, rule: String)? {
        let files = coreFiles.filter { $0.filename.lowercased().contains("safety") }
        let parsed = files.map { (file: $0.filename, sections: sections(of: $0.contents)) }
        for pass in 0..<2 {
            for entry in parsed {
                for section in entry.sections {
                    let words = pass == 0
                        ? LearningSafetyCheck.headingTerms(in: "## " + section.heading)
                        : LearningSafetyCheck.words(in: section.body.joined(separator: " "))
                    if !words.isDisjoint(with: terms) { return (entry.file, rule(section)) }
                }
            }
        }
        return nil
    }

    struct Section: Equatable {
        let heading: String
        let body: [String]
    }

    /// The `##` (and deeper) sections of a safety file, each with its lines.
    static func sections(of contents: String) -> [Section] {
        var result: [Section] = []
        var heading: String?
        var body: [String] = []
        func close() {
            if let heading { result.append(Section(heading: heading, body: body)) }
            body = []
        }
        for raw in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("##") {
                close()
                heading = String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#") {
                close()
                heading = nil
            } else if heading != nil, !line.isEmpty {
                body.append(line)
            }
        }
        close()
        return result
    }

    /// "Gas safety: Shut the gas off at the appliance valve before …" — the heading and its first
    /// lines, in the file's words, bullets dropped, cut at a word near the limit.
    static func rule(_ section: Section) -> String {
        let lines = section.body.prefix(3).map { line -> String in
            var text = Substring(line)
            while let first = text.first, "-*•>".contains(first) { text = text.dropFirst() }
            return text.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        let text = lines.isEmpty ? section.heading : section.heading + ": " + lines.joined(separator: " ")
        guard text.count > ruleLimit else { return text }
        let cut = text.prefix(ruleLimit)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end]) + "…"
    }
}

/// The coaching steps as a procedure the runner walks (Plan KM §5, P3). Pure.
///
/// One step at a time, in the expert's order; each is a step of its own, so a reading taken while
/// it runs is recorded against it. A step with a "stop if" offers two ways on: `continue`, and
/// `stop`, which ends the walkthrough at a stop step that says to call the expert back. The last
/// step leads to an end step. Only those two closing steps are the app's words; every other step is
/// the expert's, **as written** — `isVerbatim` holds the procedure to that.
///
/// It lives with the job and nowhere else: built in memory from the job's own record whenever it
/// is started or recovered, never written to a vault, and never in `ProcedureLibrary`.
enum CoachingProcedure {

    static let idPrefix = "coaching-"
    static let stopStepId = "stop"
    static let endStepId = "end"

    static func procedureId(ordinal: Int) -> String { idPrefix + String(ordinal) }

    static func isCoachingId(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    static func stepId(_ number: Int) -> String { "step-\(number)" }

    /// The first word of a name, for "walk Sam's steps".
    static func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    static func procedure(for received: ExpertCoachingReceived) -> Procedure {
        let count = received.steps.count
        let credit = received.credit
        let first = firstName(received.expert.name)
        var steps: [Procedure.Step] = received.steps.map { step in
            let next = step.number < count ? stepId(step.number + 1) : endStepId
            let branches: [Procedure.Branch] = step.stopIf.map { stopIf in
                [Procedure.Branch(id: "continue", condition: "The stop-if doesn't apply: go on to the next step", next: next),
                 Procedure.Branch(id: "stop", condition: "Stop if: \(stopIf)", next: stopStepId)]
            } ?? []
            return Procedure.Step(
                id: stepId(step.number), title: "Step \(step.number) of \(count)",
                instruction: step.instruction,
                expectedInput: step.reading?.phrase,
                safetyNote: step.safety?.rule,
                branches: branches, defaultNext: next)
        }
        steps.append(Procedure.Step(
            id: stopStepId, title: "Stopped",
            instruction: "Stop here, as \(first)'s step says. Call \(first) back before going on.",
            terminal: true, outcome: "escalated"))
        steps.append(Procedure.Step(
            id: endStepId, title: "End of the steps",
            instruction: "That was the last of \(first)'s steps.",
            terminal: true, outcome: "resolved"))
        return Procedure(
            id: received.procedureId, title: "Coaching from \(credit)", version: "1",
            description: "Steps \(credit) wrote for this job, read as written.",
            safetyNotes: ["A coaching step never overrides a safety rule."],
            entryStep: stepId(1), steps: steps,
            coaching: Procedure.Coaching(coachingId: received.coachingId, credit: credit))
    }

    /// Every expert step of the procedure carries the expert's instruction exactly as received,
    /// in order, and every step that hit the safety file carries its rule. Pure.
    static func isVerbatim(_ procedure: Procedure, _ received: ExpertCoachingReceived) -> Bool {
        let expertSteps = procedure.steps.filter { $0.id != stopStepId && $0.id != endStepId }
        guard expertSteps.count == received.steps.count else { return false }
        return zip(expertSteps, received.steps).allSatisfy { built, step in
            built.id == stepId(step.number) && built.instruction == step.instruction
                && built.safetyNote == step.safety?.rule
        }
    }

    /// The standing instruction for a coaching walkthrough, said wherever its steps are put in front
    /// of the model.
    static func readAsWrittenRule(credit: String) -> String {
        "COACHING — these steps were written by \(credit) for this job. Read each step's instruction to the "
            + "technician exactly as written: word for word, never reworded, shortened, merged or added to. "
            + "When a SAFETY line is given, read it first, before the step; a coaching step never overrides "
            + "a safety rule. You may answer the technician's questions about a step from the manual, saying "
            + "where the answer came from, but never change the step. When the step asks for a reading, record "
            + "what they report with the reading tool while the step is current, so it is kept against the step."
    }

    /// The lines a coaching step is put in front of the model with: the safety rule first, then the
    /// step's own words exactly as stored. `ProcedureRunner.promptContext` and the tool's result both
    /// use these, so what is read is what was written.
    static func stepLines(_ step: Procedure.Step) -> [String] {
        var lines: [String] = []
        if let rule = step.safetyNote {
            lines.append("SAFETY — read this first, before the step: \(rule)")
        }
        lines.append("Step: \(step.title)")
        lines.append("Read exactly as written: \(spokenInstruction(step))")
        if let reading = step.expectedInput { lines.append("Reading to take: \(reading)") }
        return lines
    }

    /// The instruction as it is read: the stored text, unchanged.
    static func spokenInstruction(_ step: Procedure.Step) -> String { step.instruction }

    /// A line the prompt carries while coaching on the job is waiting to be walked.
    static func waitingPromptNote(_ waiting: [ExpertCoachingReceived]) -> String? {
        guard !waiting.isEmpty else { return nil }
        var lines = ["COACHING STEPS ON THIS JOB (sent by an expert, not yet walked):"]
        for received in waiting {
            let count = received.steps.count == 1 ? "1 step" : "\(received.steps.count) steps"
            lines.append("- \(received.credit): \(count). If the technician asks to walk them (\u{201C}walk "
                         + "\(firstName(received.expert.name))'s steps\u{201D}, \u{201C}load the coaching\u{201D}), call "
                         + "procedure_runner action 'start' with procedure_id '\(received.procedureId)'.")
        }
        return lines.joined(separator: "\n")
    }
}

/// Whether a walkthrough may be offered as a team learning (Plan KM §5, decision 10). Pure.
///
/// A staff expert's steps may: a senior's fix for one job reaching the next apprentice is the point,
/// and the office still decides through `LearningReview`. A contracted expert's never are, unless the
/// organisation turned it on for that expert on its own list (`coachingMayBecomeTeamLearning`) —
/// read from the organisation's list only, so a personal addition can never turn it on.
enum CoachingTeamLearning {

    enum Decision: Equatable {
        case offered
        case notOffered(String)
    }

    static let contractedReason = "A contracted expert's steps aren't offered as a team learning unless your organisation's agreement with them covers it."
    static let alreadyOffered = "Those steps were already offered as a team learning."

    static func decide(_ received: ExpertCoachingReceived, organisationExperts: [EscalationContact]) -> Decision {
        if received.offeredAsTeamLearningAt != nil { return .notOffered(alreadyOffered) }
        let listed = organisationExperts.first { $0.id == received.expert.id }
        switch received.expert.kind {
        case .staff where listed?.kind != .contracted:
            return .offered
        default:
            return listed?.kind == .contracted && listed?.coachingMayBecomeTeamLearning == true
                ? .offered : .notOffered(contractedReason)
        }
    }

    /// The candidate's finding: the steps as the expert wrote them, credited to the expert.
    static func finding(_ received: ExpertCoachingReceived, jobReference: String?) -> String {
        let job = jobReference.map { "job \($0)" } ?? "a job"
        var lines = ["Coaching steps written by \(received.credit) and walked on \(job), offered for the team. Credit: \(received.expert.name)."]
        for step in received.steps {
            var line = "\(step.number). \(step.instruction)"
            if let reading = step.reading { line += " Reading: \(reading.phrase)." }
            if let stopIf = step.stopIf { line += " Stop if: \(stopIf)" }
            if step.safety != nil { line += " (Touches the safety rules.)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

/// An expert's coaching as the job's record shows it (Plan KM §5, P3): who it is credited to, each
/// step as written, the safety rule read first where a step hit one, and what was found at each
/// step — the readings taken while that step was current. Built from the job alone. Pure.
struct CoachingWalkthrough: Codable, Equatable {

    struct Step: Codable, Equatable {
        let number: Int
        /// As the expert wrote it.
        let instruction: String
        /// "inducer pressure switch, in inWC", when the step asked for one.
        let readingToTake: String?
        let stopIf: String?
        /// The rule read before the step: set exactly when the step hit the safety file (flagged).
        let safetyRule: String?
        /// The readings taken at this step, as the record prints them.
        let found: [String]

        var safetyFlagged: Bool { safetyRule != nil }

        enum CodingKeys: String, CodingKey {
            case number, instruction, found
            case readingToTake = "reading_to_take"
            case stopIf = "stop_if"
            case safetyRule = "safety_rule"
        }
    }

    let procedureId: String
    /// "Sam Okafor (contracted expert)". Nil on a customer's report with the organisation's
    /// switch off (Plan KM P4, decision 8): the steps are shown as work done, with no name and no
    /// kind (`uncredited`).
    let credit: String?
    let expertKind: EscalationContact.Kind?
    let receivedAt: Date
    /// `not_started`, `in_progress`, or the outcome it finished with (`resolved`, `escalated`, …).
    let status: String
    let steps: [Step]

    enum CodingKeys: String, CodingKey {
        case credit, status, steps
        case procedureId = "procedure_id"
        case expertKind = "expert_kind"
        case receivedAt = "received_at"
    }

    static let notStarted = "not_started"
    static let inProgress = "in_progress"

    static func build(session: FieldSession) -> [CoachingWalkthrough] {
        (session.expertCoaching ?? []).map { received in
            let task = session.tasks.last { $0.procedureId == received.procedureId }
            let status: String
            if let task {
                status = task.procedureOutcome ?? (task.status.isOpen ? inProgress : task.status.rawValue)
            } else {
                status = notStarted
            }
            let readings = session.spokenReadings.filter { $0.procedureId == received.procedureId && !$0.isRuleChain }
            let chains = SpokenReadingLedger.chains(readings)
            let steps = received.steps.map { step in
                let stepId = CoachingProcedure.stepId(step.number)
                return Step(number: step.number, instruction: step.instruction,
                            readingToTake: step.reading?.phrase, stopIf: step.stopIf,
                            safetyRule: step.safety?.rule,
                            found: chains.filter { $0.original.procedureStepId == stepId }.map { SpokenReadingLedger.line(for: $0) })
            }
            return CoachingWalkthrough(procedureId: received.procedureId, credit: received.credit,
                                       expertKind: received.expert.kind, receivedAt: received.receivedAt,
                                       status: status, steps: steps)
        }
    }

    /// The same steps for a customer's report with expert time not shown (Plan KM P4): as work
    /// done, with neither the expert's name nor their kind. The steps, readings and findings stay.
    var uncredited: CoachingWalkthrough {
        CoachingWalkthrough(procedureId: procedureId, credit: nil, expertKind: nil, receivedAt: receivedAt,
                            status: status, steps: steps)
    }

    /// The walkthrough in the record's words, one line at a time.
    var lines: [String] {
        let state: String
        switch status {
        case Self.notStarted: state = "not walked yet"
        case Self.inProgress: state = "being walked"
        default: state = "finished as " + WorkRecord.prettyLabel(status).lowercased()
        }
        var lines = [credit.map { "Coaching steps from \($0), read as written — \(state)." }
                     ?? "\(ExpertTimeAudience.uncreditedSteps) — \(state)."]
        for step in steps {
            lines.append("  Step \(step.number): \(WorkRecord.terminated(step.instruction))")
            if let rule = step.safetyRule {
                lines.append("    Safety rule read first (this step touches the safety rules): \(WorkRecord.terminated(rule))")
            }
            if let reading = step.readingToTake { lines.append("    Reading asked for: \(reading).") }
            if let stopIf = step.stopIf { lines.append("    Stop if: \(WorkRecord.terminated(stopIf))") }
            lines.append(contentsOf: step.found.map { "    Found: \(WorkRecord.terminated($0))" })
        }
        return lines
    }
}
