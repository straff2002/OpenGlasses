import XCTest
@testable import OpenGlasses

/// The app's copies of the shared core (compiled into the app); the unqualified names in this bundle
/// are the licence core's own, compiled into the test bundle beside them.
private typealias AppSet = OpenGlasses.CrewExperienceSet
private typealias AppMerge = OpenGlasses.CrewExperienceMerge

/// Plan NG P0b — the phone holds what the portal publishes, against the golden fixtures in
/// `Contracts/fixtures/crew-experience-v1/learnings/` the licence core's `CrewExperienceLearningTests`
/// read too: a set holding a learning an administrator approved (origin `spoken`) checks and is cited
/// as a team learning, any other origin is refused by name, and FP's merge rule gives the same answer
/// through `LearningReview.merge` as through the core. Invented brands, models, codes and people only.
@MainActor
final class CrewExperienceLearningSetTests: XCTestCase {

    static func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: CrewExperienceLearningSetTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "crew-experience-v1", withExtension: nil))
        return try Data(contentsOf: url.appendingPathComponent("learnings").appendingPathComponent(name))
    }

    struct Jobs: Decodable, Equatable { let origin: String; let sourceJobIDs: [String]?; let confirmedJobCount: Int? }
    struct MergeCase: Decodable { let name: String; let before: Jobs; let jobSessionID: String; let after: Jobs }
    struct GateCase: Decodable { let name: String; let seatBuilds: [String?]; let mayPublishSpokenEntries: Bool }
    fileprivate struct NegativeSet: Decodable { let name: String; let set: AppSet; let refusal: String }

    // MARK: - The merge rule agrees

    func testTheMergeCasesAgreeThroughLearningReview() throws {
        let cases = try JSONDecoder().decode([MergeCase].self, from: Self.fixture("merge-cases.json"))
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        let reviewer = LearningReview.Approver(name: "Ari Reviewer", role: "Service manager")
        for item in cases {
            let origin = try XCTUnwrap(LearningCandidate.Origin(rawValue: item.before.origin), item.name)
            let entry = LearningEntry(subject: .model(modelToken: TeamLearningFixtures.model090), vaultIDs: [TeamLearningFixtures.vaultId],
                                      finding: "The pressure switch tubing sweats and reads open on a cold start",
                                      approvedAt: Date(timeIntervalSince1970: 1_791_590_400), approvedByRole: "Service manager",
                                      approvedByName: "Ari Reviewer", origin: origin,
                                      sourceJobIDs: item.before.sourceJobIDs, confirmedJobCount: item.before.confirmedJobCount)
            let candidate = TeamLearningFixtures.candidate(session: item.jobSessionID)
            let merged = try LearningReview.merge(candidate, into: entry, approver: reviewer,
                                                  context: .init(isReviewerDevice: false)).get()
            XCTAssertEqual(merged.state, .merged(into: entry.id), item.name)
            XCTAssertEqual(Jobs(origin: merged.entry.origin.rawValue, sourceJobIDs: merged.entry.sourceJobIDs,
                                confirmedJobCount: merged.entry.confirmedJobCount), item.after, item.name)
            XCTAssertEqual(merged.entry.citationName, entry.citationName, "\(item.name): a merge never changes the citation")

            // The app's own copy of the core says the same.
            let direct = AppMerge.merge(jobSessionID: item.jobSessionID,
                                        into: .init(origin: item.before.origin, sourceJobIDs: item.before.sourceJobIDs,
                                                    confirmedJobCount: item.before.confirmedJobCount))
            XCTAssertEqual(Jobs(origin: direct.origin, sourceJobIDs: direct.sourceJobIDs, confirmedJobCount: direct.confirmedJobCount),
                           item.after, item.name)
        }
    }

    func testTheGatesStillComeBeforeTheMerge() {
        let entry = TeamLearningFixtures.entry()
        let candidate = TeamLearningFixtures.candidate(session: "job-2")
        let reviewer = LearningReview.Approver(name: "Ari Reviewer", role: "Service manager")
        func refusal(_ result: Result<(entry: LearningEntry, state: LearningReview.State), LearningReview.Refusal>) -> LearningReview.Refusal? {
            if case .failure(let refusal) = result { return refusal }
            return nil
        }
        XCTAssertEqual(refusal(LearningReview.merge(candidate, into: entry, approver: reviewer,
                                                    context: .init(isReviewerDevice: true, hipaa: true))), .hipaa)
        let author = LearningReview.Approver(name: "Sam Tane", role: "Lead technician")
        XCTAssertEqual(refusal(LearningReview.merge(candidate, into: entry, approver: author,
                                                    context: .init(isReviewerDevice: false))), .authorIsApprover)
    }

    // MARK: - The phone holds the set

    func testTheSetWithSpokenEntriesChecksAndReadsAsTheCoreWroteIt() throws {
        let bytes = try Self.fixture("set-with-spoken-v1.json")
        let set = try JSONDecoder().decode(AppSet.self, from: bytes)
        XCTAssertNoThrow(try AppSet.check(set))
        XCTAssertEqual(try AppSet.encoder().encode(set), bytes)
        XCTAssertTrue(set.containsSpokenEntries)

        let entries = CompanyExperienceStore.entries(of: set)
        XCTAssertEqual(entries.map(\.origin), [.recollection, .recollection, .recollection, .recollection, .spoken])
        let learning = try XCTUnwrap(entries.last)
        XCTAssertFalse(learning.isCrewExperience)
        XCTAssertEqual(learning.citationName, "Team learning · QXRT-990 · 2026-11-25 · approved by Service manager")
        XCTAssertEqual(learning.citationName, set.entries[4].citationName, "the phone cites exactly what the portal names")
        XCTAssertEqual(learning.candidateID, "c0ffee00000000000000000000000001")
        XCTAssertEqual(learning.sourceJobIDs, [String(repeating: "b", count: 31) + "2"])
        XCTAssertEqual(learning.confirmedJobCount, 1)

        let confirmed = try XCTUnwrap(entries.first)
        XCTAssertTrue(confirmed.isCrewExperience, "a recollection a job confirmed is still crew experience")
        XCTAssertEqual(confirmed.citationName, "Crew experience · QXRT-990 · 2026-11-25 · approved by Service manager")
        XCTAssertEqual(confirmed.sourceJobIDs, [String(repeating: "a", count: 31) + "1"])
        XCTAssertNil(entries[1].candidateID)
        XCTAssertNil(entries[1].confirmedJobCount)
    }

    func testEveryNegativeSetIsRefusedOnThePhoneInTheCoresWords() throws {
        let negatives = try JSONDecoder().decode([NegativeSet].self, from: Self.fixture("negative-sets.json"))
        XCTAssertGreaterThanOrEqual(negatives.count, 15)
        for item in negatives {
            XCTAssertThrowsError(try AppSet.check(item.set), item.name) {
                XCTAssertEqual($0 as? AppSet.Refusal, .invalid(item.refusal), item.name)
            }
        }
    }

    // MARK: - Cited and introduced as a team learning

    func testASpokenEntryIsDisclosedAsATeamLearning() throws {
        let set = try JSONDecoder().decode(AppSet.self, from: Self.fixture("set-with-spoken-v1.json"))
        let entries = CompanyExperienceStore.entries(of: set)
        let learning = try XCTUnwrap(entries.last)
        let crew = try XCTUnwrap(entries.first)
        func passage(_ entry: LearningEntry) -> VaultRetriever.Passage {
            VaultRetriever.Passage(documentId: LearningCorpus.documentId(entryID: entry.id, vaultId: set.vaultId),
                                   documentName: entry.citationName, chunkIndex: 0, text: "Model: QXRT-990", page: nil,
                                   section: nil, similarity: 0.9, score: 0.9, matchedTokens: [], source: .teamLearning)
        }
        let held = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let lookup: (String) -> LearningEntry? = { id in LearningCorpus.entryID(fromDocumentId: id).flatMap { held[$0] } }

        let alone = try XCTUnwrap(TeamLearningDisclosure.from(.teamLearningOnly([passage(learning)]), entry: lookup))
        XCTAssertFalse(try XCTUnwrap(alone.entries.first).isCrewExperience)
        XCTAssertEqual(alone.leadIn, TeamLearningDisclosure.leadIn(confirmedJobCount: 1))
        XCTAssertEqual(alone.leadIn, "The manual doesn't cover this. Your crew's own finding:")
        XCTAssertTrue(alone.showsTeamLearningBadge)
        XCTAssertTrue(TeamLearningCitation.isTeamLearning(learning.citationName))
        XCTAssertFalse(TeamLearningCitation.isCrewExperience(learning.citationName))

        // Not held on this phone: the citation alone says it is a team learning.
        let unheld = try XCTUnwrap(TeamLearningDisclosure.from(.teamLearningOnly([passage(learning)])) { _ in nil })
        XCTAssertFalse(try XCTUnwrap(unheld.entries.first).isCrewExperience)

        // The sheet's row beside it keeps the crew-experience lead-in.
        let sheet = try XCTUnwrap(TeamLearningDisclosure.from(.teamLearningOnly([passage(crew)]), entry: lookup))
        XCTAssertEqual(sheet.leadIn, TeamLearningDisclosure.crewExperienceLeadIn)
    }

    // MARK: - The older-phone gate

    func testThePublishGateIsTheCoresOnThePhoneToo() throws {
        XCTAssertEqual(AppSet.spokenEntriesMinAppBuild, 779)
        for item in try JSONDecoder().decode([GateCase].self, from: Self.fixture("publish-gate-cases.json")) {
            XCTAssertEqual(AppSet.mayPublishSpokenEntries(seatBuilds: item.seatBuilds), item.mayPublishSpokenEntries, item.name)
        }
    }
}
