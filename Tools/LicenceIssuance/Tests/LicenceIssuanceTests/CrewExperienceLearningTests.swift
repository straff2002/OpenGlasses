import XCTest
@testable import LicenceIssuance

/// Plan NG P0b — the crew experience set holds what the portal publishes: learnings an
/// administrator approved (origin `spoken`, with their candidate and jobs) beside the sheet's rows,
/// FP's merge rule in the core, and the older-phone gate. Golden fixtures in
/// `Contracts/fixtures/crew-experience-v1/learnings/`, which the app's `CrewExperienceLearningTests`
/// read too. Invented brands, models, codes and people only.
final class CrewExperienceLearningTests: XCTestCase {

    static var fixtures: URL { CrewExperienceTests.fixtures.appendingPathComponent("learnings", isDirectory: true) }

    func fixture(_ name: String) throws -> Data { try Data(contentsOf: Self.fixtures.appendingPathComponent(name)) }
    func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T { try JSONDecoder().decode(T.self, from: fixture(name)) }

    struct MergeCase: Codable { let name: String; let before: CrewExperienceMerge.Jobs; let jobSessionID: String; let after: CrewExperienceMerge.Jobs }
    struct GateCase: Codable { let name: String; let seatBuilds: [String?]; let mayPublishSpokenEntries: Bool }
    struct NegativeSet: Codable { let name: String; let set: CrewExperienceSet; let refusal: String }

    static let candidate = "c0ffee00000000000000000000000001"
    static let jobA = String(repeating: "a", count: 31) + "1"
    static let jobB = String(repeating: "b", count: 31) + "2"

    /// `set-v1.json`'s entries, the first confirmed on a job, and a learning approved in the portal.
    static func setWithSpoken() throws -> CrewExperienceSet {
        let base = try JSONDecoder().decode(CrewExperienceSet.self, from: Data(contentsOf: CrewExperienceTests.fixtures.appendingPathComponent("set-v1.json")))
        var entries = base.entries
        entries[0] = CrewExperienceMerge.merge(jobSessionID: jobA, into: entries[0])
        entries.append(spoken())
        return CrewExperienceSet(profileId: base.profileId, vaultId: base.vaultId, sequence: 2,
                                 issuedAt: CrewExperienceTests.issuedAt + 86_400, entries: entries)
    }

    static func spoken(id: String = "0000000000000000000000000000000a", origin: String = CrewExperienceSheet.spokenOrigin,
                       candidateID: String? = candidate, jobs: [String]? = [jobB], count: Int? = 1) -> CrewExperienceSet.Entry {
        CrewExperienceSet.Entry(
            entryID: id, subject: .model(modelToken: "QXRT-990", manufacturer: "Fixturetherm", equipmentType: "rooftop unit"),
            vaultIDs: ["fixture-crew-units"], finding: "Tighten the condenser fan set screw before replacing the motor",
            symptom: "Fan rattles at start", fix: "Tightened the set screw", faultCode: nil, tried: nil, outcome: nil,
            approvedAt: CrewExperienceTests.issuedAt + 3_600, approvedByRole: "Service manager", authorIsApprover: false,
            origin: origin, candidateID: candidateID, sourceJobIDs: jobs, confirmedJobCount: count)
    }

    /// Each negative set: one entry, or two, broken one way, in a set that is otherwise good.
    static func negativeSets() throws -> [NegativeSet] {
        let good = try setWithSpoken()
        func with(_ name: String, _ refusal: String, _ entries: [CrewExperienceSet.Entry]) -> NegativeSet {
            NegativeSet(name: name, set: CrewExperienceSet(profileId: good.profileId, vaultId: good.vaultId, sequence: good.sequence,
                                                           issuedAt: good.issuedAt, entries: entries),
                        refusal: refusal)
        }
        let id = "0000000000000000000000000000000a"
        let sheetRow = good.entries[1]
        func recollection(candidateID: String? = nil, jobs: [String]? = nil, count: Int? = nil) -> CrewExperienceSet.Entry {
            CrewExperienceSet.Entry(entryID: sheetRow.entryID, subject: sheetRow.subject, vaultIDs: sheetRow.vaultIDs,
                                    finding: sheetRow.finding, symptom: sheetRow.symptom, fix: sheetRow.fix,
                                    faultCode: sheetRow.faultCode, tried: sheetRow.tried, outcome: sheetRow.outcome,
                                    approvedAt: sheetRow.approvedAt, approvedByRole: sheetRow.approvedByRole,
                                    authorIsApprover: sheetRow.authorIsApprover, candidateID: candidateID,
                                    sourceJobIDs: jobs, confirmedJobCount: count)
        }
        return [
            with("an office report's origin", "\(id)'s origin report is not one a set carries (recollection or spoken)",
                 [spoken(origin: "report")]),
            with("a review pass's origin", "\(id)'s origin reportReview is not one a set carries (recollection or spoken)",
                 [spoken(origin: "reportReview")]),
            with("an origin spelled in capitals", "\(id)'s origin Spoken is not one a set carries (recollection or spoken)",
                 [spoken(origin: "Spoken")]),
            with("a spoken entry without its candidate", "\(id): a spoken entry carries the candidateID it was approved from",
                 [spoken(candidateID: nil)]),
            with("a candidate id that is not hex", "\(id): candidateID C0FFEE00000000000000000000000001 is not 32 lowercase hex",
                 [spoken(candidateID: "C0FFEE00000000000000000000000001")]),
            with("a spoken entry without its jobs", "\(id): a spoken entry carries sourceJobIDs and confirmedJobCount",
                 [spoken(jobs: nil, count: nil)]),
            with("jobs without a count", "\(id): sourceJobIDs and confirmedJobCount come together or not at all",
                 [spoken(count: nil)]),
            with("a count without jobs", "\(id): sourceJobIDs and confirmedJobCount come together or not at all",
                 [spoken(jobs: nil)]),
            with("no jobs", "\(id): sourceJobIDs is empty", [spoken(jobs: [], count: 1)]),
            with("a raw session id instead of the job hash", "\(id): a source job id is not 32 lowercase hex",
                 [spoken(jobs: ["7D3F0E52-1B7A-4C4E-9A51-0E6E3B1C2D4F"])]),
            with("the same job twice", "\(id): sourceJobIDs names a job twice", [spoken(jobs: [jobB, jobB], count: 2)]),
            with("a count below its jobs", "\(id): confirmedJobCount 1 is fewer than its 2 source jobs",
                 [spoken(jobs: [jobA, jobB], count: 1)]),
            with("a recollection with a candidate",
                 "\(sheetRow.entryID): a recollection came from no candidate, so it carries no candidateID",
                 [recollection(candidateID: candidate)]),
            with("a recollection confirmed on no job", "\(sheetRow.entryID): sourceJobIDs is empty",
                 [recollection(jobs: [], count: 0)]),
            with("one candidate approved twice", "0000000000000000000000000000000b: candidate \(candidate) is on two entries",
                 [spoken(), spoken(id: "0000000000000000000000000000000b")])
        ]
    }

    // MARK: - Regenerating

    /// `REGENERATE_CREW_EXPERIENCE_FIXTURES=1 swift test --package-path Tools/LicenceIssuance --filter
    /// CrewExperienceLearningTests/testRegenerateFixtures`. `merge-cases.json` and
    /// `publish-gate-cases.json` are hand-written; the set and the negative sets are written here.
    func testRegenerateFixtures() throws {
        guard ProcessInfo.processInfo.environment["REGENERATE_CREW_EXPERIENCE_FIXTURES"] == "1" else {
            throw XCTSkip("set REGENERATE_CREW_EXPERIENCE_FIXTURES=1 to rewrite the fixtures")
        }
        let set = try Self.setWithSpoken()
        try CrewExperienceSet.check(set)
        try CrewExperienceSet.encoder().encode(set).write(to: Self.fixtures.appendingPathComponent("set-with-spoken-v1.json"))
        try CrewExperienceTests.encoder().encode(try Self.negativeSets())
            .write(to: Self.fixtures.appendingPathComponent("negative-sets.json"))
    }

    // MARK: - The check admits both origins and still refuses any other

    func testTheSetWithSpokenEntriesChecksAndIsTheBytesItWas() throws {
        let bytes = try fixture("set-with-spoken-v1.json")
        let set = try JSONDecoder().decode(CrewExperienceSet.self, from: bytes)
        XCTAssertNoThrow(try CrewExperienceSet.check(set))
        XCTAssertEqual(set, try Self.setWithSpoken())
        XCTAssertEqual(try CrewExperienceSet.encoder().encode(set), bytes)
        XCTAssertEqual(set.entries.map(\.origin), ["recollection", "recollection", "recollection", "recollection", "spoken"])
        XCTAssertTrue(set.containsSpokenEntries)
        XCTAssertEqual(set.entries[0].sourceJobIDs, [Self.jobA])
        XCTAssertEqual(set.entries[0].confirmedJobCount, 1)
        XCTAssertNil(set.entries[0].candidateID)
        XCTAssertEqual(set.entries[4].candidateID, Self.candidate)
    }

    func testEveryNegativeSetIsRefusedInItsWords() throws {
        let negatives = try decode([NegativeSet].self, "negative-sets.json")
        XCTAssertEqual(negatives.map(\.name), try Self.negativeSets().map(\.name))
        for item in negatives {
            XCTAssertThrowsError(try CrewExperienceSet.check(item.set), item.name) {
                XCTAssertEqual($0 as? CrewExperienceSet.Refusal, .invalid(item.refusal), item.name)
            }
        }
    }

    func testTheNegativeSetsFixtureIsWhatTheCasesWrite() throws {
        let negatives = try decode([NegativeSet].self, "negative-sets.json")
        let made = try Self.negativeSets()
        XCTAssertEqual(negatives.map(\.refusal), made.map(\.refusal))
        XCTAssertEqual(negatives.map(\.set), made.map(\.set))
    }

    func testEveryOtherOriginIsRefusedByName() throws {
        for origin in ["report", "reportReview", "", "recalled", "SPOKEN"] {
            let set = CrewExperienceSet(profileId: "fixture-company", vaultId: "fixture-crew-units", sequence: 1,
                                        issuedAt: CrewExperienceTests.issuedAt, entries: [Self.spoken(origin: origin)])
            XCTAssertThrowsError(try CrewExperienceSet.check(set)) {
                XCTAssertEqual($0 as? CrewExperienceSet.Refusal,
                               .invalid("0000000000000000000000000000000a's origin \(origin) is not one a set carries (recollection or spoken)"))
            }
        }
        XCTAssertEqual(CrewExperienceSet.origins, ["recollection", "spoken"])
    }

    // MARK: - Old sets decode unchanged

    func testASheetSetCarriesNoneOfTheNewFields() throws {
        let bytes = try Data(contentsOf: CrewExperienceTests.fixtures.appendingPathComponent("set-v1.json"))
        let set = try JSONDecoder().decode(CrewExperienceSet.self, from: bytes)
        XCTAssertFalse(set.containsSpokenEntries)
        for entry in set.entries {
            XCTAssertNil(entry.candidateID)
            XCTAssertNil(entry.sourceJobIDs)
            XCTAssertNil(entry.confirmedJobCount)
        }
        let text = String(decoding: bytes, as: UTF8.self)
        for key in ["candidateID", "sourceJobIDs", "confirmedJobCount"] { XCTAssertFalse(text.contains(key), key) }
        XCTAssertEqual(try CrewExperienceSet.encoder().encode(set), bytes)
    }

    // MARK: - Citations

    func testASpokenEntryIsCitedAsATeamLearning() throws {
        let set = try decode(CrewExperienceSet.self, "set-with-spoken-v1.json")
        XCTAssertEqual(set.entries[4].citationName, "Team learning · QXRT-990 · 2026-11-25 · approved by Service manager")
        XCTAssertEqual(set.entries[0].citationName, "Crew experience · QXRT-990 · 2026-11-25 · approved by Service manager")
        XCTAssertTrue(set.entries[4].isSpoken)
        XCTAssertFalse(set.entries[0].isSpoken, "a recollection a job confirmed is still a recollection")
    }

    // MARK: - The merge rule

    func testTheMergeCases() throws {
        let cases = try decode([MergeCase].self, "merge-cases.json")
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for item in cases {
            XCTAssertEqual(CrewExperienceMerge.merge(jobSessionID: item.jobSessionID, into: item.before), item.after, item.name)
        }
    }

    func testMergingAnEntryChangesOnlyItsJobs() throws {
        let entry = Self.spoken()
        let merged = CrewExperienceMerge.merge(jobSessionID: Self.jobA, into: entry)
        XCTAssertEqual(merged.sourceJobIDs, [Self.jobB, Self.jobA])
        XCTAssertEqual(merged.confirmedJobCount, 2)
        let restored = CrewExperienceSet.Entry(
            entryID: merged.entryID, subject: merged.subject, vaultIDs: merged.vaultIDs, finding: merged.finding,
            symptom: merged.symptom, fix: merged.fix, faultCode: merged.faultCode, tried: merged.tried, outcome: merged.outcome,
            approvedAt: merged.approvedAt, approvedByRole: merged.approvedByRole, authorIsApprover: merged.authorIsApprover,
            contradictsSafetyNote: merged.contradictsSafetyNote, origin: merged.origin, candidateID: merged.candidateID,
            sourceJobIDs: entry.sourceJobIDs, confirmedJobCount: entry.confirmedJobCount)
        XCTAssertEqual(restored, entry)
        XCTAssertEqual(merged.citationName, entry.citationName, "a merge never changes the citation")
        XCTAssertEqual(CrewExperienceMerge.merge(jobSessionID: Self.jobA, into: merged), merged, "a replayed merge adds nothing")
    }

    // MARK: - The older-phone gate

    func testThePublishGateCases() throws {
        XCTAssertEqual(CrewExperienceSet.spokenEntriesMinAppBuild, 779)
        for item in try decode([GateCase].self, "publish-gate-cases.json") {
            XCTAssertEqual(CrewExperienceSet.mayPublishSpokenEntries(seatBuilds: item.seatBuilds), item.mayPublishSpokenEntries, item.name)
        }
    }

    func testASetWithoutSpokenEntriesNeedsNoGate() throws {
        let sheet = try JSONDecoder().decode(CrewExperienceSet.self, from: Data(contentsOf: CrewExperienceTests.fixtures.appendingPathComponent("set-v1.json")))
        XCTAssertTrue(CrewExperienceSet.mayPublish(sheet, seatBuilds: ["775", nil]))
        let spoken = try decode(CrewExperienceSet.self, "set-with-spoken-v1.json")
        XCTAssertFalse(CrewExperienceSet.mayPublish(spoken, seatBuilds: ["779", "778"]))
        XCTAssertTrue(CrewExperienceSet.mayPublish(spoken, seatBuilds: ["779", "800"]))
    }

    func testTheGateOverTheLedgerCountsOnlyHeldSeatsOnTheProfile() throws {
        let now = Date(timeIntervalSince1970: TimeInterval(CrewExperienceTests.issuedAt))
        func seat(_ key: String, build: String, profile: String = "fixture-company", freed: Bool = false,
                  leaseEnds: TimeInterval = 86_400) -> SeatRecord {
            SeatRecord(profileId: profile, deviceKeyHash: key, devicePublicKey: "k", enrolmentId: "e",
                       claimedAt: now.addingTimeInterval(-86_400), leaseNotAfter: now.addingTimeInterval(leaseEnds),
                       lastSeenAt: now, build: build, freedAt: freed ? now : nil)
        }
        let spoken = try decode(CrewExperienceSet.self, "set-with-spoken-v1.json")
        let current = [seat("a", build: "779"), seat("b", build: "781")]
        XCTAssertTrue(SeatPolicy.mayPublishCrewExperience(spoken, seats: current, profileId: "fixture-company", now: now))
        // A freed seat, a long-lapsed one and another company's do not hold it back.
        let ignored = current + [seat("c", build: "776", freed: true), seat("d", build: "776", leaseEnds: -400 * 86_400),
                                 seat("e", build: "776", profile: "fixture-other-company")]
        XCTAssertTrue(SeatPolicy.mayPublishCrewExperience(spoken, seats: ignored, profileId: "fixture-company", now: now))
        XCTAssertFalse(SeatPolicy.mayPublishCrewExperience(spoken, seats: current + [seat("f", build: "778")],
                                                           profileId: "fixture-company", now: now))
    }

    // MARK: - The sheet keeps a learning's provenance

    func testDownloadingAndReuploadingTheSheetKeepsASpokenEntry() throws {
        let set = try decode(CrewExperienceSet.self, "set-with-spoken-v1.json")
        let vault = CrewExperienceSheet.Vault(vaultId: "fixture-crew-units", modelSpellings: ["QXRT-990", "QXRT990", "ZPL-2040", "ZPL2040"],
                                              equipmentTypes: ["rooftop unit", "walk-in cooler"],
                                              currentEntryIDs: set.entries.map(\.entryID))
        let csv = CrewExperienceSheet.csv(entries: set.entries)
        let parsed = try CrewExperienceSheet.parse(csv: Data(csv.utf8), vault: vault)
        let approval = CrewExperienceSheet.Approval(role: "Owner", name: nil, approvedAt: CrewExperienceTests.issuedAt + 5 * 86_400)
        let unchanged = CrewExperienceSheet.entries(from: parsed, approvedBy: approval, current: set.entries,
                                                    newID: CrewExperienceTests.ids(from: 99))
        XCTAssertEqual(unchanged, set.entries, "an unedited sheet changes nothing, the portal's learnings included")

        // The administrator edits the learning's fix in the sheet: still that learning.
        let edited = csv.replacingOccurrences(of: "Tightened the set screw", with: "Tightened the set screw and its key")
        let reparsed = try CrewExperienceSheet.parse(csv: Data(edited.utf8), vault: vault)
        let next = CrewExperienceSheet.entries(from: reparsed, approvedBy: approval, current: set.entries,
                                               newID: CrewExperienceTests.ids(from: 99))
        let learning = try XCTUnwrap(next.last)
        XCTAssertEqual(learning.fix, "Tightened the set screw and its key")
        XCTAssertEqual(learning.origin, "spoken")
        XCTAssertEqual(learning.candidateID, Self.candidate)
        XCTAssertEqual(learning.sourceJobIDs, [Self.jobB])
        XCTAssertEqual(learning.confirmedJobCount, 1)
        XCTAssertEqual(next[0].sourceJobIDs, [Self.jobA], "a job-confirmed row keeps its job")
        XCTAssertNoThrow(try CrewExperienceSet.check(CrewExperienceSet(profileId: set.profileId, vaultId: set.vaultId,
                                                                       sequence: 3, issuedAt: set.issuedAt + 1, entries: next)))
    }
}
