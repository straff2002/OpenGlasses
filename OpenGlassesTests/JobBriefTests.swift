import XCTest
@testable import OpenGlasses

/// Plan FO P3c — the brief before site, and the history index it reads. All pure: fixture core
/// files, fixture sessions, fixture manual passages. No vault registry, no network, no model.
@MainActor
final class JobBriefTests: XCTestCase {

    // MARK: - Fixtures

    private let may14 = Date(timeIntervalSince1970: 1_778_760_000)   // mid-May 2026
    private let april2 = Date(timeIntervalSince1970: 1_775_120_000)
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private let coreFiles: [(filename: String, contents: String)] = [
        (filename: "error_codes.md", contents: """
        # Error Codes

        ## Carrier (ComfortLink — 30RB / 30XA)

        | Code | Meaning | First-line check |
        |------|---------|-----------------|
        | E200 | Carrier's own E200 | Check the Carrier thing |

        ## Lennox (Energence / M3 controller)

        | Code | Meaning | First-line check |
        |------|---------|-----------------|
        | E200 | Low refrigerant pressure | Charge, evap airflow |
        | E201 | High refrigerant pressure | Condenser coil, fan |
        """),
        (filename: "models.md", contents: """
        ## SLP99UH090XV60CK (SLP99UHXV-090-60C, 090XV60C)

        Lennox furnace. Pressure switch kit 65W77.
        """),
        (filename: "parts.md", contents: """
        ## Parts

        | Part  | Description           | Fits          | Supersedes |
        |-------|-----------------------|---------------|------------|
        | 65W77 | Pressure switch kit   | SLP99         |            |
        """),
    ]

    private func session(id: String, reference: String?, startedAt: Date,
                         model: String? = nil, serial: String? = nil, site: JobSite? = nil,
                         done: [String] = [], deferred: [String] = [],
                         outcome: FieldSession.Outcome = .resolved) -> FieldSession {
        var session = FieldSession(id: id, vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
                                   startedAt: startedAt, endedAt: startedAt.addingTimeInterval(3_600),
                                   pausedAt: nil, resumedAt: nil, outcome: outcome, startLocation: nil,
                                   endLocation: nil, escalations: [], billableSeconds: 3_600)
        session.jobReference = reference
        session.site = site
        if let model {
            let identity = EquipmentIdentity(modelToken: model, heading: model, file: "models.md", source: .spoken)
            session.equipment = identity
            session.visitedUnits = [VisitedUnit(identity: identity, serial: serial, continuityScope: "initial",
                                                firstSeenAt: startedAt)]
        }
        session.tasks = done.map { FieldSession.Task(title: $0, origin: .operatorAdded, status: .done) }
            + deferred.map { FieldSession.Task(title: $0, origin: .recommended, status: .deferred) }
        return session
    }

    private func upcoming(reference: String? = "1007",
                          site: JobSite = JobSite(customer: "Smith & Co", address: "14 Smith St."),
                          fault: String? = "No heat. Display shows E200.",
                          equipment: [KnownEquipment] = [KnownEquipment(model: "Lennox SLP99UH090XV60CK", serial: "5919K01234")],
                          origin: UpcomingJob.Origin = .typed) -> UpcomingJob {
        UpcomingJob(id: "u1", jobReference: reference, site: site,
                    faultReport: fault.map { FaultReport(text: $0, source: .typed, receivedAt: now) },
                    equipment: equipment, origin: origin, createdAt: now)
    }

    private func passage(_ text: String, score: Float = 0.8) -> VaultRetriever.Passage {
        VaultRetriever.Passage(documentId: "d", documentName: "SLP99 Service Manual", chunkIndex: 0,
                               text: text, page: 44, section: "Fault codes", similarity: score, score: score,
                               matchedTokens: ["E200"], kind: .prose, figure: nil)
    }

    private func brief(job: UpcomingJob, sessions: [FieldSession] = [],
                       passages: [VaultRetriever.Passage] = [],
                       files: [(filename: String, contents: String)]? = nil) -> JobBrief {
        JobBriefAssembler.assemble(.init(job: job, history: JobHistoryIndex(sessions: sessions),
                                         vaultName: "Refrigeration", coreFiles: files ?? coreFiles,
                                         manualPassages: { _ in passages }, now: now))
    }

    // MARK: - The history index

    func testTheIndexFindsBySiteBySerialAndByModel() {
        let site = JobSite(customer: "Smith & Co", address: "14 Smith St.")
        let index = JobHistoryIndex(sessions: [
            session(id: "a", reference: "0993", startedAt: may14, site: JobSite(address: "14 smith st")),
            session(id: "b", reference: "0980", startedAt: april2, model: "SLP99UH090XV60CK", serial: "5919K-01234"),
            session(id: "c", reference: "0900", startedAt: april2, model: "CARRIER30RB"),
        ])
        XCTAssertEqual(index.visits(site: site).map(\.id), ["a"], "punctuation and case are not a different site")
        XCTAssertEqual(index.visits(serial: "5919K01234").map(\.id), ["b"], "a serial matches with its dashes dropped")
        XCTAssertEqual(index.visits(model: "Lennox SLP99UH090XV60CK").map(\.id), ["b"])
        XCTAssertTrue(index.visits(model: "SLP98UH090XV60CK").isEmpty, "a near model is not the model")
    }

    func testTheIndexOnlyKnowsTheSessionsItWasGiven() {
        // There is no other source: an index built from nothing knows nothing, however familiar
        // the job ahead looks. A visit made on another phone can never appear as history here.
        let index = JobHistoryIndex(sessions: [])
        XCTAssertTrue(index.matches(for: upcoming()).isEmpty)
        XCTAssertTrue(index.visits.isEmpty)
    }

    func testOpenAndCancelledVisitsAreNotHistory() {
        var open = session(id: "open", reference: "1", startedAt: may14, site: JobSite(address: "14 Smith St"))
        open.endedAt = nil
        open.outcome = .inProgress
        let cancelled = session(id: "x", reference: "2", startedAt: may14, site: JobSite(address: "14 Smith St"),
                                outcome: .cancelled)
        XCTAssertTrue(JobHistoryIndex(sessions: [open, cancelled]).visits.isEmpty)
    }

    func testAVisitMatchingSeveralWaysIsListedOnceWithItsStrongestReason() {
        let visit = session(id: "a", reference: "0993", startedAt: may14, model: "SLP99UH090XV60CK",
                            serial: "5919K01234", site: JobSite(address: "14 Smith St."))
        let matches = JobHistoryIndex(sessions: [visit]).matches(for: upcoming())
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.reason, .serial)
    }

    // MARK: - Every claim cites

    func testABriefFromFixturesCitesEveryLine() {
        let history = [session(id: "a", reference: "0993", startedAt: may14, model: "SLP99UH090XV60CK",
                               site: JobSite(address: "14 Smith St."), done: ["Replaced pressure switch"],
                               deferred: ["Check flue length"])]
        let result = brief(job: upcoming(), sessions: history, passages: [passage("E200 low pressure lockout: check the flue.")])
        XCTAssertFalse(result.allItems.isEmpty)
        for item in result.allItems {
            XCTAssertFalse(item.citation.trimmingCharacters(in: .whitespaces).isEmpty, "uncited: \(item.text)")
        }
        XCTAssertEqual(result.sections.map(\.kind), JobBrief.SectionKind.allCases, "always five, always in order")
    }

    func testSiteAndHistoryNameThePreviousVisitFromThisPhonesRecord() throws {
        let history = [session(id: "a", reference: "0993", startedAt: may14,
                               site: JobSite(address: "14 Smith St."), done: ["Replaced pressure switch"])]
        let section = brief(job: upcoming(), sessions: history).section(.siteAndHistory)
        let visit = try XCTUnwrap(section.items.first { $0.text.hasPrefix("Last visit") })
        XCTAssertTrue(visit.text.contains("Job 0993"))
        XCTAssertTrue(visit.text.contains("Replaced pressure switch"))
        XCTAssertTrue(visit.citation.contains("this phone's job history"))
        XCTAssertTrue(section.items.contains { $0.text == "Customer: Smith & Co." && $0.citation == "Typed on this phone" })
    }

    func testAJobFilesLinesCiteTheFileAndItsSigner() {
        var job = upcoming(origin: .jobFile)
        job.provenance = JobFileProvenance(fileName: "1007.ogjob", signature: .signed,
                                           signer: "Smith Refrigeration", digest: "abc")
        let section = brief(job: job).section(.siteAndHistory)
        XCTAssertEqual(section.items.first?.citation, "Job file 1007.ogjob, signed by Smith Refrigeration")
    }

    // MARK: - Empty is said, not skipped

    func testEmptySectionsAreSpokenAsEmpty() {
        let bare = UpcomingJob(id: "u", jobReference: "1008", origin: .spoken, createdAt: now)
        let result = brief(job: bare, files: [])
        XCTAssertTrue(result.section(.siteAndHistory).isEmpty)
        XCTAssertTrue(result.section(.knownEquipment).isEmpty)
        XCTAssertTrue(result.section(.faultCandidates).isEmpty)
        XCTAssertFalse(result.faultUnmatched, "no report is not an unmatched report")
        let spoken = JobBriefSpeech.spoken(result, title: bare.title)
        for kind in JobBrief.SectionKind.allCases {
            XCTAssertTrue(spoken.contains("\(kind.title): \(kind.emptyLine)"), "\(kind) was not said as empty")
        }
    }

    func testAnUnmatchedFaultReportSaysNothingMatches() throws {
        let job = upcoming(fault: "Customer says it smells funny", equipment: [])
        let result = brief(job: job)
        XCTAssertTrue(result.faultUnmatched)
        let items = result.section(.faultCandidates).items
        XCTAssertEqual(items.first?.text, "Reported: \u{201C}Customer says it smells funny\u{201D}")
        XCTAssertEqual(items.last?.text, "Nothing in the Refrigeration vault or its manuals matches those words.")
        XCTAssertTrue(result.section(.partsAndPrerequisites).isEmpty, "no candidates, no parts")
    }

    func testAModelTheVaultDoesNotKnowIsSaidToBeUnknown() throws {
        let job = upcoming(equipment: [KnownEquipment(model: "Daikin RXYQ", serial: nil)])
        let line = try XCTUnwrap(brief(job: job).section(.knownEquipment).items.first)
        XCTAssertEqual(line.text, "Daikin RXYQ: not in the Refrigeration vault.")
    }

    func testAKnownModelCitesItsVaultSection() throws {
        let line = try XCTUnwrap(brief(job: upcoming()).section(.knownEquipment).items.first)
        XCTAssertTrue(line.text.contains("in the vault as SLP99UH090XV60CK"))
        XCTAssertEqual(line.citation, "Refrigeration vault › models.md › SLP99UH090XV60CK")
    }

    // MARK: - Ranking follows evidence

    func testCandidatesRankByEvidenceNotBySourceOrder() {
        let result = brief(job: upcoming(), passages: [passage("weak manual hit", score: 0.3),
                                                       passage("strong manual hit", score: 0.9)])
        let texts = result.section(.faultCandidates).items.map(\.text)
        // The report first, then the code row under the heading naming this job's make, then the
        // other make's row, then manual passages strongest first.
        XCTAssertTrue(texts[0].hasPrefix("Reported:"))
        XCTAssertEqual(texts[1], "E200: Low refrigerant pressure. First check: Charge, evap airflow.")
        XCTAssertEqual(texts[2], "E200: Carrier's own E200. First check: Check the Carrier thing.")
        XCTAssertEqual(texts[3], "The manual: \u{201C}strong manual hit\u{201D}")
        XCTAssertEqual(texts[4], "The manual: \u{201C}weak manual hit\u{201D}")
        XCTAssertEqual(result.section(.faultCandidates).items[1].citation,
                       "Refrigeration vault › error_codes.md › Lennox (Energence / M3 controller)")
    }

    func testPriorFixesAreHistoryNotADiagnosis() throws {
        let history = [session(id: "a", reference: "0993", startedAt: may14, model: "SLP99UH090XV60CK",
                               done: ["Replaced pressure switch"])]
        let items = brief(job: upcoming(), sessions: history).section(.faultCandidates).items
        let prior = try XCTUnwrap(items.first { $0.text.hasPrefix("Recorded as done") })
        XCTAssertTrue(prior.text.hasSuffix("History, not a diagnosis."))
    }

    func testFaultCodesNeedALetterAndADigit() {
        XCTAssertEqual(JobBriefAssembler.faultCodes(in: "No heat, E200 at 20 psi, then U0 and t01"),
                       ["E200", "U0", "T01"])
        XCTAssertTrue(JobBriefAssembler.faultCodes(in: "running at 20 psi").isEmpty)
    }

    func testPartsFollowTheCandidates() throws {
        let files = coreFiles + [(filename: "extra.md", contents: """
        | Code | Meaning | First-line check |
        |------|---------|-----------------|
        | E999 | Pressure switch open | Replace with 65W77 |
        """)]
        let job = upcoming(fault: "E999 on the display")
        let parts = brief(job: job, files: files).section(.partsAndPrerequisites).items
        let part = try XCTUnwrap(parts.first)
        XCTAssertEqual(part.text, "Part 65W77: Pressure switch kit (fits SLP99).")
        XCTAssertEqual(part.citation, "Refrigeration vault › parts.md › Parts")
    }

    func testTheCrewSectionReadsEarlierFollowUpsAndTheLearningsSeam() {
        let history = [session(id: "a", reference: "0993", startedAt: may14, site: JobSite(address: "14 Smith St."),
                               deferred: ["Check flue length"])]
        let seam = [JobBrief.Item(text: "Crew note", citation: "Team learnings")]
        let result = JobBriefAssembler.assemble(.init(job: upcoming(), history: JobHistoryIndex(sessions: history),
                                                      vaultName: "Refrigeration", coreFiles: coreFiles,
                                                      learnings: seam, now: now))
        let items = result.section(.crewLearnings).items
        XCTAssertEqual(items.first, seam.first)
        XCTAssertTrue(items.contains { $0.text.contains("Check flue length") && $0.citation.contains("Job 0993") })
    }

    func testABriefNeverProducesATask() {
        // A brief is a value with no path to a session; the assembler takes no session to write to.
        // What it produces is five sections of cited text — asserted here so a later change that
        // makes a brief *do* something has to change this test first.
        let result = brief(job: upcoming())
        XCTAssertEqual(Set(result.sections.map(\.kind)), Set(JobBrief.SectionKind.allCases))
    }

    // MARK: - Speech

    func testTheSpokenBriefIsCappedAndOffersMore() {
        let long = (1...30).map { KnownEquipment(model: "Unknown model number \($0)", serial: nil) }
        let result = brief(job: upcoming(equipment: long))
        let spoken = JobBriefSpeech.spoken(result, title: "Job 1007")
        XCTAssertLessThanOrEqual(spoken.count, JobBriefSpeech.characterCap + 200)
        XCTAssertTrue(spoken.contains("And 28 more."))
    }

    func testMoreAboutASectionReadsAllOfIt() {
        let result = brief(job: upcoming(equipment: [KnownEquipment(model: "A1234"), KnownEquipment(model: "B1234"),
                                                    KnownEquipment(model: "C1234")]))
        let more = JobBriefSpeech.more(.knownEquipment, in: result)
        XCTAssertTrue(more.contains("A1234") && more.contains("B1234") && more.contains("C1234"))
        XCTAssertFalse(more.contains("more."))
    }

    func testASpokenRequestNamesItsSection() {
        XCTAssertEqual(JobBriefSpeech.section(named: "say more about the fault"), .faultCandidates)
        XCTAssertEqual(JobBriefSpeech.section(named: "what about parts"), .partsAndPrerequisites)
        XCTAssertEqual(JobBriefSpeech.section(named: "tell me about the last visit"), .siteAndHistory)
        XCTAssertNil(JobBriefSpeech.section(named: "what's the weather"))
    }

    // MARK: - The model's copy

    func testTheSnapshotBlockIsBoundedAndAbsentWithoutAnything() {
        XCTAssertTrue(JobBriefContract.lines(site: nil, faultReport: nil, brief: nil).isEmpty)
        let long = (1...80).map { KnownEquipment(model: "Model number \($0)") }
        let lines = JobBriefContract.lines(site: JobSite(address: "14 Smith St"),
                                           faultReport: FaultReport(text: "No heat", source: .typed),
                                           brief: brief(job: upcoming(equipment: long)))
        XCTAssertEqual(lines.first, JobBriefContract.heading)
        XCTAssertLessThanOrEqual(lines.joined(separator: "\n").count, JobBriefContract.characterLimit)
        XCTAssertTrue(lines.contains("FAULT REPORT: \"No heat\""))
    }

    func testALegacySessionsSnapshotHasNoBriefLines() {
        let legacy = session(id: "a", reference: "0993", startedAt: may14)
        let rendered = FieldSessionContextSnapshot.render(session: legacy, events: [])
        XCTAssertFalse(rendered.contains(JobBriefContract.heading))
    }

    func testAStartedJobAheadsSnapshotCarriesTheBrief() {
        var visit = session(id: "a", reference: "1007", startedAt: may14)
        visit.site = JobSite(address: "14 Smith St")
        visit.brief = brief(job: upcoming())
        let rendered = FieldSessionContextSnapshot.render(session: visit, events: [])
        XCTAssertTrue(rendered.contains(JobBriefContract.heading))
        XCTAssertTrue(rendered.contains("SITE: \"14 Smith St\""))
    }
}
