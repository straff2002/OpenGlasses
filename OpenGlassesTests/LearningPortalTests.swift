import XCTest
@testable import OpenGlasses

// The app's copies of the shared core's types (compiled into the app for Plan NG P1). The
// unqualified names in this bundle are the licence core's own, compiled into the test bundle beside
// it, so what the phone writes is read back here by the portal's side of the contract.
private typealias AppWire = OpenGlasses.SeatLearningWire
private typealias AppStatus = OpenGlasses.SeatLearningStatus
private typealias AppRoute = OpenGlasses.SeatLearningRoute
private typealias AppRefusal = OpenGlasses.SeatLearningRefusal
private typealias AppCheck = OpenGlasses.SeatLearningCheck
private typealias AppCandidateRequest = OpenGlasses.SeatLearningCandidateRequest

/// The portal's side, reduced to the shared core's rules and an in-memory ledger.
@MainActor
private final class FakePortal {
    static let profileId = "fixture-company"
    static let seatID = String(repeating: "ab", count: 32)
    static let lease = "bGVhc2U=.c2lnbmF0dXJl"

    var held: [String: SeatLearningCandidate] = [:]
    var statuses: [String: SeatLearningStatus] = [:]
    /// Answer every candidate with this refusal instead.
    var refusal: SeatLearningRefusal?
    var reachable = true
    var hasSeat = true
    /// Every request the phone sent, by action, as the bytes it would have signed.
    var requests: [(AppWire.Action, Data)] = []
    var issuedAt: Int64 = 1_795_600_000

    func exchange(_ action: AppWire.Action, _ request: (String, String, String) -> Data?) -> DeviceSeatService.LearningExchange {
        guard hasSeat else { return .noSeat }
        guard let body = request(Self.lease, Self.seatID, Self.profileId) else { return .noSeat }
        requests.append((action, body))
        guard reachable else { return .unreachable }
        let decoder = SeatLearningWire.decoder(), encoder = SeatLearningWire.encoder()
        switch action {
        case .learningCandidate:
            if let refusal { return .reply(try! encoder.encode(SeatLearningCandidateReply(refusal: refusal))) }
            guard let wire = try? decoder.decode(SeatLearningCandidateRequest.self, from: body),
                  (try? SeatLearningCheck.check(wire)) != nil else {
                return .reply(try! encoder.encode(SeatLearningCandidateReply(refusal: .badRequest)))
            }
            let kept = SeatLearningIntake.keep(wire.candidate, held: held[wire.candidate.candidateID])
            held[kept.candidateID] = kept
            let answer = statuses[kept.candidateID].map { $0.revision >= kept.revision ? $0 : nil } ?? nil
            let status = answer ?? SeatLearningStatus(candidateID: kept.candidateID, revision: kept.revision,
                                                      profileId: kept.profileId, seatID: kept.seatID, status: .received,
                                                      issuedAt: issuedAt)
            if answer == nil { statuses[kept.candidateID] = status }
            return .reply(try! encoder.encode(SeatLearningCandidateReply(status: status)))
        case .learningStatus:
            guard let ask = try? decoder.decode(SeatLearningStatusRequest.self, from: body) else { return .unreachable }
            return .reply(try! encoder.encode(SeatLearningIntake.page(Array(statuses.values), after: ask.after)))
        }
    }

    func decide(_ id: String, _ code: SeatLearningStatusCode, entry: String? = nil, reason: String? = nil) {
        let revision = held[id]?.revision ?? 1
        statuses[id] = SeatLearningStatus(candidateID: id, revision: revision, profileId: Self.profileId, seatID: Self.seatID,
                                          status: code, entryID: entry, reason: reason, issuedAt: issuedAt + 60)
    }
}

@MainActor
final class LearningPortalTests: XCTestCase {
    private var tempRoot: URL!
    private var store: LearningCandidateStore!
    private var queue: OfflineQueue!
    private var outbox: LearningPortalOutbox!
    private var engine: SyncEngine!
    private var portal: FakePortal!
    private var hipaa = false
    private var route: AppRoute = .portal
    private var capability: FieldAssistCapabilityCheck = .granted
    private var recorded: [LearningCandidate] = []

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("LearningPortalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = LearningCandidateStore(directory: tempRoot.appendingPathComponent("candidates", isDirectory: true))
        queue = OfflineQueue(path: tempRoot.appendingPathComponent("queue.sqlite"))
        portal = FakePortal()
        outbox = LearningPortalOutbox(candidates: store)
        outbox.hipaaMode = { [unowned self] in self.hipaa }
        outbox.route = { [unowned self] in self.route }
        outbox.capability = { [unowned self] in self.capability }
        outbox.exchange = { [unowned self] action, request in self.portal.exchange(action, request) }
        outbox.recordStatus = { [unowned self] in self.recorded.append($0) }
        let box = outbox!
        engine = SyncEngine(queue: queue, sink: LearningPortalSink(fallback: LocalSyncSink(), outbox: { box }))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func file(_ n: Int, revision: Int = 1, finding: String = "On this model the E228 is the harness at the plug, not the switch.") -> LearningCandidate {
        let candidate = LearningCandidate(
            id: String(format: "%032x", n), revision: revision, sessionId: "session-\(n)", jobReference: "J-\(1000 + n)",
            taskId: nil, vaultId: "fixture-crew-units",
            equipment: .init(modelToken: "QXRT-990", heading: "QXRT-990", source: "nameplate"), spokenModel: nil,
            finding: finding, symptom: "E228 on start", fix: nil,
            evidence: .init(pagesVerified: ["Installation manual p. 12"], readings: 2, photos: 1),
            author: "Fixture Technician", createdAt: Date(timeIntervalSince1970: 1_795_564_800), redactions: [])
        store.add(candidate)
        return candidate
    }

    private var pending: [QueuedOp] { queue.pending(limit: 50).filter { $0.kind == .teamLearningPortal } }

    // MARK: - Contract

    static func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: LearningPortalTests.self).url(forResource: "team-learning-portal-v1", withExtension: nil))
        return try Data(contentsOf: url.appendingPathComponent(name))
    }

    func testThePhoneWritesTheGoldenCandidate() throws {
        let golden = try SeatLearningWire.decoder().decode(SeatLearningCandidateRequest.self, from: Self.fixture("candidate-request-v1.json"))
        let wire = golden.candidate
        let phone = LearningCandidate(
            id: wire.candidateID, revision: wire.revision, sessionId: "6F1C2D3E-0000-4000-8000-000000000001",
            jobReference: wire.jobNumber, taskId: wire.taskID, vaultId: wire.vaultID,
            equipment: .init(modelToken: "QXRT-990", heading: "QXRT-990", source: "nameplate"), spokenModel: nil,
            finding: wire.finding, symptom: wire.symptom, fix: wire.fix,
            evidence: .init(pagesVerified: wire.evidence.pagesVerified, citationsOpened: wire.evidence.citationsOpened,
                            readings: wire.evidence.readings, photos: wire.evidence.photos),
            author: wire.author, createdAt: Date(timeIntervalSince1970: TimeInterval(wire.createdAt)), redactions: wire.redactions)
        let built = LearningPortalOutbox.wire(phone, profileId: wire.profileId, seatID: wire.seatID)
        // The phone's bytes, read by the portal's side of the contract, are the golden candidate.
        let bytes = try AppWire.encoder().encode(AppCandidateRequest(lease: golden.lease, candidate: built))
        XCTAssertEqual(try SeatLearningWire.decoder().decode(SeatLearningCandidateRequest.self, from: bytes), golden)
        XCTAssertNoThrow(try AppCheck.check(AppCandidateRequest(lease: golden.lease, candidate: built)))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("6F1C2D3E"), "the job session id never travels")
    }

    func testThePhonesJobKeyIsTheCoresHash() throws {
        struct Case: Decodable { let profileId: String; let sessionId: String; let jobSessionID: String }
        let cases = try JSONDecoder().decode([Case].self, from: Self.fixture("job-session-ids-v1.json"))
        XCTAssertEqual(cases.count, 3)
        for item in cases {
            XCTAssertEqual(LearningPortalOutbox.jobSessionID(profileId: item.profileId, sessionId: item.sessionId), item.jobSessionID)
        }
    }

    func testThePhonesRouteRuleIsTheFixtures() throws {
        struct Case: Decodable { let officeBinding: Bool; let portalCompanyVaults: Bool; let portalSwitchedOn: Bool; let route: String }
        for item in try JSONDecoder().decode([Case].self, from: Self.fixture("routes-v1.json")) {
            XCTAssertEqual(AppRoute.choose(officeBinding: item.officeBinding, portalCompanyVaults: item.portalCompanyVaults,
                                           portalSwitchedOn: item.portalSwitchedOn).rawValue, item.route)
        }
        XCTAssertEqual(TeamLearningRoute.choose(record: nil, profile: nil, portalSwitchedOn: true), .reviewerDevice,
                       "a phone with no company reviews on a reviewer's phone, as before")
    }

    func testThePhoneHoldsTheGoldenNegativesToTheSameRules() throws {
        struct Case: Decodable { let name: String; let request: OpenGlasses.SeatLearningCandidateRequest }
        for item in try JSONDecoder().decode([Case].self, from: Self.fixture("negative-candidates-v1.json")) {
            XCTAssertThrowsError(try AppCheck.check(item.request), item.name)
        }
        XCTAssertNoThrow(try AppCheck.check(try JSONDecoder().decode(AppCandidateRequest.self, from: Self.fixture("candidate-request-v1.json"))))
    }

    func testTheProfileSwitchIsOnUnlessTheProfileSaysOff() {
        XCTAssertEqual(SettingKey.organizationTeamLearningsInPortal.kind, .profileOwned(.bool))
        XCTAssertNotEqual(SettingKey.organizationTeamLearningsInPortal.ownedDescription, "organizationTeamLearningsInPortal")
        XCTAssertTrue(Config.organizationTeamLearningsInPortal, "on by default (decision 9)")
    }

    // MARK: - Sending

    func testAFiledLearningIsSentOnceAndIsSentOnlyOnReceived() async throws {
        portal.reachable = false
        let candidate = file(1)
        XCTAssertTrue(outbox.enqueue(candidate, in: queue))
        await engine.flush()
        XCTAssertEqual(pending.count, 1, "offline: still queued")
        XCTAssertEqual(pending.first?.attempts, 0, "and no attempt counted")
        XCTAssertEqual(store.candidate(id: candidate.id)?.status, .filed)

        portal.reachable = true
        await engine.flush()
        XCTAssertTrue(pending.isEmpty)
        let sent = try XCTUnwrap(store.candidate(id: candidate.id))
        XCTAssertEqual(sent.status, .sent)
        XCTAssertEqual(sent.portalReceivedRevision, 1)
        XCTAssertEqual(portal.held.count, 1, "it reached the portal")
        XCTAssertEqual(recorded.last?.status, .sent, "the job heard it")
        // The queue held the id and revision, never the words.
        XCTAssertFalse(portal.requests.isEmpty)
        XCTAssertFalse(outbox.enqueue(sent, in: queue), "nothing more is owed")
        XCTAssertEqual(TeamLearningStatusLine.spoken(sent, route: .portal), "sent to your company's administrator, awaiting review")
    }

    func testARefusedSendStaysQueuedAndIsNamedOnTheJob() async throws {
        portal.refusal = .routeOff
        let candidate = file(2)
        outbox.enqueue(candidate, in: queue)
        await engine.flush()
        await engine.flush()
        XCTAssertEqual(pending.count, 1, "refused: still queued")
        XCTAssertEqual(pending.first?.attempts, 0, "a refusal is not a failed attempt")
        let refused = try XCTUnwrap(store.candidate(id: candidate.id))
        XCTAssertEqual(refused.status, .filed)
        XCTAssertEqual(refused.portalRefusal, "routeOff")
        XCTAssertEqual(recorded.count, 1, "named on the job once, not on every retry")
        XCTAssertEqual(recorded.last?.reference.sendRefusal, "routeOff")
        XCTAssertEqual(TeamLearningStatusLine.spoken(refused, route: .portal),
                       "not sent yet: your company doesn't review team learnings in the portal")

        portal.refusal = nil
        await engine.flush()
        XCTAssertTrue(pending.isEmpty)
        let sent = try XCTUnwrap(store.candidate(id: candidate.id))
        XCTAssertEqual(sent.status, .sent)
        XCTAssertNil(sent.portalRefusal, "the refusal clears once it is received")
        XCTAssertNil(sent.reference.sendRefusal)
    }

    func testADuplicateRevisionIsIdempotent() async throws {
        let candidate = file(3)
        outbox.enqueue(candidate, in: queue)
        outbox.enqueue(candidate, in: queue)
        XCTAssertEqual(pending.count, 1, "the same candidate is queued once")
        await engine.flush()
        // The same revision sent again (a retry whose answer was lost) is the same `received`.
        queue.enqueue(.make(portalCandidate: candidate))
        let before = portal.requests.count
        await engine.flush()
        XCTAssertEqual(portal.requests.count, before, "a revision already received is not sent again")
        let replay = try AppWire.encoder().encode(AppCandidateRequest(
            lease: FakePortal.lease, candidate: LearningPortalOutbox.wire(candidate, profileId: FakePortal.profileId, seatID: FakePortal.seatID)))
        let first = portal.exchange(.learningCandidate) { _, _, _ in replay }
        let second = portal.exchange(.learningCandidate) { _, _, _ in replay }
        XCTAssertEqual(first, second, "the portal answers a replay with the same received")
        XCTAssertEqual(portal.held.count, 1)
        XCTAssertEqual(store.candidate(id: candidate.id)?.status, .sent)
    }

    func testANewerRevisionSupersedesTheQueuedOneAndAWithdrawalTravelsOnlyIfItWasReceived() async throws {
        let candidate = file(4)
        outbox.enqueue(candidate, in: queue)
        var amended = candidate
        amended.revision = 2
        amended.finding = "On this model the E228 is the harness at the plug."
        store.update(amended)
        outbox.enqueue(amended, in: queue)
        XCTAssertEqual(pending.count, 1)
        await engine.flush()
        XCTAssertEqual(portal.held[candidate.id]?.revision, 2, "the send read the candidate as it stood")
        XCTAssertEqual(portal.requests.count, 1)

        var withdrawn = try XCTUnwrap(store.candidate(id: candidate.id))
        withdrawn.status = .withdrawn; withdrawn.finding = ""; withdrawn.symptom = nil; withdrawn.revision = 3
        store.update(withdrawn)
        XCTAssertTrue(outbox.enqueue(withdrawn, in: queue))
        await engine.flush()
        XCTAssertEqual(portal.held[candidate.id]?.withdrawn, true)
        XCTAssertEqual(portal.held[candidate.id]?.finding, "", "a withdrawal carries no words")

        var never = file(5)
        never.status = .withdrawn; never.finding = ""; never.revision = 2
        store.update(never)
        XCTAssertFalse(outbox.enqueue(never, in: queue), "taken back before it ever left: nothing goes")
    }

    func testHIPAASendsNothingAndFetchesNothing() async throws {
        let queued = file(6)
        outbox.enqueue(queued, in: queue)
        hipaa = true
        XCTAssertFalse(outbox.enqueue(file(7), in: queue))
        XCTAssertEqual(outbox.enqueueOwed(in: queue), 0)
        await engine.flush()
        XCTAssertEqual(pending.count, 1, "the queued one waits")
        var sent = try XCTUnwrap(store.candidate(id: queued.id))
        sent.status = .sent
        store.update(sent)
        let fetched = await outbox.refreshStatuses()
        XCTAssertEqual(fetched, 0)
        XCTAssertTrue(portal.requests.isEmpty, "nothing reached the licence service under HIPAA mode")
    }

    func testALapsedLicenceStopsSendingAndKeepsWhatWasPublished() async throws {
        let experience = CompanyExperienceStore(directory: tempRoot.appendingPathComponent("experience", isDirectory: true))
        let set = try JSONDecoder().decode(OpenGlasses.CrewExperienceSet.self,
                                           from: CompanyExperienceContractTests.fixture("set-v1.json"))
        experience.apply(.init(profileId: set.profileId, vaultId: set.vaultId, sequence: set.sequence, revision: "r",
                               issuedAt: Date(), appliedAt: Date(), entries: CompanyExperienceStore.entries(of: set), retractedIDs: []))
        let published = experience.entries.map(\.id)
        XCTAssertFalse(published.isEmpty)

        capability = .denied(.expired(Date(timeIntervalSince1970: 1_795_000_000)))
        let candidate = file(8)
        outbox.enqueue(candidate, in: queue)
        await engine.flush()
        XCTAssertEqual(pending.count, 1, "kept queued for when the licence is back")
        XCTAssertEqual(store.candidate(id: candidate.id)?.status, .filed)
        let fetched = await outbox.refreshStatuses()
        XCTAssertEqual(fetched, 0)
        XCTAssertTrue(portal.requests.isEmpty, "a lapsed licence sends nothing")
        XCTAssertEqual(experience.entries.map(\.id), published, "what was published stays")

        capability = .granted
        await engine.flush()
        XCTAssertEqual(store.candidate(id: candidate.id)?.status, .sent)
    }

    func testNoSeatOrAnotherRouteSendsNothing() async throws {
        portal.hasSeat = false
        let candidate = file(9)
        outbox.enqueue(candidate, in: queue)
        await engine.flush()
        XCTAssertEqual(pending.count, 1, "waits for the seat")
        XCTAssertTrue(portal.requests.isEmpty)

        route = .reviewerDevice
        XCTAssertFalse(outbox.enqueue(file(10), in: queue), "off the portal route nothing is queued for it")
        let outcome = await outbox.deliver(pending[0])
        XCTAssertEqual(outcome,
                       .permanent(reason: "this company no longer reviews team learnings in the portal; the team learning stays on this phone"))
        route = .office
        XCTAssertEqual(outbox.enqueueOwed(in: queue), 0)
    }

    // MARK: - Hearing back

    func testDecisionsComeBackPageByPageToTheAuthorsJob() async throws {
        let approved = file(11), declined = file(12), merged = file(13)
        for candidate in [approved, declined, merged] { outbox.enqueue(candidate, in: queue) }
        await engine.flush()
        // Plenty of other seats' work on the portal's side would not fit one page; this seat's own
        // statuses are all the phone gets.
        for n in 100..<160 {
            let id = String(format: "%032x", n)
            portal.statuses[id] = SeatLearningStatus(candidateID: id, revision: 1, profileId: FakePortal.profileId, seatID: FakePortal.seatID,
                                                     status: .notTakenUp, reason: String(repeating: "Not for this vault. ", count: 10),
                                                     issuedAt: 1_795_600_000)
        }
        portal.decide(approved.id, .approved, entry: String(format: "%032x", 9001))
        portal.decide(declined.id, .notTakenUp, reason: "Already in the sheet as row 17.")
        portal.decide(merged.id, .merged, entry: String(format: "%032x", 9017))
        recorded = []
        let changed = await outbox.refreshStatuses()
        XCTAssertEqual(changed, 3)
        let statusRequests = portal.requests.filter { $0.0 == .learningStatus }
        XCTAssertGreaterThan(statusRequests.count, 1, "paged")
        let cursors = try statusRequests.map { try SeatLearningWire.decoder().decode(SeatLearningStatusRequest.self, from: $0.1).after }
        XCTAssertNil(cursors.first ?? nil)
        XCTAssertNotNil(cursors.last ?? nil)

        XCTAssertEqual(store.candidate(id: approved.id)?.status, .approved)
        XCTAssertEqual(store.candidate(id: approved.id)?.entryID, String(format: "%032x", 9001))
        let notTaken = try XCTUnwrap(store.candidate(id: declined.id))
        XCTAssertEqual(notTaken.status, .notTakenUp)
        XCTAssertEqual(notTaken.reviewReason, "Already in the sheet as row 17.")
        XCTAssertEqual(TeamLearningStatusLine.spoken(notTaken, route: .portal), "not taken up: Already in the sheet as row 17")
        XCTAssertEqual(store.candidate(id: merged.id)?.status, .merged)
        XCTAssertEqual(Set(recorded.map(\.id)), [approved.id, declined.id, merged.id], "each reached its job")

        // Final is final: a later answer changes nothing, and nothing sent is left to ask after.
        portal.decide(approved.id, .notTakenUp, reason: "Changed my mind.")
        let later = await outbox.refreshStatuses()
        XCTAssertEqual(later, 0)
        XCTAssertEqual(store.candidate(id: approved.id)?.status, .approved)
    }

    func testAStatusForAnotherSeatOrCompanyIsIgnored() throws {
        let candidate = file(14)
        let other = AppStatus(candidateID: candidate.id, revision: 1, profileId: FakePortal.profileId,
                              seatID: String(repeating: "cd", count: 32), status: .approved,
                              entryID: String(format: "%032x", 1), issuedAt: 1_795_600_000)
        XCTAssertFalse(outbox.apply(other, profileId: FakePortal.profileId, seatID: FakePortal.seatID))
        let company = AppStatus(candidateID: candidate.id, revision: 1, profileId: "another-company",
                                seatID: FakePortal.seatID, status: .approved, entryID: String(format: "%032x", 1),
                                issuedAt: 1_795_600_000)
        XCTAssertFalse(outbox.apply(company, profileId: FakePortal.profileId, seatID: FakePortal.seatID))
        let malformed = AppStatus(candidateID: candidate.id, revision: 1, profileId: FakePortal.profileId,
                                  seatID: FakePortal.seatID, status: .approved, issuedAt: 1_795_600_000)
        XCTAssertFalse(outbox.apply(malformed, profileId: FakePortal.profileId, seatID: FakePortal.seatID),
                       "approved without an entry fails the contract's check")
        XCTAssertEqual(store.candidate(id: candidate.id)?.status, .filed)
    }

    func testTheStatusLineIsUnchangedOffThePortalRoute() {
        let candidate = file(15)
        XCTAssertEqual(TeamLearningStatusLine.spoken(candidate, route: .reviewerDevice), candidate.status.spoken)
        XCTAssertEqual(TeamLearningStatusLine.spoken(candidate, route: .office), candidate.status.spoken)
        XCTAssertEqual(TeamLearningStatusLine.spoken(candidate, route: .portal), "filed, waiting to go to your company's administrator")
        for refusal in AppRefusal.allCases { XCTAssertFalse(TeamLearningStatusLine.words(refusal).isEmpty) }
    }
}
