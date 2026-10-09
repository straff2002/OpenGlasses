import XCTest
@testable import OpenGlasses

/// Plan FP P2 — supersession and retraction: the entry is stamped and kept as history, its
/// documents leave every namespace they were in, and replaying either changes nothing.
///
/// Headless: fresh stores over a temporary directory, a temporary `DocumentStore`, and two
/// injected vaults that both know the model.
@MainActor
final class TeamLearningSupersessionTests: XCTestCase {

    private typealias F = TeamLearningFixtures

    private var root: URL!
    private var candidates: LearningCandidateStore!
    private var entries: LearningEntryStore!
    private var documents: DocumentStore!
    private var service: LearningReviewService!
    private var clock = Date(timeIntervalSince1970: 1_791_633_600)

    private let reviewer = LearningReview.Approver(name: "Ari Reviewer", role: "Service manager")
    private let second = "fp_second_vault"

    override func setUp() {
        super.setUp()
        root = F.tempDirectory("TeamLearningSupersession")
        candidates = LearningCandidateStore(directory: root.appendingPathComponent("candidates", isDirectory: true))
        entries = LearningEntryStore(directory: root.appendingPathComponent("entries", isDirectory: true))
        documents = F.documentStore(in: root)
        service = LearningReviewService(candidates: candidates, entries: entries, documentStore: documents)
        service.capability = { .granted }
        service.isReviewerDevice = { false }
        service.hipaaMode = { false }
        service.vaults = { [unowned self] in
            [LearningCorpus.VaultTarget(id: F.vaultId, modelIndex: F.modelIndex()),
             LearningCorpus.VaultTarget(id: self.second, modelIndex: F.modelIndex())]
        }
        service.coreFiles = { _ in [] }
        service.clock = { [unowned self] in self.clock }
    }

    override func tearDown() {
        service = nil
        documents = nil
        entries = nil
        candidates = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func count(_ vaultId: String) -> Int {
        documents.documentCount(namespace: DocumentStore.learningNamespace(vaultId))
    }

    private func approve(_ candidate: LearningCandidate, supersedes: String? = nil) throws -> LearningEntry {
        candidates.add(candidate)
        return try service.approve(candidateID: candidate.id, approver: reviewer, vaultIDs: [],
                                   supersedes: supersedes).get().entry
    }

    // MARK: - Retraction

    func testRetractionStampsAndKeepsTheEntryAndEmptiesEveryNamespace() throws {
        let entry = try approve(F.candidate())
        XCTAssertEqual(count(F.vaultId), 1)
        XCTAssertEqual(count(second), 1, "empty vaultIDs: every vault")

        clock = clock.addingTimeInterval(3_600.4)
        let retracted = try service.retract(entryID: entry.id, reason: " The board revision changed ").get()
        XCTAssertEqual(retracted.retractedAt, Date(timeIntervalSince1970: 1_791_637_200))
        XCTAssertEqual(retracted.retractionReason, "The board revision changed")
        XCTAssertFalse(retracted.isLive)
        XCTAssertEqual(LearningReview.state(of: retracted), .retracted(reason: "The board revision changed"))
        XCTAssertEqual(entries.entries.map(\.id), [entry.id], "kept as history")
        XCTAssertEqual(entries.live, [])
        XCTAssertEqual(count(F.vaultId), 0)
        XCTAssertEqual(count(second), 0)

        // Replayed: the first stamp and reason stand, and nothing is left to remove.
        clock = clock.addingTimeInterval(86_400)
        let replayed = try service.retract(entryID: entry.id, reason: "again").get()
        XCTAssertEqual(replayed, retracted)
        XCTAssertEqual(entries.entry(id: entry.id), retracted)
        XCTAssertEqual(count(F.vaultId), 0)
        XCTAssertEqual(LearningCorpus.withdraw(entryID: entry.id, store: documents), 0)

        // A retracted entry is final.
        let other = try approve(F.candidate(finding: "The inducer bearing squeals below freezing"))
        XCTAssertEqual(service.supersede(entryID: entry.id, by: other.id).failureValue,
                       .invalidTransition(from: .retracted(reason: "The board revision changed"),
                                          action: .supersede(by: other.id)))
        XCTAssertEqual(service.retract(entryID: entry.id, reason: "").failureValue, nil,
                       "replaying a retraction never needs a reason again")
    }

    // MARK: - Supersession

    func testSupersessionStampsTheOldEntryAndMovesTheNamespaceToTheNewOne() throws {
        let old = try approve(F.candidate(session: "job-1"))
        clock = clock.addingTimeInterval(60)
        let replacement = try approve(F.candidate(session: "job-2",
                                                  finding: "The tubing sweats only on the early board revision"),
                                      supersedes: old.id)
        XCTAssertEqual(replacement.supersedes, old.id)

        let stamped = try XCTUnwrap(entries.entry(id: old.id))
        XCTAssertEqual(stamped.supersededBy, replacement.id)
        XCTAssertEqual(stamped.supersededAt, Date(timeIntervalSince1970: 1_791_633_660))
        XCTAssertEqual(LearningReview.state(of: stamped), .superseded(by: replacement.id))
        XCTAssertEqual(entries.entries.count, 2, "the old one stays as history")
        XCTAssertEqual(entries.live.map(\.id), [replacement.id])

        for vault in [F.vaultId, second] {
            let ids = documents.list(namespace: DocumentStore.learningNamespace(vault)).map(\.id)
            XCTAssertEqual(ids, [LearningCorpus.documentId(entryID: replacement.id, vaultId: vault)], vault)
        }

        // Replayed: unchanged, and still only the replacement answers.
        clock = clock.addingTimeInterval(86_400)
        let replayed = try service.supersede(entryID: old.id, by: replacement.id).get()
        XCTAssertEqual(replayed, stamped)
        XCTAssertEqual(count(F.vaultId), 1)

        // Superseded by one entry, it cannot be superseded by another, retracted, or merged into.
        let third = try approve(F.candidate(session: "job-3", finding: "Replace the tubing with the silicone kit"))
        XCTAssertEqual(service.supersede(entryID: old.id, by: third.id).failureValue,
                       .invalidTransition(from: .superseded(by: replacement.id), action: .supersede(by: third.id)))
        XCTAssertEqual(service.retract(entryID: old.id, reason: "x").failureValue,
                       .invalidTransition(from: .superseded(by: replacement.id), action: .retract(reason: "x")))
        let late = F.candidate(session: "job-4")
        candidates.add(late)
        XCTAssertEqual(service.merge(candidateID: late.id, into: old.id, approver: reviewer).failureValue,
                       .entryNotLive(old.id))
        XCTAssertEqual(service.approve(candidateID: late.id, approver: reviewer, supersedes: old.id).failureValue,
                       .entryNotLive(old.id))
    }

    func testAnEntryCannotSupersedeItselfOrBeReplacedByARetiredOne() throws {
        let entry = try approve(F.candidate())
        XCTAssertEqual(service.supersede(entryID: entry.id, by: entry.id).failureValue,
                       .invalidTransition(from: .approved(entryID: entry.id), action: .supersede(by: entry.id)))
        let other = try approve(F.candidate(finding: "Another finding about the inducer"))
        _ = try service.retract(entryID: other.id, reason: "Wrong unit").get()
        XCTAssertNotNil(service.supersede(entryID: entry.id, by: other.id).failureValue)
        XCTAssertTrue(entries.entry(id: entry.id)?.isLive ?? false)
        XCTAssertEqual(count(F.vaultId), 1)
    }

    // MARK: - Replaying the whole set

    func testReconcilingTheSetIsIdempotentAndDropsWhatNoLongerAnswers() throws {
        let kept = try approve(F.candidate())
        let gone = try approve(F.candidate(finding: "The inducer bearing squeals below freezing"))
        _ = try service.retract(entryID: gone.id, reason: "Wrong unit").get()
        // A document whose entry this phone no longer holds at all — say, erased.
        documents.ingestWhole(documentId: LearningCorpus.documentId(entryID: LearningCandidate.newID(), vaultId: F.vaultId),
                              name: "Team learning · X · 2026-01-01 · approved by Nobody", text: "orphan",
                              sourceType: LearningCorpus.sourceType, namespace: DocumentStore.learningNamespace(F.vaultId))
        // And a learning document left in a vault that is no longer installed.
        documents.ingestWhole(documentId: LearningCorpus.documentId(entryID: kept.id, vaultId: "uninstalled"),
                              name: kept.citationName, text: "stale", sourceType: LearningCorpus.sourceType,
                              namespace: DocumentStore.learningNamespace("uninstalled"))

        service.republish()
        func snapshot() -> [String] {
            documents.list().filter { DocumentStore.isLearningNamespace($0.namespace) }.map { "\($0.namespace)|\($0.id)|\($0.name)" }.sorted()
        }
        let first = snapshot()
        XCTAssertEqual(first, [F.vaultId, second].map {
            "\(DocumentStore.learningNamespace($0))|\(LearningCorpus.documentId(entryID: kept.id, vaultId: $0))|\(kept.citationName)"
        }.sorted())

        service.republish()
        XCTAssertEqual(snapshot(), first, "replaying the set changes nothing")
        XCTAssertEqual(documents.list().filter { DocumentStore.isLearningNamespace($0.namespace) }.map(\.chunkCount),
                       [1, 1], "one chunk each, still")
    }

    func testTheDocumentIdCarriesTheEntryIdAndNothingElseParsesAsOne() {
        let id = LearningCandidate.newID()
        XCTAssertEqual(LearningCorpus.entryID(fromDocumentId: LearningCorpus.documentId(entryID: id, vaultId: "a@b")), id)
        XCTAssertNil(LearningCorpus.entryID(fromDocumentId: UUID().uuidString), "a manual's id is not an entry's")
        XCTAssertNil(LearningCorpus.entryID(fromDocumentId: "short@vault"))
        XCTAssertNil(LearningCorpus.entryID(fromDocumentId: String(repeating: "A", count: 32) + "@v"), "lowercase only")
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
