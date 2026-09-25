import XCTest
@testable import OpenGlasses

/// Plan CT PR 4 — leaving the firm: the organisation's content goes at once; its session logs and
/// waiting reports go to it first and are erased once its endpoint has accepted them, or once the
/// window has passed; nothing is erased mid-job.
@MainActor
final class OrgDepartureTests: XCTestCase {

    private var now = Date(timeIntervalSince1970: 1_790_000_000)
    private var saved: OrgDeparture?
    private var sessions: [(id: String, startedAt: Date)] = []
    private var activeJob: String?
    private var erasedContentFor: [String?] = []
    private var erasedRecords: [[String]] = []
    private var endpoint = false
    private var outstandingCount = 0
    private var flushes = 0
    private let enrolledAt = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUp() {
        super.setUp()
        now = Date(timeIntervalSince1970: 1_790_000_000)
        saved = nil
        sessions = [("before", enrolledAt.addingTimeInterval(-60)),
                    ("job-1", enrolledAt.addingTimeInterval(3_600)),
                    ("job-2", enrolledAt.addingTimeInterval(7_200))]
        activeJob = nil
        erasedContentFor = []
        erasedRecords = []
        endpoint = false
        outstandingCount = 0
        flushes = 0
    }

    private func makeService() -> OrgDepartureService {
        var seams = OrgDepartureService.Seams()
        seams.now = { [unowned self] in self.now }
        seams.load = { [unowned self] in self.saved }
        seams.save = { [unowned self] in self.saved = $0 }
        seams.sessionIds = { [unowned self] since in self.sessions.filter { $0.startedAt >= since }.map { $0.id } }
        seams.activeJobId = { [unowned self] in self.activeJob }
        seams.eraseContent = { [unowned self] packId in self.erasedContentFor.append(packId) }
        seams.hasEndpoint = { [unowned self] in self.endpoint }
        seams.flushEndpoint = { [unowned self] in self.flushes += 1 }
        seams.outstanding = { [unowned self] _ in self.outstandingCount }
        seams.eraseRecords = { [unowned self] ids in self.erasedRecords.append(ids) }
        let service = OrgDepartureService(seams: seams)
        service.loadAtLaunch()
        return service
    }

    private func leave(_ service: OrgDepartureService, reason: OrgDeparture.Reason = .revoked,
                       days: Int? = nil) async {
        await service.begin(reason, organizationName: "Northbridge Mechanical", enrolmentId: "e1",
                            enrolledAt: enrolledAt, packId: "hvac_rtu_pack", undeliveredEraseDays: days)
    }

    // MARK: - At once

    func testTheFirmsContentGoesAtOnceAndOnlyTheManagedPeriodsLogsAreOwed() async {
        let service = makeService()
        await leave(service)
        XCTAssertEqual(erasedContentFor, ["hvac_rtu_pack"], "the pack's vault, jobs ahead and staged exports")
        XCTAssertEqual(saved?.sessionIds, ["job-1", "job-2"], "a log from before enrolment is the wearer's own")
        XCTAssertEqual(saved?.eraseBy, now.addingTimeInterval(30 * 86_400), "30 days unless the profile says")
    }

    func testTheProfileSetsTheWindowWithinItsBounds() async {
        let service = makeService()
        await leave(service, days: 10)
        XCTAssertEqual(saved?.eraseBy, now.addingTimeInterval(10 * 86_400))

        saved = nil
        let other = makeService()
        await leave(other, days: 9_999)
        XCTAssertEqual(saved?.eraseBy, now.addingTimeInterval(365 * 86_400))
    }

    // MARK: - Delivered, then erased

    func testAcceptedByTheEndpointMeansDeliveredAndErased() async {
        endpoint = true
        let service = makeService()
        await leave(service)
        XCTAssertEqual(flushes, 1)
        XCTAssertEqual(erasedRecords, [["job-1", "job-2"]])
        XCTAssertEqual(saved?.deliveredToFirm, true)
        XCTAssertFalse(saved?.isPending ?? true)
    }

    func testUnacceptedRecordsWaitAndAreRetriedUntilTheEndpointTakesThem() async {
        endpoint = true
        outstandingCount = 2
        let service = makeService()
        await leave(service)
        XCTAssertEqual(erasedRecords, [], "not accepted yet — kept, and retried")
        XCTAssertTrue(saved?.isPending ?? false)

        outstandingCount = 0
        now = now.addingTimeInterval(86_400)
        await makeService().settle()
        XCTAssertEqual(erasedRecords.count, 1)
        XCTAssertEqual(saved?.deliveredToFirm, true)
    }

    func testWithoutAnEndpointNothingCountsAsDeliveredAndTheWindowDecides() async {
        let service = makeService()
        await leave(service)
        XCTAssertEqual(flushes, 0, "no endpoint: the local sink would mark records done without sending")
        XCTAssertEqual(erasedRecords, [])

        now = now.addingTimeInterval(29 * 86_400)
        await service.settle()
        XCTAssertEqual(erasedRecords, [])

        now = now.addingTimeInterval(86_400)
        await service.settle()
        XCTAssertEqual(erasedRecords, [["job-1", "job-2"]])
        XCTAssertEqual(saved?.deliveredToFirm, false, "the erasure records that it never reached the firm")
    }

    func testNothingIsErasedMidJob() async {
        endpoint = true
        activeJob = "job-3"
        let service = makeService()
        await leave(service)
        now = now.addingTimeInterval(40 * 86_400)
        await service.settle()
        XCTAssertEqual(erasedRecords, [], "not even past the window")

        activeJob = nil
        await service.settle()
        XCTAssertEqual(erasedRecords.count, 1)
    }

    func testLeavingTwiceForTheSameEnrolmentChangesNothing() async {
        outstandingCount = 1
        endpoint = true
        let service = makeService()
        await leave(service, reason: .revoked)
        let first = saved
        now = now.addingTimeInterval(3_600)
        await leave(service, reason: .removed)
        XCTAssertEqual(saved, first, "a revoked phone its owner then removes keeps the first window")
        XCTAssertEqual(erasedContentFor.count, 1)
    }

    // MARK: - Which logs are the firm's

    func testOnlyLogsFromTheManagedPeriodAreTheFirms() {
        func session(_ id: String, _ offset: TimeInterval) -> FieldSession {
            FieldSession(id: id, vaultId: "v", assetId: nil, mode: .aiOnly,
                         startedAt: enrolledAt.addingTimeInterval(offset), outcome: .resolved,
                         escalations: [], billableSeconds: 0)
        }
        let history = [session("mine", -60), session("theirs", 0), session("theirs-too", 3_600)]
        XCTAssertEqual(OrgDepartureService.managedSessionIds(history, since: enrolledAt),
                       ["theirs", "theirs-too"],
                       "the removal prompt and the departure agree on what is owed")
    }
}
