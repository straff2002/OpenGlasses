import XCTest
@testable import OpenGlasses

/// Plan FP P3 — the team-learning bundle codec. A bundle from another phone is untrusted input, so
/// every structural fault refuses the **whole** bundle with a named reason: truncated, malformed,
/// an unknown version or kind, an unknown or duplicated key, a number that is not a plain integer,
/// a control character, an over-length field, an oversize file. Incoming text is redacted and the
/// pattern names recorded. A reordered bundle is the ledger's call, tested at the bottom.
@MainActor
final class LearningBundleTests: XCTestCase {

    private typealias F = TeamLearningFixtures

    private func candidatesBundle(_ list: [LearningCandidate]? = nil) -> LearningBundle {
        LearningBundle(direction: .candidates, organisationLabel: "Northbridge Mechanical", issuedAt: 1_800_000_100,
                       candidates: (list ?? [F.candidate()]).map(LearningBundle.Candidate.init))
    }

    private func decisionsBundle() -> LearningBundle {
        var retracted = F.entry(finding: "The inducer bearing squeals below freezing")
        retracted.retractedAt = Date(timeIntervalSince1970: 1_791_600_000)
        retracted.retractionReason = "Wrong unit"
        return LearningBundle(
            direction: .decisions, organisationLabel: "Northbridge Mechanical", issuedAt: 1_800_000_200, sequence: 3,
            statuses: [.init(candidateID: LearningCandidate.newID(), revision: 1, status: .notTakenUp, entryID: nil,
                             reason: "Already in the manual", issuedAt: 1_800_000_150)],
            entries: [.init(F.entry()), .init(retracted)],
            retracted: [LearningBundle.Retraction(retracted)!])
    }

    /// The bundle's JSON as a mutable dictionary, for building faulty files from a good one.
    private func json(_ bundle: LearningBundle) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: bundle.encoded()) as? [String: Any])
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func refusal(_ data: Data) -> LearningBundle.Refusal? {
        if case .failure(let refusal) = LearningBundle.decode(data) { return refusal }
        return nil
    }

    // MARK: - Round trip

    func testACandidatesBundleRoundTripsExactly() throws {
        let candidate = F.candidate()
        let bundle = candidatesBundle([candidate])
        let decoded = try LearningBundle.decode(bundle.encoded()).get()
        XCTAssertEqual(decoded.bundle, bundle)
        XCTAssertEqual(decoded.redactionsOnIntake, [])
        // The candidate in the contract's §3 shape, and back as a received candidate on the reviewer.
        let wire = try XCTUnwrap(decoded.bundle.candidates.first)
        XCTAssertEqual(wire.candidateID, candidate.id)
        XCTAssertEqual(wire.jobSessionID, "job-1")
        XCTAssertEqual(wire.createdAt, 1_800_000_000)
        let imported = wire.candidate(importedFrom: "team-learning bundle from Northbridge Mechanical")
        XCTAssertEqual(imported.status, .received)
        XCTAssertEqual(imported.origin, .spoken)
        XCTAssertEqual(imported.importedFrom, "team-learning bundle from Northbridge Mechanical")
        XCTAssertEqual(imported.finding, candidate.finding)
        XCTAssertEqual(imported.modelToken, F.model090)
        XCTAssertFalse(imported.isLocal)
    }

    func testADecisionsBundleRoundTripsAndItsKeysAreTheContracts() throws {
        let bundle = decisionsBundle()
        let bytes = bundle.encoded()
        XCTAssertEqual(try LearningBundle.decode(bytes).get().bundle, bundle)
        XCTAssertEqual(bundle.encoded(), bytes, "the same bundle is the same bytes")

        let top = try json(bundle)
        XCTAssertEqual(Set(top.keys), ["schemaVersion", "kind", "direction", "organisationLabel", "issuedAt", "sequence",
                                       "candidates", "statuses", "entries", "retracted"])
        XCTAssertEqual(top["schemaVersion"] as? Int, 1)
        XCTAssertEqual(top["kind"] as? String, "avenkin.learning-bundle")
        let entry = try XCTUnwrap((top["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(entry.keys), ["entryID", "subject", "vaultIDs", "finding", "fix", "approvedAt", "approvedByRole",
                                         "authorIsApprover", "contradictsSafetyNote", "origin", "sourceJobIDs",
                                         "confirmedJobCount"],
                       "the §5 entry and the amendment's fields; nothing of the phone's own history")
        XCTAssertNil(entry["approvedByName"], "the approver's name does not travel")
        XCTAssertEqual((entry["subject"] as? [String: Any])?["kind"] as? String, "model")
    }

    func testAnEmptyOptionalIsLeftOutRatherThanSentEmpty() throws {
        var candidate = F.candidate(symptom: nil, fix: nil)
        candidate = LearningCandidate(id: candidate.id, sessionId: "job-1", jobReference: "", taskId: nil,
                                      vaultId: F.vaultId, equipment: nil, spokenModel: nil, finding: "Finding",
                                      symptom: "", fix: nil, evidence: .init(), author: "Sam Tane",
                                      createdAt: Date(timeIntervalSince1970: 1_800_000_000), redactions: [])
        let bundle = candidatesBundle([candidate])
        let wire = try XCTUnwrap((try json(bundle)["candidates"] as? [[String: Any]])?.first)
        XCTAssertNil(wire["jobNumber"])
        XCTAssertNil(wire["symptom"])
        XCTAssertNoThrow(try LearningBundle.decode(bundle.encoded()).get())
    }

    func testTheFileNameIsTheDirectionAndTheIssueTimeInUTC() {
        XCTAssertEqual(candidatesBundle().fileName, "team-learning-candidates-20270115-0801.json")
        XCTAssertEqual(decisionsBundle().fileName, "team-learning-decisions-20270115-0803.json")
    }

    // MARK: - Refused whole

    func testATruncatedBundleIsRefusedAsTruncated() {
        let bytes = candidatesBundle().encoded()
        for cut in [bytes.count / 3, bytes.count / 2, bytes.count - 2] {
            XCTAssertEqual(refusal(bytes.prefix(cut)), .truncated, "cut at \(cut)")
        }
        XCTAssertEqual(refusal(Data()), .truncated)
        XCTAssertEqual(refusal(Data("not json".utf8)), .malformed)
        XCTAssertEqual(refusal(Data("[]".utf8)), .malformed, "a bundle is an object")
        XCTAssertEqual(refusal(bytes + Data(" {}".utf8)), .malformed, "nothing after the document")
    }

    func testAnUnknownVersionOrKindIsRefusedWholeBeforeAnyKeyIsJudged() throws {
        var object = try json(candidatesBundle())
        object["schemaVersion"] = 2
        object["newField"] = "from a later version"
        XCTAssertEqual(refusal(try data(object)), .unknownVersion, "a later version is a version, not an unknown key")
        object["schemaVersion"] = nil
        XCTAssertEqual(refusal(try data(object)), .unknownVersion)

        object = try json(candidatesBundle())
        object["kind"] = "avenkin.learning-set"
        XCTAssertEqual(refusal(try data(object)), .unknownKind)
        object["kind"] = nil
        XCTAssertEqual(refusal(try data(object)), .unknownKind)
        XCTAssertEqual(refusal(Data(#"{"schemaVersion":1,"kind":"avenkin.job"}"#.utf8)), .unknownKind)
    }

    func testUnknownAndMissingKeysAreRefusedByPath() throws {
        var object = try json(candidatesBundle())
        object["signature"] = "made-up"
        XCTAssertEqual(refusal(try data(object)), .unknownKey("signature"))

        object = try json(candidatesBundle())
        var candidates = try XCTUnwrap(object["candidates"] as? [[String: Any]])
        candidates[0]["customerName"] = "Mrs Smith"
        object["candidates"] = candidates
        XCTAssertEqual(refusal(try data(object)), .unknownKey("candidates[0].customerName"))

        object = try json(candidatesBundle())
        candidates = try XCTUnwrap(object["candidates"] as? [[String: Any]])
        candidates[0]["author"] = nil
        object["candidates"] = candidates
        XCTAssertEqual(refusal(try data(object)), .missingKey("candidates[0].author"))

        object = try json(candidatesBundle())
        object["entries"] = nil
        XCTAssertEqual(refusal(try data(object)), .missingKey("entries"))

        object = try json(candidatesBundle())
        object["organisationLabel"] = NSNull()
        XCTAssertEqual(refusal(try data(object)), .wrongType("organisationLabel"), "absent, never null")
    }

    func testADuplicatedKeyIsRefusedEvenThoughJSONSerializationWouldKeepTheLast() {
        let text = String(decoding: candidatesBundle().encoded(), as: UTF8.self)
        let doubled = text.replacingOccurrences(of: #""direction" : "candidates","#,
                                                with: #""direction" : "candidates", "direction" : "decisions","#)
        XCTAssertNotEqual(doubled, text, "fixture edit applied")
        XCTAssertEqual(refusal(Data(doubled.utf8)), .duplicateKey("direction"))
    }

    func testANumberThatIsNotAPlainIntegerIsRefused() {
        let text = String(decoding: candidatesBundle().encoded(), as: UTF8.self)
        for spelling in ["1800000100.0", "1.8000001e9", "01800000100", "-0", "9007199254740992"] {
            let edited = text.replacingOccurrences(of: #""issuedAt" : 1800000100"#, with: #""issuedAt" : \#(spelling)"#)
            XCTAssertNotEqual(edited, text)
            XCTAssertEqual(refusal(Data(edited.utf8)), .nonIntegerNumber, spelling)
        }
        let negative = text.replacingOccurrences(of: #""issuedAt" : 1800000100"#, with: #""issuedAt" : -5"#)
        XCTAssertEqual(refusal(Data(negative.utf8)), .outOfRange("issuedAt"))
        let quoted = text.replacingOccurrences(of: #""issuedAt" : 1800000100"#, with: #""issuedAt" : "1800000100""#)
        XCTAssertEqual(refusal(Data(quoted.utf8)), .wrongType("issuedAt"))
    }

    func testAControlCharacterIsRefusedAndALineFeedOnlyInsideAFinding() throws {
        func edited(_ field: String, _ value: String) throws -> Data {
            var object = try json(candidatesBundle())
            var candidates = try XCTUnwrap(object["candidates"] as? [[String: Any]])
            candidates[0][field] = value
            object["candidates"] = candidates
            return try data(object)
        }
        XCTAssertNoThrow(try LearningBundle.decode(try edited("finding", "First line\nsecond line")).get(),
                         "a line feed is allowed inside a finding")
        XCTAssertEqual(refusal(try edited("symptom", "First\nsecond")), .controlCharacter("candidates[0].symptom"))
        XCTAssertEqual(refusal(try edited("finding", "Bell\u{07} here")), .controlCharacter("candidates[0].finding"))
        XCTAssertEqual(refusal(try edited("finding", "Carriage\r return")), .controlCharacter("candidates[0].finding"))
        XCTAssertEqual(refusal(try edited("author", "Sam \u{202E}enaT")), .controlCharacter("candidates[0].author"),
                       "a bidirectional override reads differently from how it is stored")
    }

    func testOverLengthFieldsAreRefusedWithTheCountAndTheLimit() throws {
        func edited(_ field: String, _ value: String) throws -> Data {
            var object = try json(candidatesBundle())
            var candidates = try XCTUnwrap(object["candidates"] as? [[String: Any]])
            candidates[0][field] = value
            object["candidates"] = candidates
            return try data(object)
        }
        XCTAssertEqual(refusal(try edited("finding", String(repeating: "a", count: 2_001))),
                       .tooLong("candidates[0].finding", count: 2_001, limit: 2_000))
        XCTAssertNoThrow(try LearningBundle.decode(try edited("finding", String(repeating: "a", count: 2_000))).get())
        XCTAssertEqual(refusal(try edited("fix", String(repeating: "b", count: 501))),
                       .tooLong("candidates[0].fix", count: 501, limit: 500))
        XCTAssertEqual(refusal(try edited("author", String(repeating: "c", count: 121))),
                       .tooLong("candidates[0].author", count: 121, limit: 120))
        XCTAssertEqual(refusal(try edited("author", "")), .empty("candidates[0].author"))
        XCTAssertEqual(refusal(try edited("candidateID", "ABC")), .invalidIdentifier("candidates[0].candidateID"))

        var object = try json(decisionsBundle())
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        entries[0]["approvedByRole"] = String(repeating: "r", count: 81)
        object["entries"] = entries
        XCTAssertEqual(refusal(try data(object)), .tooLong("entries[0].approvedByRole", count: 81, limit: 80))
    }

    func testAnOversizeBundleIsRefusedBeforeItIsRead() {
        let huge = Data(count: LearningBundle.maximumBytes + 1)
        XCTAssertEqual(refusal(huge), .tooLarge(bytes: LearningBundle.maximumBytes + 1))
    }

    func testADirectionCarriesOnlyItsOwnItemsAndNoItemTwice() throws {
        var mixed = candidatesBundle()
        mixed.entries = [.init(F.entry())]
        XCTAssertEqual(refusal(mixed.encoded()), .directionMismatch)

        var wrongWay = decisionsBundle()
        wrongWay.candidates = [.init(F.candidate())]
        XCTAssertEqual(refusal(wrongWay.encoded()), .directionMismatch)

        let candidate = F.candidate()
        XCTAssertEqual(refusal(candidatesBundle([candidate, candidate]).encoded()), .duplicateItem(candidate.id))

        var approvedWithoutEntry = decisionsBundle()
        approvedWithoutEntry.statuses[0].status = .approved
        approvedWithoutEntry.statuses[0].reason = nil
        XCTAssertEqual(refusal(approvedWithoutEntry.encoded()), .missingKey("statuses[0].entryID"))

        var withdrawnWithText = candidatesBundle()
        withdrawnWithText.candidates[0].withdrawn = true
        XCTAssertEqual(refusal(withdrawnWithText.encoded()), .outOfRange("candidates[0].withdrawn"),
                       "a withdrawal carries no text")
    }

    func testEveryRefusalSaysNothingWasUsed() {
        let all: [LearningBundle.Refusal] = [.tooLarge(bytes: 3_000_000), .truncated, .malformed, .duplicateKey("a"),
                                             .nonIntegerNumber, .unknownVersion, .unknownKind, .unknownKey("x"),
                                             .missingKey("y"), .wrongType("z"), .outOfRange("w"), .invalidIdentifier("v"),
                                             .controlCharacter("u"), .tooLong("t", count: 9, limit: 8), .empty("s"),
                                             .directionMismatch, .duplicateItem("0123456789"), .reordered]
        for refusal in all {
            XCTAssertTrue(refusal.message.hasPrefix("This team-learning file was not opened, and nothing in it was used"),
                          refusal.message)
        }
    }

    // MARK: - Redaction on intake

    func testIncomingTextIsRedactedAndTheNamesThatFiredAreRecorded() throws {
        var leaky = F.candidate(finding: "Call the owner on owner@example.com before restarting",
                                symptom: "IRD 123-456-789 on the work order")
        leaky.redactions = []
        var bundle = candidatesBundle([leaky])
        bundle.candidates[0].redactions = []
        let decoded = try LearningBundle.decode(bundle.encoded()).get()
        XCTAssertEqual(decoded.redactionsOnIntake, ["email", "nz_ird"])
        let wire = try XCTUnwrap(decoded.bundle.candidates.first)
        XCTAssertFalse(wire.finding.contains("owner@example.com"), wire.finding)
        XCTAssertFalse(wire.symptom?.contains("123-456-789") ?? true)
        XCTAssertEqual(wire.redactions, ["email", "nz_ird"], "the candidate's names agree with its text")

        var decisions = decisionsBundle()
        decisions.entries[0].finding = "Ask dispatch@example.com for the board revision"
        let decided = try LearningBundle.decode(decisions.encoded()).get()
        XCTAssertEqual(decided.redactionsOnIntake, ["email"])
        XCTAssertFalse(decided.bundle.entries[0].finding.contains("dispatch@example.com"))
    }

    func testAFindingThatIsOnlyAMachineNameSurvivesRedactionUntouched() throws {
        let decoded = try LearningBundle.decode(candidatesBundle().encoded()).get()
        XCTAssertEqual(decoded.bundle.candidates.first?.finding, F.candidate().finding)
        XCTAssertEqual(decoded.redactionsOnIntake, [])
    }

    // MARK: - Reordered

    func testABundleOlderThanOneAppliedForTheSameLabelAndDirectionIsOlder() {
        var ledger = LearningBundleLedger()
        let newer = decisionsBundle()
        ledger.advance(for: newer)
        XCTAssertFalse(ledger.isOlder(newer), "the same bundle again is not older")

        var older = newer
        older.sequence = 2
        older.issuedAt += 1_000
        XCTAssertTrue(ledger.isOlder(older), "a lower sequence is older, whatever its time")

        var unsequenced = newer
        unsequenced.sequence = nil
        unsequenced.issuedAt -= 1
        XCTAssertTrue(ledger.isOlder(unsequenced), "without a sequence, the issue time decides")

        var otherLabel = unsequenced
        otherLabel.organisationLabel = "Southbridge Mechanical"
        XCTAssertFalse(ledger.isOlder(otherLabel), "another label is another issuer")

        var otherDirection = candidatesBundle()
        otherDirection.issuedAt = 1
        XCTAssertFalse(ledger.isOlder(otherDirection))
    }

    // MARK: - The strict reader

    func testTheStrictReaderParsesNestedJSONAndRefusesDepthBombs() {
        XCTAssertEqual(try LearningBundleJSON.parse(Data(#"{"a":[1,true,null,"x\n"],"b":{"c":-3}}"#.utf8)).get(),
                       .object([("a", .array([.integer(1), .bool(true), .null, .string("x\n")])),
                                ("b", .object([("c", .integer(-3))]))]))
        let bomb = String(repeating: "[", count: 40) + String(repeating: "]", count: 40)
        if case .success = LearningBundleJSON.parse(Data(bomb.utf8)) { XCTFail("a depth bomb must not parse") }
        XCTAssertEqual(refusal(Data("{\"a\":\u{01}}".utf8)), .malformed)
    }
}
