import XCTest
@testable import OpenGlasses

/// Plan GB P0 — "send the report" straight after the job was closed.
///
/// The field test closed job 1011 by voice and asked for the report two seconds later; the tool
/// answered "No active Field Assist session". The table below is the rule for which finished job
/// is meant; the tool tests drive the real service against a temp directory.
@MainActor
final class ReportTargetResolverTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReportTargetResolverTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private func ended(_ id: String, thread: String? = "t-job", minutesAgo: Double,
                       sent: Bool = false) -> ReportTargetResolver.EndedJob {
        .init(sessionId: id, threadId: thread, endedAt: now.addingTimeInterval(-minutesAgo * 60),
              reportSent: sent)
    }

    // MARK: - The table

    func testAnOpenJobIsAlwaysTheTarget() {
        XCTAssertEqual(ReportTargetResolver.resolve(active: true, recentEnded: [ended("a", minutesAgo: 1)],
                                                    thread: .none, now: now), .active)
    }

    func testAJobClosedMomentsAgoInThisConversationIsTheTarget() {
        // The close ends the job's thread, so nothing is open — the diagnostics' case exactly.
        XCTAssertEqual(ReportTargetResolver.resolve(active: false, recentEnded: [ended("a", minutesAgo: 0.1)],
                                                    thread: .none, now: now), .ended(sessionId: "a"))
        // Still in the job's own thread.
        XCTAssertEqual(ReportTargetResolver.resolve(active: false, recentEnded: [ended("a", minutesAgo: 2)],
                                                    thread: .init(id: "t-job"), now: now),
                       .ended(sessionId: "a"))
        // A conversation begun after the close carries on from it.
        XCTAssertEqual(ReportTargetResolver.resolve(
            active: false, recentEnded: [ended("a", minutesAgo: 5)],
            thread: .init(id: "t-new", createdAt: now.addingTimeInterval(-60)), now: now),
                       .ended(sessionId: "a"))
    }

    func testTheMostRecentlyEndedJobIsTheOneMeant() {
        let target = ReportTargetResolver.resolve(
            active: false, recentEnded: [ended("older", minutesAgo: 20), ended("newer", minutesAgo: 3)],
            thread: .none, now: now)
        XCTAssertEqual(target, .ended(sessionId: "newer"))
    }

    func testAJobEndedLongAgoIsRefused() {
        let target = ReportTargetResolver.resolve(active: false, recentEnded: [ended("a", minutesAgo: 31)],
                                                  thread: .none, now: now)
        XCTAssertEqual(target, .refuse(reason: ReportTargetResolver.noJobReason))
        XCTAssertEqual(ReportTargetResolver.resolve(active: false, recentEnded: [], thread: .none, now: now),
                       .refuse(reason: ReportTargetResolver.noJobReason))
    }

    func testAJobAlreadySentIsRefused() {
        let target = ReportTargetResolver.resolve(active: false,
                                                  recentEnded: [ended("a", minutesAgo: 1, sent: true)],
                                                  thread: .none, now: now)
        XCTAssertEqual(target, .refuse(reason: ReportTargetResolver.alreadySentReason))
    }

    func testAJobFromAnotherConversationIsRefused() {
        // An older conversation, opened from the switcher after the close, is somebody else's.
        let target = ReportTargetResolver.resolve(
            active: false, recentEnded: [ended("a", minutesAgo: 2)],
            thread: .init(id: "t-other", createdAt: now.addingTimeInterval(-3_600)), now: now)
        XCTAssertEqual(target, .refuse(reason: ReportTargetResolver.otherConversationReason))
    }

    // MARK: - The tool

    private func settings() -> DeliverySettings {
        DeliverySettings(emailRecipients: ["office@example.com"], messageRecipients: [],
                         endpoint: "", endpointToken: "", allowedChannels: DeliveryChannel.localChannels)
    }

    private func closedJob() throws -> (FieldSessionService, String) {
        let service = FieldSessionService(sessionsRoot: tempRoot)
        let session = try service.startSession(vaultId: "refrigeration", assetId: nil, jobReference: "1011")
        let pdf = tempRoot.appendingPathComponent("r.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        service.reportAttachmentsProvider = { [.init(url: pdf, kind: .pdf, filename: "r.pdf")] }
        _ = try service.endSession(outcome: .resolved)
        return (service, session.id)
    }

    func testCloseThenSendStagesTheClosedJobsReportWithoutReopeningIt() async throws {
        let (service, id) = try closedJob()
        let tool = DeliverReportTool(sessionService: service, settings: { self.settings() })

        _ = try await tool.execute(args: [:])
        let staged = try XCTUnwrap(service.stagedDelivery, "the finished job's report is staged")
        XCTAssertEqual(staged.sessionId, id)
        XCTAssertNil(service.activeSession, "sending a report never reopens the job")
        XCTAssertEqual(service.history.first?.outcome, .resolved)
    }

    func testASecondSendAfterTheFirstWentIsRefused() async throws {
        let (service, _) = try closedJob()
        let tool = DeliverReportTool(sessionService: service, settings: { self.settings() })
        _ = try await tool.execute(args: [:])
        let staged = try XCTUnwrap(service.stagedDelivery)
        service.completeDelivery(staged, outcome: .sent)

        let again = try await tool.execute(args: [:])
        XCTAssertEqual(again, ReportTargetResolver.alreadySentReason)
    }

    func testTheEndResultTellsTheModelTheReportCanStillBeSent() async throws {
        let service = FieldSessionService(sessionsRoot: tempRoot)
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        let reply = try await FieldSessionTool(service: service).execute(args: ["action": "end"])
        XCTAssertTrue(reply.contains("deliver_report"), reply)
    }
}
