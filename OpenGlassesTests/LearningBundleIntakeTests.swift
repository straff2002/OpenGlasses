import XCTest
@testable import OpenGlasses

/// Plan FP P3 — `LearningBundleIntake`: a bundle from another phone is untrusted input. Nothing in a
/// decisions bundle is applied until it is accepted; `accept(entryIDs:)` publishes exactly those
/// through the corpus; `discard()` leaves no trace; HIPAA refuses every bundle and the licence
/// gates entries and statuses (never a retraction); imported candidates land in the review queue
/// and go through `LearningReview` with the author-as-approver rule, exactly like local ones.
///
/// Headless: fresh stores over a temporary directory, a temporary `DocumentStore`, one injected
/// vault that knows the model, and a status recorder in place of the session service.
@MainActor
final class LearningBundleIntakeTests: XCTestCase {

    private typealias F = TeamLearningFixtures

    private var root: URL!
    private var candidates: LearningCandidateStore!
    private var entries: LearningEntryStore!
    private var documents: DocumentStore!
    private var intake: LearningBundleIntake!
    private var recorded: [(id: String, status: LearningCandidate.Status, inUse: Bool)] = []
    private var granted: FieldAssistCapabilityCheck = .granted
    private var hipaa = false
    private var reviewer = true

    override func setUp() {
        super.setUp()
        root = F.tempDirectory("LearningBundleIntake")
        candidates = LearningCandidateStore(directory: root.appendingPathComponent("candidates", isDirectory: true))
        entries = LearningEntryStore(directory: root.appendingPathComponent("entries", isDirectory: true))
        documents = F.documentStore(in: root)
        intake = LearningBundleIntake(candidates: candidates, entries: entries, documentStore: documents)
        intake.capability = { [unowned self] in self.granted }
        intake.hipaaMode = { [unowned self] in self.hipaa }
        intake.isReviewerDevice = { [unowned self] in self.reviewer }
        intake.vaults = { [LearningCorpus.VaultTarget(id: F.vaultId, modelIndex: F.modelIndex())] }
        intake.recordStatus = { [unowned self] candidate, inUse in
            self.recorded.append((candidate.id, candidate.status, inUse))
        }
        intake.clock = { Date(timeIntervalSince1970: 1_800_001_000) }
    }

    override func tearDown() {
        intake = nil
        documents = nil
        entries = nil
        candidates = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var published: [String] {
        documents.list().filter { DocumentStore.isLearningNamespace($0.namespace) }.map(\.id).sorted()
    }

    private func decisions(_ entries: [LearningEntry], retracted: [LearningBundle.Retraction] = [],
                           statuses: [LearningBundle.Status] = [], issuedAt: Int64 = 1_800_000_000,
                           sequence: Int64? = nil) -> Data {
        LearningBundle(direction: .decisions, organisationLabel: "Northbridge", issuedAt: issuedAt, sequence: sequence,
                       statuses: statuses, entries: entries.map(LearningBundle.Entry.init), retracted: retracted).encoded()
    }

    // MARK: - Nothing without accept

    func testNothingFromADecisionsBundleIsAppliedUntilItIsAccepted() throws {
        let one = F.entry(), two = F.entry(finding: "The inducer bearing squeals below freezing")
        let receipt = try intake.receive(decisions([one, two])).get()
        guard case .staged(let pending) = receipt else { return XCTFail("a decisions bundle is staged") }
        XCTAssertEqual(pending.entries.map(\.entryID), [one.id, two.id])
        XCTAssertEqual(pending.entries.map(\.change), [.new, .new])
        XCTAssertEqual(pending.entries.first?.text, LearningCorpus.documentText(one), "the full literal text")
        XCTAssertEqual(pending.entries.first?.citationName, one.citationName)
        XCTAssertEqual(entries.entries, [], "nothing stored")
        XCTAssertEqual(published, [], "nothing published")
        XCTAssertEqual(intake.pending, pending)
    }

    func testAcceptPublishesExactlyTheEntriesNamedThroughTheCorpus() throws {
        let one = F.entry(), two = F.entry(finding: "The inducer bearing squeals below freezing")
        _ = try intake.receive(decisions([one, two])).get()
        let report = try intake.accept(entryIDs: [two.id]).get()
        XCTAssertEqual(report.entriesChanged, [two.id])
        XCTAssertEqual(entries.entries.map(\.id), [two.id])
        XCTAssertEqual(published, [LearningCorpus.documentId(entryID: two.id, vaultId: F.vaultId)])
        XCTAssertEqual(intake.pending?.entries.map(\.entryID), [one.id], "the rest still waits")

        _ = try intake.acceptAll().get()
        XCTAssertNil(intake.staged, "nothing left waiting")
        XCTAssertEqual(published, [one.id, two.id].map { LearningCorpus.documentId(entryID: $0, vaultId: F.vaultId) }.sorted())
    }

    func testAcceptingAnIdNotInTheFileRefusesTheWholeRequest() throws {
        _ = try intake.receive(decisions([F.entry()])).get()
        let stray = LearningCandidate.newID()
        XCTAssertEqual(intake.accept(entryIDs: [stray]).failureValue, .unknownItems([stray]))
        XCTAssertEqual(entries.entries, [])
        XCTAssertEqual(intake.accept(entryIDs: []).failureValue, nil, "accepting nothing is not an error")
    }

    func testDiscardLeavesNoTrace() throws {
        let entry = F.entry()
        _ = try intake.receive(decisions([entry], retracted: [.init(entryID: LearningCandidate.newID(),
                                                                    retractedAt: 5, reason: "Gone")])).get()
        intake.discard()
        XCTAssertNil(intake.staged)
        XCTAssertNil(intake.pending)
        XCTAssertEqual(entries.entries, [])
        XCTAssertEqual(entries.bundleLedger, LearningBundleLedger(), "no tombstone, no watermark")
        XCTAssertEqual(published, [])
        XCTAssertEqual(intake.acceptAll().failureValue, .nothingStaged)
        // …and the stores on disk agree after a restart.
        let reread = LearningEntryStore(directory: root.appendingPathComponent("entries", isDirectory: true))
        XCTAssertEqual(reread.entries, [])
    }

    func testARetractionAcceptedTakesTheEntryOutOfRetrievalAndKeepsItAsHistory() throws {
        let entry = F.entry()
        _ = try intake.receive(decisions([entry])).get()
        _ = try intake.acceptAll().get()
        XCTAssertEqual(published.count, 1)
        _ = try intake.receive(decisions([], retracted: [.init(entryID: entry.id, retractedAt: 1_800_000_500,
                                                               reason: "Board revision changed")],
                                         issuedAt: 1_800_000_600)).get()
        XCTAssertEqual(intake.pending?.retractions.first?.isHeld, true)
        _ = try intake.accept(entryIDs: [entry.id]).get()
        XCTAssertEqual(published, [])
        XCTAssertEqual(entries.entries.first?.retractionReason, "Board revision changed")
    }

    // MARK: - Ordering

    func testAnOlderDecisionsBundleFromTheSameOrganisationIsRefusedOnceANewerOneIsApplied() throws {
        _ = try intake.receive(decisions([F.entry()], issuedAt: 1_800_000_000)).get()
        _ = try intake.acceptAll().get()
        XCTAssertEqual(intake.receive(decisions([F.entry()], issuedAt: 1_799_999_999)).failureValue,
                       .bundle(.reordered))
        XCTAssertNotNil(try? intake.receive(decisions([F.entry()], issuedAt: 1_800_000_000)).get(),
                        "the same issue time again is a replay, not a reorder")
    }

    // MARK: - Gates

    func testHIPAAModeRefusesEveryBundleInAndEveryAccept() throws {
        hipaa = true
        XCTAssertEqual(intake.receive(decisions([F.entry()])).failureValue, .hipaa)
        hipaa = false
        _ = try intake.receive(decisions([F.entry()])).get()
        hipaa = true
        XCTAssertEqual(intake.acceptAll().failureValue, .hipaa)
        XCTAssertEqual(entries.entries, [])
    }

    func testWithoutTheCapabilityOnlyARetractionCanBeAccepted() throws {
        let held = F.entry()
        _ = try intake.receive(decisions([held])).get()
        _ = try intake.acceptAll().get()

        granted = .denied(.expired(Date(timeIntervalSince1970: 1)))
        let fresh = F.entry(finding: "A new finding")
        _ = try intake.receive(decisions([fresh], retracted: [.init(entryID: held.id, retractedAt: 1_800_000_900,
                                                                    reason: "Wrong unit")],
                                         issuedAt: 1_800_001_000)).get()
        XCTAssertEqual(intake.accept(entryIDs: [fresh.id]).failureValue,
                       .notEntitled(FieldAssistPaywallCopy.teamLearningsBundleLapsed))
        XCTAssertNil(entries.entry(id: fresh.id))
        _ = try intake.accept(entryIDs: [held.id]).get()
        XCTAssertFalse(entries.entry(id: held.id)?.isLive ?? true, "taking an answer out of service is always allowed")
        XCTAssertEqual(published, [])
    }

    // MARK: - Candidates on the reviewer's device

    func testImportedCandidatesLandInTheReviewQueueAndAreNeverAutoApproved() throws {
        let fromField = F.candidate(author: "Sam Tane")
        let data = LearningBundle(direction: .candidates, organisationLabel: "Northbridge", issuedAt: 1_800_000_000,
                                  candidates: [.init(fromField)]).encoded()
        let receipt = try intake.receive(data).get()
        guard case .imported(let report, _) = receipt else { return XCTFail("candidates are imported, not staged") }
        XCTAssertEqual(report.candidatesAdded, [fromField.id])
        let stored = try XCTUnwrap(candidates.candidate(id: fromField.id))
        XCTAssertEqual(stored.status, .received)
        XCTAssertEqual(stored.origin, .spoken)
        XCTAssertEqual(stored.importedFrom, "team-learning bundle from Northbridge")
        XCTAssertEqual(entries.entries, [], "arriving is not approval")
        XCTAssertEqual(published, [])

        // It goes through review like a local one — the author cannot approve it off a reviewer device…
        let review = LearningReviewService(candidates: candidates, entries: entries, documentStore: documents)
        review.capability = { .granted }
        review.hipaaMode = { false }
        review.vaults = { [LearningCorpus.VaultTarget(id: F.vaultId, modelIndex: F.modelIndex())] }
        review.coreFiles = { _ in [] }
        review.isReviewerDevice = { false }
        XCTAssertEqual(review.approve(candidateID: fromField.id,
                                      approver: .init(name: "sam tane", role: "Technician")).failureValue,
                       .authorIsApprover)
        // …and a reviewer approves it into a published entry.
        let outcome = try review.approve(candidateID: fromField.id,
                                         approver: .init(name: "Ari Reviewer", role: "Service manager")).get()
        XCTAssertEqual(candidates.candidate(id: fromField.id)?.status, .approved)
        XCTAssertEqual(outcome.placement.published, [F.vaultId])
    }

    func testCandidatesAreTakenOnlyByAReviewerDeviceWithTheCapability() throws {
        let data = LearningBundle(direction: .candidates, issuedAt: 1_800_000_000,
                                  candidates: [.init(F.candidate())]).encoded()
        reviewer = false
        XCTAssertEqual(intake.receive(data).failureValue, .notAReviewerDevice)
        reviewer = true
        granted = .notIncluded(held: [.bundledVaults])
        XCTAssertEqual(intake.receive(data).failureValue, .notEntitled(FieldAssistPaywallCopy.teamLearningsBundleNotIncluded))
        XCTAssertEqual(candidates.candidates, [])
    }

    func testAMalformedFileIsRefusedByNameAndSaysSo() {
        XCTAssertEqual(intake.receive(Data("{\"schemaVersion\":1".utf8)).failureValue, .bundle(.truncated))
        XCTAssertEqual(intake.lastMessage, LearningBundle.Refusal.truncated.message)
        XCTAssertNil(intake.staged)
    }

    // MARK: - The author hears what became of it

    func testAcceptingADecisionTellsTheAuthorsJobAndMarksItInUseOnceItsEntryAnswers() throws {
        var mine = F.candidate()
        mine.status = .sent
        candidates.add(mine)
        var entry = F.entry()
        entry = LearningEntry(id: entry.id, subject: entry.subject, vaultIDs: entry.vaultIDs, finding: entry.finding,
                              approvedAt: entry.approvedAt, approvedByRole: "Service manager",
                              approvedByName: "Ari", candidateID: mine.id)
        let status = LearningBundle.Status(candidateID: mine.id, revision: 1, status: .approved, entryID: entry.id,
                                           reason: nil, issuedAt: 1_800_000_300)
        _ = try intake.receive(decisions([entry], statuses: [status])).get()
        XCTAssertEqual(intake.pending?.statuses.first?.isOurs, true)

        _ = try intake.accept(entryIDs: [], candidateIDs: [mine.id]).get()
        XCTAssertEqual(candidates.candidate(id: mine.id)?.status, .approved)
        XCTAssertEqual(recorded.last?.status, .approved)
        XCTAssertEqual(recorded.last?.inUse, false, "approved, but its entry is not on this phone yet")

        _ = try intake.accept(entryIDs: [entry.id]).get()
        XCTAssertEqual(recorded.last?.id, mine.id)
        XCTAssertEqual(recorded.last?.inUse, true, "its entry answers here now")
        XCTAssertTrue(intake.inUse(try XCTUnwrap(candidates.candidate(id: mine.id))))
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
