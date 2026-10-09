import XCTest
@testable import OpenGlasses

/// Plan FP P3 — `LearningBundleMerge`, pure: a tombstone beats content whatever its timestamp, the
/// later approval wins, the higher candidate revision wins, a status is final once applied and a
/// replay changes nothing, a finding two phones filed surfaces for the reviewer instead of being
/// silently merged, and two phones that apply the same bundles in opposite orders end identical.
@MainActor
final class LearningBundleMergeTests: XCTestCase {

    private typealias F = TeamLearningFixtures
    private typealias M = LearningBundleMerge

    private let note = "team-learning bundle from Northbridge"

    private func decisions(issuedAt: Int64 = 1_800_000_000, entries: [LearningEntry] = [],
                           retracted: [LearningBundle.Retraction] = [],
                           statuses: [LearningBundle.Status] = []) -> LearningBundle {
        LearningBundle(direction: .decisions, organisationLabel: "Northbridge", issuedAt: issuedAt,
                       statuses: statuses, entries: entries.map(LearningBundle.Entry.init), retracted: retracted)
    }

    private func candidates(_ list: [LearningCandidate]) -> LearningBundle {
        LearningBundle(direction: .candidates, organisationLabel: "Northbridge", issuedAt: 1_800_000_000,
                       candidates: list.map(LearningBundle.Candidate.init))
    }

    private func retraction(_ id: String, at: Int64, _ reason: String = "Wrong unit") -> LearningBundle.Retraction {
        .init(entryID: id, retractedAt: at, reason: reason)
    }

    private func apply(_ bundles: [LearningBundle], to start: M.Holdings = .init()) -> M.Holdings {
        bundles.reduce(start) { held, bundle in M.apply(bundle, to: held, importedFrom: note).0 }
    }

    /// An entry as a receiving phone would hold it from the wire.
    private func received(_ entry: LearningEntry) -> LearningEntry { LearningBundle.Entry(entry).entry() }

    // MARK: - Tombstones

    func testATombstoneBeatsContentWhateverItsTimestamp() throws {
        let entry = F.entry(approvedAt: Date(timeIntervalSince1970: 1_800_000_000))
        // The retraction says it happened *before* the approval it withdraws — clocks differ — and
        // still wins, in either order.
        let tomb = retraction(entry.id, at: 1_700_000_000)
        for order in [[decisions(entries: [entry]), decisions(retracted: [tomb])],
                      [decisions(retracted: [tomb]), decisions(entries: [entry])]] {
            let held = apply(order)
            let stored = try XCTUnwrap(held.entries.first)
            XCTAssertFalse(stored.isLive)
            XCTAssertEqual(stored.retractedAt, Date(timeIntervalSince1970: 1_700_000_000))
            XCTAssertEqual(stored.retractionReason, "Wrong unit")
            XCTAssertEqual(stored.finding, entry.finding, "kept as history")
            XCTAssertEqual(held.tombstones, [], "the tombstone is on the entry now")
        }
        // A later copy of the content, approved later still, does not bring it back.
        var newer = entry
        newer = LearningEntry(id: entry.id, subject: entry.subject, vaultIDs: entry.vaultIDs, finding: "Reworded",
                              approvedAt: Date(timeIntervalSince1970: 1_900_000_000), approvedByRole: "Service manager",
                              approvedByName: "Ari")
        let held = apply([decisions(retracted: [tomb]), decisions(entries: [newer])])
        XCTAssertFalse(try XCTUnwrap(held.entries.first).isLive)
    }

    func testARetractionForAnEntryNotHeldIsKeptAsATombstone() {
        let id = LearningCandidate.newID()
        let held = apply([decisions(retracted: [retraction(id, at: 10)])])
        XCTAssertEqual(held.entries, [])
        XCTAssertEqual(held.tombstones, [retraction(id, at: 10)])
        let again = apply([decisions(retracted: [retraction(id, at: 5, "Earlier")])], to: held)
        XCTAssertEqual(again.tombstones, [retraction(id, at: 5, "Earlier")], "the earlier retraction stands")
    }

    // MARK: - Later approval wins

    func testTheLaterApprovedAtWinsAndAnOlderCopyChangesNothing() throws {
        let id = LearningCandidate.newID()
        let first = F.entry(id: id, finding: "Original wording", approvedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = F.entry(id: id, finding: "Edited wording", approvedAt: Date(timeIntervalSince1970: 1_800_086_400))
        for order in [[first, second], [second, first]] {
            let held = apply(order.map { decisions(entries: [$0]) })
            XCTAssertEqual(held.entries.count, 1)
            XCTAssertEqual(held.entries.first?.finding, "Edited wording")
        }
        let (_, report) = M.apply(decisions(entries: [first]), to: apply([decisions(entries: [second])]), importedFrom: note)
        XCTAssertEqual(report.entriesChanged, [], "an older copy changes nothing")
    }

    func testAtTheSameApprovalTheJobListsJoinWhicheverArrivesFirst() throws {
        let id = LearningCandidate.newID()
        let one = F.entry(id: id, jobs: ["job-1"], count: 1)
        let two = F.entry(id: id, jobs: ["job-1", "job-2"], count: 2)
        let a = apply([decisions(entries: [one]), decisions(entries: [two])])
        let b = apply([decisions(entries: [two]), decisions(entries: [one])])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.entries.first?.sourceJobIDs, ["job-1", "job-2"])
        XCTAssertEqual(a.entries.first?.confirmedJobCount, 2)
    }

    func testASupersedingEntryTakesTheOldOneOutOfServiceAtItsOwnApprovalTime() throws {
        let old = F.entry(approvedAt: Date(timeIntervalSince1970: 1_800_000_000))
        var replacement = F.entry(finding: "Better wording", approvedAt: Date(timeIntervalSince1970: 1_800_100_000))
        replacement.supersedes = old.id
        let held = apply([decisions(entries: [old, replacement])])
        let stamped = try XCTUnwrap(held.entries.first { $0.id == old.id })
        XCTAssertEqual(stamped.supersededBy, replacement.id)
        XCTAssertEqual(stamped.supersededAt, replacement.approvedAt)
        XCTAssertFalse(stamped.isLive)
        XCTAssertTrue(held.entries.first { $0.id == replacement.id }?.isLive ?? false)
    }

    // MARK: - Candidates

    func testTheHigherCandidateRevisionWinsAndALowerOneChangesNothing() throws {
        var first = F.candidate(finding: "First wording of the finding")
        first.importedFrom = nil
        var amended = first
        amended.finding = "Amended wording of the finding"
        amended.revision = 2
        for order in [[first, amended], [amended, first]] {
            let held = apply(order.map { candidates([$0]) })
            XCTAssertEqual(held.candidates.count, 1)
            XCTAssertEqual(held.candidates.first?.finding, "Amended wording of the finding")
            XCTAssertEqual(held.candidates.first?.revision, 2)
            XCTAssertEqual(held.candidates.first?.status, .received, "arriving is not approval")
            XCTAssertEqual(held.candidates.first?.importedFrom, note)
        }
    }

    func testADecidedCandidateKeepsItsDecisionWhenALaterRevisionArrives() throws {
        let wire = F.candidate()
        var held = apply([candidates([wire])])
        held.candidates[0].status = .approved
        held.candidates[0].entryID = LearningCandidate.newID()
        var amended = wire
        amended.revision = 3
        amended.finding = "Something else entirely"
        let (after, report) = M.apply(candidates([amended]), to: held, importedFrom: note)
        XCTAssertEqual(report.candidatesKeptDecided, [wire.id])
        XCTAssertEqual(after.candidates, held.candidates)
    }

    func testACandidateThisPhoneFiledIsNeverOverwrittenByACopyOfIt() {
        let local = F.candidate()
        var copy = local
        copy.revision = 5
        copy.finding = "Edited elsewhere"
        let (after, report) = M.apply(candidates([copy]), to: .init(candidates: [local]), importedFrom: note)
        XCTAssertEqual(after.candidates, [local])
        XCTAssertEqual(report.candidatesUnchanged, [local.id])
    }

    func testTheSameFindingFromTwoPhonesSurfacesAsAMergeSuggestionAndBothAreKept() throws {
        let phoneA = F.candidate(session: "job-A", finding: "The pressure switch tubing sweats and reads open on a cold start",
                                 author: "Sam Tane")
        let phoneB = F.candidate(session: "job-B", finding: "  the PRESSURE switch tubing   sweats and reads open on a cold start ",
                                 author: "Mere Hohaia")
        let other = F.candidate(session: "job-C", finding: "A different finding about the inducer", author: "Sam Tane")
        let first = apply([candidates([phoneA, other])])
        let (held, report) = M.apply(candidates([phoneB]), to: first, importedFrom: note)
        XCTAssertEqual(held.candidates.count, 3, "never silently deduplicated")
        XCTAssertEqual(report.duplicates, [M.DuplicatePair(phoneA.id, phoneB.id)])
        XCTAssertTrue(held.candidates.allSatisfy { $0.status == .received })

        // …and one that repeats a live entry is offered for a merge into it.
        let entry = F.entry()
        let (_, withEntry) = M.apply(candidates([F.candidate(session: "job-D")]),
                                     to: .init(entries: [entry]), importedFrom: note)
        XCTAssertEqual(withEntry.entrySuggestions.values.first, [entry.id])
    }

    // MARK: - Statuses

    func testAStatusIsFinalOnceAppliedAndAReplayIsANoOp() throws {
        var mine = F.candidate()
        mine.status = .sent
        let entryID = LearningCandidate.newID()
        let approved = LearningBundle.Status(candidateID: mine.id, revision: 1, status: .approved, entryID: entryID,
                                             reason: nil, issuedAt: 1_800_000_500)
        let declined = LearningBundle.Status(candidateID: mine.id, revision: 1, status: .notTakenUp, entryID: nil,
                                             reason: "Already in the manual", issuedAt: 1_800_000_600)
        let received = LearningBundle.Status(candidateID: mine.id, revision: 1, status: .received, entryID: nil,
                                             reason: nil, issuedAt: 1_800_000_400)

        let (first, report) = M.apply(decisions(statuses: [approved]), to: .init(candidates: [mine]), importedFrom: note)
        XCTAssertEqual(report.statusesApplied, [mine.id])
        XCTAssertEqual(first.candidates.first?.status, .approved)
        XCTAssertEqual(first.candidates.first?.entryID, entryID)

        let (replayed, replay) = M.apply(decisions(statuses: [approved]), to: first, importedFrom: note)
        XCTAssertEqual(replayed, first)
        XCTAssertEqual(replay.statusesApplied, [])
        let (after, other) = M.apply(decisions(statuses: [declined, received]), to: first, importedFrom: note)
        XCTAssertEqual(after, first, "a final status is not replaced, nor walked back to received")
        XCTAssertEqual(other.statusesIgnored, [mine.id, mine.id])
    }

    func testReceivedMovesOnlyFiledOrSentAndOnlyForTheRevisionHeld() throws {
        var mine = F.candidate()
        mine.revision = 2
        let stale = LearningBundle.Status(candidateID: mine.id, revision: 1, status: .received, entryID: nil,
                                          reason: nil, issuedAt: 1_800_000_400)
        XCTAssertNil(M.applying(stale, to: mine), "revision 2 has not been received yet")
        var current = stale
        current.revision = 2
        XCTAssertEqual(M.applying(current, to: mine)?.status, .received)
        var withdrawn = mine
        withdrawn.status = .withdrawn
        XCTAssertNil(M.applying(current, to: withdrawn))
        let declined = LearningBundle.Status(candidateID: mine.id, revision: 2, status: .notTakenUp, entryID: nil,
                                             reason: "Already in the manual", issuedAt: 1_800_000_600)
        let after = try XCTUnwrap(M.applying(declined, to: mine))
        XCTAssertEqual(after.status, .notTakenUp)
        XCTAssertEqual(after.reviewReason, "Already in the manual")
        XCTAssertEqual(after.updatedAt, Date(timeIntervalSince1970: 1_800_000_600))
    }

    // MARK: - Convergence and idempotence

    func testTwoPhonesApplyingTheSameBundlesInOppositeOrdersEndIdentical() {
        let kept = F.entry(finding: "Kept finding", approvedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let edited = F.entry(id: kept.id, finding: "Kept finding, reworded",
                             approvedAt: Date(timeIntervalSince1970: 1_800_050_000))
        let doomed = F.entry(finding: "Doomed finding", approvedAt: Date(timeIntervalSince1970: 1_800_000_000))
        var mine = F.candidate()
        mine.status = .sent
        let status = LearningBundle.Status(candidateID: mine.id, revision: 1, status: .merged, entryID: kept.id,
                                           reason: nil, issuedAt: 1_800_000_700)
        let x = decisions(issuedAt: 1_800_000_000, entries: [kept, doomed], statuses: [status])
        let y = decisions(issuedAt: 1_800_090_000, entries: [edited],
                          retracted: [retraction(doomed.id, at: 1_800_080_000)])
        let start = M.Holdings(candidates: [mine])

        let phoneA = apply([x, y], to: start)
        let phoneB = apply([y, x], to: start)
        XCTAssertEqual(phoneA, phoneB)
        XCTAssertEqual(phoneA.entries.first { $0.id == kept.id }?.finding, "Kept finding, reworded")
        XCTAssertFalse(phoneA.entries.first { $0.id == doomed.id }?.isLive ?? true)
        XCTAssertEqual(phoneA.candidates.first?.status, .merged)
        XCTAssertEqual(phoneA.tombstones, [])
    }

    func testApplyingTheSameBundleTwiceChangesNothingTheSecondTime() {
        let entry = F.entry()
        let gone = F.entry(finding: "Gone")
        var mine = F.candidate()
        mine.status = .sent
        let bundle = decisions(entries: [entry, gone], retracted: [retraction(gone.id, at: 1_800_000_900),
                                                                  retraction(LearningCandidate.newID(), at: 3)],
                               statuses: [.init(candidateID: mine.id, revision: 1, status: .received, entryID: nil,
                                                reason: nil, issuedAt: 1_800_000_100)])
        let (once, first) = M.apply(bundle, to: .init(candidates: [mine]), importedFrom: note)
        XCTAssertTrue(first.changedAnything)
        let (twice, second) = M.apply(bundle, to: once, importedFrom: note)
        XCTAssertEqual(twice, once)
        XCTAssertFalse(second.changedAnything)
        XCTAssertEqual(second.entriesChanged, [])

        let incoming = candidates([F.candidate(session: "job-X")])
        let (c1, _) = M.apply(incoming, to: .init(), importedFrom: note)
        let (c2, again) = M.apply(incoming, to: c1, importedFrom: note)
        XCTAssertEqual(c2, c1)
        XCTAssertFalse(again.changedAnything)
    }

    func testAnEntryFromTheWireKeepsTheContractFieldsAndNamesTheRoleForTheApprover() {
        let entry = F.entry()
        let back = received(entry)
        XCTAssertEqual(back.id, entry.id)
        XCTAssertEqual(back.citationName, entry.citationName)
        XCTAssertEqual(back.approvedByName, "Service manager", "the name does not travel; the role does")
        XCTAssertNil(back.captured)
    }
}
