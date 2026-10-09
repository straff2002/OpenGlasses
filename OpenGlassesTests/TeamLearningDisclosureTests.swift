import XCTest
@testable import OpenGlasses

/// Plan FP P2 — "clear that it is a team learning", pinned in all four places: the spoken lead-in,
/// the citation, the badge flag, and the job's log and record — and kept out of every
/// customer-facing document.
///
/// Headless: a custom vault installed from a temporary folder, a temporary `DocumentStore`, a
/// fresh `FieldSessionService` and a fresh entry store.
@MainActor
final class TeamLearningDisclosureTests: XCTestCase {

    private typealias F = TeamLearningFixtures

    private var root: URL!
    private var store: DocumentStore!
    private var entries: LearningEntryStore!
    private var sessions: FieldSessionService!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?
    private var previousHipaa = false

    override func setUp() async throws {
        try await super.setUp()
        root = F.tempDirectory("TeamLearningDisclosure")
        previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousHipaa = Config.hipaaMode
        Config.hipaaMode = false
        previousEntitlement = EntitlementTestScope.grant(tier: .team)
        VaultRegistry.shared.resetCache()

        store = F.documentStore(in: root)
        entries = LearningEntryStore(directory: root.appendingPathComponent("entries", isDirectory: true))
        let manifest = try VaultImporter.install(from: F.writeVault(in: root))
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        _ = try await VaultImporter.syncDocuments(manifest: manifest, into: store)

        sessions = FieldSessionService(sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true))
        sessions.documentStore = store
        sessions.learningEntries = entries
        sessions.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 1.01)
        _ = try sessions.startSession(vaultId: F.vaultId, assetId: nil, jobReference: "WO-88")
    }

    override func tearDown() async throws {
        sessions.turnSourceID = nil
        sessions = nil
        entries = nil
        store = nil
        VaultImporter.uninstall(id: F.vaultId)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: root)
        if let previousEnabled { UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
        Config.hipaaMode = previousHipaa
        EntitlementTestScope.restore(previousEntitlement)
        try await super.tearDown()
    }

    @discardableResult
    private func publish(_ entry: LearningEntry) -> LearningEntry {
        entries.upsert(entry)
        LearningCorpus.publish(entry, vaults: [.init(id: F.vaultId, modelIndex: F.modelIndex())], store: store)
        return entry
    }

    private static let finding = "Fault ZX7 on a cold start means the pressure switch tubing is wet"

    private func events() throws -> [SessionLogger.Event] {
        let id = try XCTUnwrap(sessions.activeSession?.id ?? sessions.history.first?.id)
        let url = root.appendingPathComponent("sessions/\(id)/log.jsonl")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .compactMap { try? decoder.decode(SessionLogger.Event.self, from: Data($0.utf8)) }
    }

    // MARK: - 1. The lead-in

    func testTheLeadInIsExactWithAndWithoutTheCount() {
        XCTAssertEqual(TeamLearningDisclosure.leadIn(confirmedJobCount: nil),
                       "The manual doesn't cover this. Your crew's own finding:")
        XCTAssertEqual(TeamLearningDisclosure.leadIn(confirmedJobCount: 1),
                       "The manual doesn't cover this. Your crew's own finding:",
                       "one job is no count worth saying")
        XCTAssertEqual(TeamLearningDisclosure.leadIn(confirmedJobCount: 3),
                       "The manual doesn't cover this. Your crew's own finding, noted on 3 previous jobs:")

        let lead = TeamLearningDisclosure.leadIn(confirmedJobCount: 3)
        XCTAssertEqual(TeamLearningDisclosure.prepend(lead, to: "  Dry the tubing and re-route it. "),
                       lead + " Dry the tubing and re-route it.")
        let already = "The manual doesn\u{2019}t cover this. Your crew's own finding, noted on 3 previous jobs: dry it."
        XCTAssertEqual(TeamLearningDisclosure.prepend(lead, to: already), already,
                       "a reply that already opens with it is not prefaced twice")
    }

    // MARK: - All four, on a learning-only answer

    func testALearningOnlyAnswerCarriesAllFourDisclosures() throws {
        let entry = publish(F.entry(finding: Self.finding, role: "Service manager", jobs: ["j1", "j2", "j3"], count: 3))
        let lead = "The manual doesn't cover this. Your crew's own finding, noted on 3 previous jobs:"
        sessions.turnSourceID = "turn-1"

        let context = try XCTUnwrap(sessions.promptContext(turn: "what does ZX7 mean"))
        XCTAssertTrue(context.contains("Open your answer with exactly this sentence: \"\(lead)\""), context)

        // 1. The lead-in, composed by the app and put in front of the reply exactly once.
        let reply = "Dry the tubing and re-route it away from the inducer.\nSource: \(entry.citationName)"
        let spoken = sessions.applyTeamLearningDisclosure(to: reply)
        XCTAssertEqual(spoken, lead + " " + reply)
        XCTAssertEqual(sessions.applyTeamLearningDisclosure(to: reply), reply, "owed once, paid once")

        // 2. The citation is the §7.1 name, never a manual title.
        let evidence = try XCTUnwrap(sessions.answerEvidence)
        XCTAssertEqual(evidence.basis, .teamLearningOnly)
        XCTAssertEqual(evidence.citations, [entry.citationName])
        XCTAssertFalse(evidence.citations.contains { $0.contains("Test Manual") })
        let cited = CitationLineParser.parse(spoken)
        XCTAssertEqual(cited.map(\.title), [entry.citationName])

        // 3. The badge flag, on the evidence and on the chip.
        XCTAssertTrue(evidence.teamLearningBadge)
        XCTAssertTrue(cited.allSatisfy(\.isTeamLearning))

        // 4. The job's log and its record name the entry and the approver's role — never the words.
        let answered = try events().filter { $0.kind == .teamLearningAnswered }
        XCTAssertEqual(answered.count, 1)
        XCTAssertNil(answered.first?.text)
        XCTAssertEqual(answered.first?.payload?["entry_ids"]?.value as? [String], [entry.id])
        XCTAssertEqual(answered.first?.payload?["approved_by_roles"]?.value as? [String], ["Service manager"])
        XCTAssertEqual(answered.first?.payload?["learning_alone"]?.value as? Bool, true)
        let recorded = try XCTUnwrap(sessions.activeSession?.teamLearningAnswers)
        XCTAssertEqual(recorded.map(\.entryID), [entry.id])
        XCTAssertEqual(recorded.map(\.approvedByRole), ["Service manager"])
        XCTAssertEqual(recorded.map(\.answers), [1])
        XCTAssertEqual(sessions.workRecord()?.teamLearningAnswers?.map(\.entryID), [entry.id])

        // The prompt rebuilt after a tool call is the same answer, not a second one.
        _ = sessions.promptContext(turn: "what does ZX7 mean")
        XCTAssertEqual(try events().filter { $0.kind == .teamLearningAnswered }.count, 1)
        XCTAssertEqual(sessions.activeSession?.teamLearningAnswers?.first?.answers, 1)

        // A later turn that rests on it again counts as another answer.
        sessions.turnSourceID = "turn-2"
        _ = sessions.promptContext(turn: "and ZX7 again")
        XCTAssertEqual(sessions.activeSession?.teamLearningAnswers?.first?.answers, 2)
        XCTAssertEqual(sessions.applyTeamLearningDisclosure(to: "Same again."), lead + " Same again.")

        // A reply to some other turn owes nothing.
        _ = sessions.promptContext(turn: "ZX7")
        sessions.turnSourceID = "turn-3"
        XCTAssertEqual(sessions.applyTeamLearningDisclosure(to: "Unrelated."), "Unrelated.")

        // Never in the model's view of the job.
        XCTAssertFalse(context.contains("team_learning_answered"))
        XCTAssertFalse(sessions.promptContext()?.contains(entry.id) ?? false)
    }

    func testTheToolRoutesCarryTheSameLeadInInstruction() async throws {
        publish(F.entry(finding: Self.finding, count: 2))
        let looked = try await ManualLookupTool(documentStore: store, sessionService: sessions)
            .execute(args: ["query": "ZX7"])
        XCTAssertTrue(looked.hasPrefix("No manual passage for 'ZX7'."), looked)
        XCTAssertTrue(looked.contains("\"The manual doesn't cover this. Your crew's own finding, noted on 2 previous jobs:\""), looked)
        XCTAssertEqual(sessions.answerEvidence?.basis, .teamLearningOnly)
        XCTAssertEqual(sessions.activeSession?.teamLearningAnswers?.count, 1, "a live-mode answer is recorded too")
    }

    // MARK: - Beside the manual

    func testALearningBesideTheManualIsBadgedButOwesNoLeadInAndIsNotRecordedAsAlone() throws {
        publish(F.entry(finding: "On these units ZX9 also shows when the sight glass is fogged"))
        sessions.turnSourceID = "turn-1"
        _ = sessions.promptContext(turn: "the display shows ZX9")
        let evidence = try XCTUnwrap(sessions.answerEvidence)
        XCTAssertEqual(evidence.basis, .manualWithTeamLearning)
        XCTAssertTrue(evidence.teamLearningBadge)
        XCTAssertNil(evidence.disclosure?.leadIn)
        XCTAssertEqual(sessions.applyTeamLearningDisclosure(to: "Check the charge."), "Check the charge.")
        XCTAssertNil(sessions.activeSession?.teamLearningAnswers)
        XCTAssertTrue(try events().filter { $0.kind == .teamLearningAnswered }.isEmpty)
    }

    func testAManualOnlyAnswerCarriesNoBadge() throws {
        _ = sessions.promptContext(turn: "the display shows ZX9")
        let evidence = try XCTUnwrap(sessions.answerEvidence)
        XCTAssertEqual(evidence.basis, .manual)
        XCTAssertFalse(evidence.teamLearningBadge)
        XCTAssertNil(evidence.disclosure)
    }

    // MARK: - Never in a customer-facing document (contract §8)

    func testTheCustomerDocumentNeverCarriesIt() throws {
        let entry = publish(F.entry(finding: Self.finding, role: "Service manager"))
        sessions.turnSourceID = "turn-1"
        _ = sessions.promptContext(turn: "what does ZX7 mean")
        let reply = sessions.applyTeamLearningDisclosure(to: "Dry the tubing.\nSource: \(entry.citationName)")
        sessions.recordAssistantReply(reply, sourceID: "turn-1")
        sessions.turnSourceID = nil
        let ended = try sessions.endSession()
        let dir = root.appendingPathComponent("sessions/\(ended.id)", isDirectory: true)

        // The office's record has it.
        let office = try XCTUnwrap(SessionExporter.buildExport(sessionDir: dir))
        XCTAssertEqual(office.workRecord?.teamLearningAnswers?.map(\.entryID), [entry.id])
        XCTAssertTrue(office.citations.contains { $0.source == entry.citationName })

        // A customer's does not: not the answer record, not the citation.
        let customer = ReportTranscriptPolicy.decide(channel: .email, recipients: ["someone@example.org"],
                                                     carriesFiles: true, context: .init())
        XCTAssertEqual(customer.audience, .customer)
        let customerExport = try XCTUnwrap(SessionExporter.buildExport(sessionDir: dir, transcript: customer))
        XCTAssertNotNil(customerExport.workRecord)
        XCTAssertNil(customerExport.workRecord?.teamLearningAnswers)
        XCTAssertNil(customerExport.workRecord?.teamLearnings)
        XCTAssertFalse(customerExport.citations.contains { TeamLearningCitation.isTeamLearning($0.source) })
        XCTAssertTrue(customerExport.transcript.isEmpty)

        // …and no line a customer reads names it.
        let record = try XCTUnwrap(office.workRecord)
        for line in record.customerSummaryLines + record.summaryLines {
            XCTAssertFalse(line.contains(entry.id), line)
            XCTAssertFalse(line.contains("Team learning"), line)
        }

        // An older record, written before the field existed, still decodes.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "team_learning_answers"))
        let legacy = try decoder.decode(WorkRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.teamLearningAnswers)
    }
}
