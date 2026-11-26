import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import LicenceIssuance

/// Plan NG P0 — the team-learning seat actions: shapes, checks, the paging rule, the route rule, and
/// the golden fixtures in `Contracts/fixtures/team-learning-portal-v1/` (invented content only).
final class SeatLearningTests: XCTestCase {

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Contracts/fixtures/team-learning-portal-v1", isDirectory: true)
    }

    static let profileId = "fixture-company"
    /// A stand-in seat id: SHA-256 of a public label, naming no real phone.
    static let seatID = IssuanceWire.digest(Data("Avenkin public fixture seat v1".utf8))
    static let sessionId = "6F1C2D3E-0000-4000-8000-000000000001"
    static let createdAt: Int64 = 1_795_564_800 // 2026-11-25T00:00:00Z
    /// A lease-shaped placeholder; the fixtures pin shapes, not a lease signature.
    static let lease = Data("fixture-lease".utf8).base64EncodedString() + "." + Data("fixture-signature".utf8).base64EncodedString()

    static func id(_ n: Int) -> String { String(repeating: "0", count: 32 - String(n, radix: 16).count) + String(n, radix: 16) }

    static func candidate(revision: Int = 1, withdrawn: Bool = false) -> SeatLearningCandidate {
        SeatLearningCandidate(
            candidateID: "c0ffee00c0ffee00c0ffee00c0ffee01", revision: revision, withdrawn: withdrawn,
            profileId: profileId, seatID: seatID,
            jobSessionID: SeatWire.learningJobSessionID(profileId: profileId, sessionId: sessionId),
            jobNumber: "J-1042", taskID: "task-2", createdAt: createdAt, author: "Fixture Technician",
            vaultID: "fixture-crew-units", modelToken: "QXRT-990", spokenModel: nil,
            finding: withdrawn ? "" : "On this model the E228 is the harness at the plug, not the switch.\nCheck the plug first.",
            symptom: withdrawn ? nil : "E228 on start", fix: withdrawn ? nil : "Reseated the harness at the plug",
            evidence: SeatLearningEvidence(pagesVerified: ["Installation manual p. 12"], citationsOpened: ["Installation manual p. 12"],
                                           readings: 2, photos: 1),
            redactions: withdrawn ? [] : ["email"])
    }

    static func statuses() -> [SeatLearningStatus] {
        (1...40).map { n in
            let code: SeatLearningStatusCode = [.received, .approved, .merged, .notTakenUp][n % 4]
            return SeatLearningStatus(candidateID: id(n), revision: 1 + n % 3, profileId: profileId, seatID: seatID, status: code,
                                      entryID: code == .approved || code == .merged ? id(1000 + n) : nil,
                                      reason: code == .notTakenUp ? "Already in the sheet as row \(n); thanks for checking." : nil,
                                      issuedAt: createdAt + Int64(n) * 3_600)
        }
    }

    func fixture(_ name: String) throws -> Data { try Data(contentsOf: Self.fixtures.appendingPathComponent(name)) }
    func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T { try SeatLearningWire.decoder().decode(T.self, from: fixture(name)) }

    // MARK: - Shapes

    func testTheCandidateCarriesThePortalBindingAndNoOfficeBinding() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: SeatLearningWire.encoder().encode(Self.candidate())) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "kind", "candidateID", "revision", "withdrawn", "profileId", "seatID",
                                          "jobSessionID", "jobNumber", "taskID", "createdAt", "author", "vaultID", "modelToken",
                                          "finding", "symptom", "fix", "evidence", "redactions"])
        for office in ["organizationID", "enrolmentID", "officeID", "generation"] { XCTAssertNil(object[office], office) }
        let evidence = try XCTUnwrap(object["evidence"] as? [String: Any])
        XCTAssertEqual(Set(evidence.keys), ["pagesVerified", "citationsOpened", "readings", "photos"],
                       "names and counts only: no photo, reading value or nameplate text")
    }

    func testTheJobSessionIdNeverTravelsOnlyItsJoinKey() throws {
        let joined = SeatWire.learningJobSessionID(profileId: Self.profileId, sessionId: Self.sessionId)
        XCTAssertTrue(SeatLearningCheck.isHex(joined, 32))
        XCTAssertNotEqual(joined, SeatWire.learningJobSessionID(profileId: "other-company", sessionId: Self.sessionId),
                          "another company gets an unrelated key for the same job")
        let bytes = try SeatLearningWire.encoder().encode(SeatLearningCandidateRequest(lease: Self.lease, candidate: Self.candidate()))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(Self.sessionId))
    }

    func testTheActionsSitUnderSeatsAndSignTheirOwnName() {
        XCTAssertEqual(SeatLearningWire.Action.learningCandidate.path, "/seats/learning-candidate")
        XCTAssertEqual(SeatLearningWire.Action.learningStatus.path, "/seats/learning-status")
        XCTAssertEqual(SeatLearningWire.requestDomain, SeatWire.requestDomain)
        let body = Data("{}".utf8)
        XCTAssertNotEqual(SeatLearningWire.signedBytes(action: .learningCandidate, nonce: "n", request: body),
                          SeatLearningWire.signedBytes(action: .learningStatus, nonce: "n", request: body))
        // The same rule as the other seat actions: only the action's name differs.
        XCTAssertEqual(SeatLearningWire.signedBytes(action: .learningCandidate, nonce: "n", request: body).dropFirst(SeatWire.requestDomain.utf8.count).prefix(18),
                       Data("learning-candidate".utf8))
    }

    func testAnEnvelopeOpensOnlyForItsActionNonceAndKey() throws {
        let phone = P256.Signing.PrivateKey()
        let body = try SeatLearningWire.encoder().encode(SeatLearningCandidateRequest(lease: Self.lease, candidate: Self.candidate()))
        let signature = try phone.signature(for: SeatLearningWire.signedBytes(action: .learningCandidate, nonce: "n-1", request: body))
        let envelope = SeatEnvelope(nonce: "n-1", request: body.base64EncodedString(), signature: signature.derRepresentation.base64EncodedString())
        let key = phone.publicKey.x963Representation
        XCTAssertEqual(try SeatWire.openLearningEnvelope(envelope, action: .learningCandidate, publicKeyX963: key), body)
        XCTAssertThrowsError(try SeatWire.openLearningEnvelope(envelope, action: .learningStatus, publicKeyX963: key))
        XCTAssertThrowsError(try SeatWire.openLearningEnvelope(envelope, action: .learningCandidate,
                                                               publicKeyX963: P256.Signing.PrivateKey().publicKey.x963Representation))
        let renamed = SeatEnvelope(nonce: "n-2", request: envelope.request, signature: envelope.signature)
        XCTAssertThrowsError(try SeatWire.openLearningEnvelope(renamed, action: .learningCandidate, publicKeyX963: key))
        // Larger than the old 4 KiB seat cap, within the candidate's 32 KiB.
        var big = Self.candidate()
        big.evidence.pagesVerified = (0..<40).map { "Installation manual page \($0) " + String(repeating: "x", count: 200) }
        let bigBody = try SeatLearningWire.encoder().encode(SeatLearningCandidateRequest(lease: Self.lease, candidate: big))
        XCTAssertGreaterThan(bigBody.count, SeatWire.maximumRequestBytes)
        let bigSignature = try phone.signature(for: SeatLearningWire.signedBytes(action: .learningCandidate, nonce: "n-3", request: bigBody))
        let bigEnvelope = SeatEnvelope(nonce: "n-3", request: bigBody.base64EncodedString(), signature: bigSignature.derRepresentation.base64EncodedString())
        XCTAssertNoThrow(try SeatWire.openLearningEnvelope(bigEnvelope, action: .learningCandidate, publicKeyX963: key))
        XCTAssertThrowsError(try SeatWire.openLearningEnvelope(bigEnvelope, action: .learningStatus, publicKeyX963: key),
                             "a status fetch keeps the small cap")
    }

    // MARK: - Checks

    func testTheFixtureCandidatesPass() throws {
        try SeatLearningCheck.check(SeatLearningCandidateRequest(lease: Self.lease, candidate: Self.candidate()))
        try SeatLearningCheck.check(SeatLearningCandidateRequest(lease: Self.lease, candidate: Self.candidate(revision: 3, withdrawn: true)))
        for status in Self.statuses() { try SeatLearningCheck.check(status) }
    }

    func testEveryNegativeCandidateIsRefusedByName() throws {
        let cases = try decode([NegativeCandidate].self, "negative-candidates-v1.json")
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            XCTAssertThrowsError(try SeatLearningCheck.check(item.request), item.name) { error in
                XCTAssertEqual(error as? SeatLearningProblem, item.problem, item.name)
            }
        }
    }

    func testEveryNegativeStatusIsRefusedByName() throws {
        let cases = try decode([NegativeStatus].self, "negative-statuses-v1.json")
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            XCTAssertThrowsError(try SeatLearningCheck.check(item.status), item.name) { error in
                XCTAssertEqual(error as? SeatLearningProblem, item.problem, item.name)
            }
        }
    }

    func testACandidateOverThirtyTwoKibibytesIsRefused() {
        var big = Self.candidate()
        big.evidence.pagesVerified = (0..<100).map { "Page \($0) " + String(repeating: "y", count: 290) }
        big.evidence.citationsOpened = big.evidence.pagesVerified
        XCTAssertThrowsError(try SeatLearningCheck.check(SeatLearningCandidateRequest(lease: Self.lease, candidate: big))) {
            XCTAssertEqual($0 as? SeatLearningProblem, SeatLearningProblem(.tooLarge, "request"))
        }
    }

    // MARK: - The service's rules

    func testADuplicateRevisionIsIdempotentAndAnOlderOneNeverWins() {
        let one = Self.candidate(revision: 1), two = Self.candidate(revision: 2)
        XCTAssertEqual(SeatLearningIntake.keep(one, held: nil), one)
        XCTAssertEqual(SeatLearningIntake.keep(two, held: one), two)
        XCTAssertEqual(SeatLearningIntake.keep(two, held: two), two, "the same revision again changes nothing")
        XCTAssertEqual(SeatLearningIntake.keep(one, held: two), two, "a retry that crossed a newer send keeps the newer")
    }

    func testStatusesArePagedInOrderUnderTheReplyCap() throws {
        let all = Self.statuses().shuffled()
        var seen: [String] = []
        var after: String?
        var pages = 0
        repeat {
            let page = SeatLearningIntake.page(all, after: after)
            XCTAssertLessThanOrEqual(try SeatLearningWire.encoder().encode(page).count, SeatLearningWire.maximumReplyBytes)
            XCTAssertLessThanOrEqual(page.statuses?.count ?? 0, SeatLearningWire.maximumStatusesPerPage)
            seen += page.statuses?.map(\.candidateID) ?? []
            after = page.next
            pages += 1
        } while after != nil && pages < 10
        XCTAssertEqual(seen, all.map(\.candidateID).sorted(), "every status once, in id order")
        XCTAssertGreaterThan(pages, 1)
        // Long reasons fill the cap before the count does.
        let long = (1...20).map { n in
            SeatLearningStatus(candidateID: Self.id(n), revision: 1, profileId: Self.profileId, seatID: Self.seatID, status: .notTakenUp,
                               reason: String(repeating: "é", count: 500), issuedAt: Self.createdAt)
        }
        let first = SeatLearningIntake.page(long, after: nil)
        XCTAssertLessThan(first.statuses?.count ?? 0, 20)
        XCTAssertNotNil(first.next)
        XCTAssertLessThanOrEqual(try SeatLearningWire.encoder().encode(first).count, SeatLearningWire.maximumReplyBytes)
    }

    func testTheRouteRuleMatchesTheFixture() throws {
        let cases = try decode([RouteCase].self, "routes-v1.json")
        XCTAssertEqual(cases.count, 8)
        for item in cases {
            XCTAssertEqual(SeatLearningRoute.choose(officeBinding: item.officeBinding, portalCompanyVaults: item.portalCompanyVaults,
                                                    portalSwitchedOn: item.portalSwitchedOn), item.route, "\(item)")
        }
    }

    // MARK: - Golden fixtures

    func testTheGoldenFixturesAreWhatThisCoreWrites() throws {
        for (name, bytes) in try Self.generated() {
            XCTAssertEqual(try fixture(name), bytes, "\(name) differs from what the core writes; regenerate it")
        }
    }

    func testTheProfileSwitchIsACompanyValueTheAdministratorMaySet() {
        XCTAssertEqual(ProfileContract.allowList["organizationTeamLearningsInPortal"], "owned:bool")
        XCTAssertTrue(ProfileContract.administratorEditableSettings.contains("organizationTeamLearningsInPortal"))
    }

    /// `REGENERATE_TEAM_LEARNING_PORTAL_FIXTURES=1 swift test --package-path Tools/LicenceIssuance --filter
    /// SeatLearningTests/testRegenerateFixtures`. Byte for byte the same on every run. The negative
    /// lists are written here too, from the mutations below.
    func testRegenerateFixtures() throws {
        guard ProcessInfo.processInfo.environment["REGENERATE_TEAM_LEARNING_PORTAL_FIXTURES"] == "1" else {
            throw XCTSkip("set REGENERATE_TEAM_LEARNING_PORTAL_FIXTURES=1 to rewrite the fixtures")
        }
        try FileManager.default.createDirectory(at: Self.fixtures, withIntermediateDirectories: true)
        for (name, bytes) in try Self.generated() { try bytes.write(to: Self.fixtures.appendingPathComponent(name)) }
    }

    struct NegativeCandidate: Codable { let name: String; let problem: SeatLearningProblem; let request: SeatLearningCandidateRequest }
    struct NegativeStatus: Codable { let name: String; let problem: SeatLearningProblem; let status: SeatLearningStatus }
    struct RouteCase: Codable { let officeBinding: Bool; let portalCompanyVaults: Bool; let portalSwitchedOn: Bool; let route: SeatLearningRoute }
    struct JobSessionCase: Codable { let profileId: String; let sessionId: String; let jobSessionID: String }

    static func generated() throws -> [(String, Data)] {
        let encoder = SeatLearningWire.encoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        func bytes(_ value: some Encodable) throws -> Data { try encoder.encode(value) + Data("\n".utf8) }
        let request = SeatLearningCandidateRequest(lease: lease, candidate: candidate())
        let withdrawn = SeatLearningCandidateRequest(lease: lease, candidate: candidate(revision: 3, withdrawn: true))
        var received = SeatLearningStatus(candidateID: request.candidate.candidateID, revision: 1, profileId: profileId, seatID: seatID,
                                          status: .received, issuedAt: createdAt + 60)
        let all = statuses()
        let page1 = SeatLearningIntake.page(all, after: nil)
        let page2 = SeatLearningIntake.page(all, after: page1.next)

        func negative(_ name: String, _ problem: SeatLearningProblem, _ change: (inout SeatLearningCandidate) -> Void) -> NegativeCandidate {
            var c = candidate()
            change(&c)
            return NegativeCandidate(name: name, problem: problem, request: SeatLearningCandidateRequest(lease: lease, candidate: c))
        }
        let negatives: [NegativeCandidate] = [
            negative("kind", .init(.wrongKind, "kind")) { $0.kind = "avenkin.learning-set" },
            negative("version", .init(.wrongVersion, "version")) { $0.version = 2 },
            negative("candidate id upper case", .init(.badIdentifier, "candidateID")) { $0.candidateID = $0.candidateID.uppercased() },
            negative("revision zero", .init(.badRevision, "revision")) { $0.revision = 0 },
            negative("profile id with a slash", .init(.badIdentifier, "profileId")) { $0.profileId = "fixture/company" },
            negative("seat id short", .init(.badIdentifier, "seatID")) { $0.seatID = String($0.seatID.prefix(32)) },
            negative("job session id is the session id", .init(.badIdentifier, "jobSessionID")) { $0.jobSessionID = sessionId },
            negative("vault id empty", .init(.badIdentifier, "vaultID")) { $0.vaultID = "" },
            negative("created at zero", .init(.badTime, "createdAt")) { $0.createdAt = 0 },
            negative("job number too long", .init(.tooLong, "jobNumber")) { $0.jobNumber = String(repeating: "9", count: 81) },
            negative("author empty", .init(.empty, "author")) { $0.author = "" },
            negative("author over 120", .init(.tooLong, "author")) { $0.author = String(repeating: "a", count: 121) },
            negative("finding empty", .init(.missingFinding, "finding")) { $0.finding = "" },
            negative("finding over 2000", .init(.tooLong, "finding")) { $0.finding = String(repeating: "f", count: 2_001) },
            negative("finding with a tab", .init(.controlCharacter, "finding")) { $0.finding = "harness\tplug" },
            negative("finding with a bidirectional override", .init(.controlCharacter, "finding")) { $0.finding = "plug \u{202E}hctiws" },
            negative("symptom with a line feed", .init(.controlCharacter, "symptom")) { $0.symptom = "E228\non start" },
            negative("fix over 500", .init(.tooLong, "fix")) { $0.fix = String(repeating: "x", count: 501) },
            negative("withdrawal with words", .init(.textInWithdrawal, "finding")) { $0.withdrawn = true },
            negative("negative photo count", .init(.badCount, "photos")) { $0.evidence.photos = -1 },
            negative("an empty page name", .init(.empty, "pagesVerified")) { $0.evidence.pagesVerified = [""] },
            negative("a redaction that is not a pattern name", .init(.badIdentifier, "redactions")) { $0.redactions = ["matched text@example.com"] },
        ]
        var noLease = request
        noLease = SeatLearningCandidateRequest(lease: "", candidate: request.candidate)

        func negativeStatus(_ name: String, _ problem: SeatLearningProblem, _ change: (inout SeatLearningStatus) -> Void) -> NegativeStatus {
            var s = SeatLearningStatus(candidateID: id(7), revision: 1, profileId: profileId, seatID: seatID, status: .approved,
                                       entryID: id(1007), issuedAt: createdAt)
            change(&s)
            return NegativeStatus(name: name, problem: problem, status: s)
        }
        let negativeStatuses: [NegativeStatus] = [
            negativeStatus("kind", .init(.wrongKind, "kind")) { $0.kind = SeatLearningWire.candidateKind },
            negativeStatus("approved without an entry", .init(.missingEntryID, "entryID")) { $0.entryID = nil },
            negativeStatus("approved with a reason", .init(.reasonOutOfPlace, "reason")) { $0.reason = "nice" },
            negativeStatus("not taken up without a reason", .init(.missingReason, "reason")) { $0.status = .notTakenUp; $0.entryID = nil },
            negativeStatus("not taken up with an entry", .init(.entryIDOutOfPlace, "entryID")) { $0.status = .notTakenUp; $0.reason = "no" },
            negativeStatus("reason over 500", .init(.tooLong, "reason")) {
                $0.status = .notTakenUp; $0.entryID = nil; $0.reason = String(repeating: "r", count: 501)
            },
            negativeStatus("reason with a control character", .init(.controlCharacter, "reason")) {
                $0.status = .notTakenUp; $0.entryID = nil; $0.reason = "no\u{0007}"
            },
            negativeStatus("received with an entry", .init(.entryIDOutOfPlace, "entryID")) { $0.status = .received },
            negativeStatus("seat id upper case", .init(.badIdentifier, "seatID")) { $0.seatID = $0.seatID.uppercased() },
        ]

        var routes: [RouteCase] = []
        for office in [false, true] {
            for vaults in [false, true] {
                for on in [false, true] {
                    routes.append(RouteCase(officeBinding: office, portalCompanyVaults: vaults, portalSwitchedOn: on,
                                            route: SeatLearningRoute.choose(officeBinding: office, portalCompanyVaults: vaults, portalSwitchedOn: on)))
                }
            }
        }
        let jobSessions = [(profileId, sessionId), (profileId, "6F1C2D3E-0000-4000-8000-000000000002"), ("other-company", sessionId)]
            .map { JobSessionCase(profileId: $0.0, sessionId: $0.1, jobSessionID: SeatWire.learningJobSessionID(profileId: $0.0, sessionId: $0.1)) }

        let refusals = SeatLearningRefusal.allCases.map { SeatLearningCandidateReply(refusal: $0) }
        received.issuedAt = createdAt + 60
        return [
            ("candidate-request-v1.json", try bytes(request)),
            ("candidate-request-withdrawn-v1.json", try bytes(withdrawn)),
            ("candidate-reply-received-v1.json", try bytes(SeatLearningCandidateReply(status: received))),
            ("candidate-reply-refusals-v1.json", try bytes(refusals)),
            ("status-request-v1.json", try bytes(SeatLearningStatusRequest(lease: lease))),
            ("status-request-page2-v1.json", try bytes(SeatLearningStatusRequest(lease: lease, after: page1.next))),
            ("status-reply-page1-v1.json", try bytes(page1)),
            ("status-reply-page2-v1.json", try bytes(page2)),
            ("negative-candidates-v1.json", try bytes(negatives + [NegativeCandidate(name: "no lease", problem: .init(.badLease, "lease"), request: noLease)])),
            ("negative-statuses-v1.json", try bytes(negativeStatuses)),
            ("routes-v1.json", try bytes(routes)),
            ("job-session-ids-v1.json", try bytes(jobSessions)),
        ]
    }

    func testTheJobSessionFixtureIsTheCoresHash() throws {
        for item in try decode([JobSessionCase].self, "job-session-ids-v1.json") {
            XCTAssertEqual(SeatWire.learningJobSessionID(profileId: item.profileId, sessionId: item.sessionId), item.jobSessionID)
        }
    }

    func testTheRepliesDecodeAndTheirStatusesPass() throws {
        let received = try decode(SeatLearningCandidateReply.self, "candidate-reply-received-v1.json")
        XCTAssertEqual(received.status?.status, .received)
        try SeatLearningCheck.check(try XCTUnwrap(received.status))
        let refusals = try decode([SeatLearningCandidateReply].self, "candidate-reply-refusals-v1.json")
        XCTAssertEqual(refusals.compactMap(\.refusal), SeatLearningRefusal.allCases)
        let page1 = try decode(SeatLearningStatusReply.self, "status-reply-page1-v1.json")
        let page2 = try decode(SeatLearningStatusReply.self, "status-reply-page2-v1.json")
        XCTAssertNotNil(page1.next)
        XCTAssertNil(page2.next)
        XCTAssertEqual((page1.statuses ?? []).count + (page2.statuses ?? []).count, 40)
        for status in (page1.statuses ?? []) + (page2.statuses ?? []) { try SeatLearningCheck.check(status) }
        XCTAssertEqual(try decode(SeatLearningStatusRequest.self, "status-request-page2-v1.json").after, page1.next)
    }
}
