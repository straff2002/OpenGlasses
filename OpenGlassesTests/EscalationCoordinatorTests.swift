import XCTest
@testable import OpenGlasses

/// Tests for the Phase 3 escalation state machine. The live ExpertBridge is pending, so these
/// verify the graceful-degradation flow: request → notify → awaiting → (expert joins, no live
/// media) → resolve, plus audit logging on the active session.
@MainActor
final class EscalationCoordinatorTests: XCTestCase {

    private var tempRoot: URL!
    private var service: FieldSessionService!
    private var coordinator: EscalationCoordinator!

    /// Notifier whose result is configurable, to exercise the success and failure branches.
    private struct ConfigurableNotifier: ExpertNotifier {
        let succeed: Bool
        func notifyExpertPool(reason: String, assetId: String?, sessionId: String, roomURL: String?) async throws -> Bool { succeed }
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistDeveloperUnlocked")
        VaultRegistry.shared.resetCache()

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EscalationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        service = FieldSessionService(sessionsRoot: tempRoot)

        coordinator = EscalationCoordinator.shared
        coordinator.reset()
        coordinator.notifier = StubExpertNotifier()
        coordinator.bridge = PendingExpertBridge()
        coordinator.sessionService = service
    }

    override func tearDown() {
        coordinator.reset()
        coordinator.notifier = StubExpertNotifier()
        coordinator.sessionService = .shared
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        UserDefaults.standard.removeObject(forKey: "fieldAssistDeveloperUnlocked")
        super.tearDown()
    }

    func testRequestExpertReachesAwaitingState() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: "Unit 47B")
        let state = await coordinator.requestExpert(reason: "Readings contradict the flowchart")
        XCTAssertEqual(state, .awaitingExpert(reason: "Readings contradict the flowchart"))
        XCTAssertTrue(coordinator.isEscalationActive)
    }

    func testRequestExpertRecordsEscalationOnSession() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        _ = await coordinator.requestExpert(reason: "Need a human")
        XCTAssertEqual(service.activeSession?.escalations.count, 1)
        XCTAssertEqual(service.activeSession?.escalations.first?.reason, "Need a human")
        XCTAssertNil(service.activeSession?.escalations.first?.resolvedAt)
    }

    func testFailedNotificationYieldsFailedState() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        coordinator.notifier = ConfigurableNotifier(succeed: false)
        let state = await coordinator.requestExpert(reason: "x")
        guard case .failed = state else { return XCTFail("Expected .failed, got \(state)") }
    }

    func testExpertJoinedTransitionsWithoutLiveMedia() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        _ = await coordinator.requestExpert(reason: "x")
        let result = await coordinator.markExpertJoined(expertId: "expert-7")
        XCTAssertEqual(result.state, .expertConnected(expertId: "expert-7"))
        XCTAssertFalse(result.liveMedia) // PendingExpertBridge never connects in Phase 3
    }

    func testResolveMarksEscalationResolvedAndLogs() async throws {
        let session = try service.startSession(vaultId: "refrigeration", assetId: nil)
        _ = await coordinator.requestExpert(reason: "x")
        await coordinator.resolve(note: "Sorted by senior tech")
        XCTAssertEqual(coordinator.state, .resolved)
        XCTAssertNotNil(service.activeSession?.escalations.first?.resolvedAt)

        let log = (try? String(contentsOf: tempRoot
            .appendingPathComponent(session.id, isDirectory: true)
            .appendingPathComponent("log.jsonl"), encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("escalation_requested"))
        XCTAssertTrue(log.contains("escalation_resolved"))
    }

    func testCancelStandsDown() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        _ = await coordinator.requestExpert(reason: "x")
        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .cancelled)
        XCTAssertFalse(coordinator.isEscalationActive)
    }

    // MARK: - Phase 5 notifier / room URL

    private final class FakeBridge: ExpertBridge {
        var isConnected = false
        var roomURL: String?
        func connect(sessionId: String, expertId: String?) async throws {
            isConnected = true
            roomURL = "https://room.example/\(sessionId)"
        }
        func disconnect() async { isConnected = false; roomURL = nil }
    }

    private final class CaptureBox { var roomURL: String?; var reason: String? }
    private struct CapturingNotifier: ExpertNotifier {
        let box: CaptureBox
        func notifyExpertPool(reason: String, assetId: String?, sessionId: String, roomURL: String?) async throws -> Bool {
            box.roomURL = roomURL; box.reason = reason; return true
        }
    }

    func testRequestExpertBringsUpBridgeAndPassesRoomURL() async throws {
        let session = try service.startSession(vaultId: "refrigeration", assetId: nil)
        let bridge = FakeBridge()
        let box = CaptureBox()
        coordinator.bridge = bridge
        coordinator.notifier = CapturingNotifier(box: box)

        _ = await coordinator.requestExpert(reason: "need eyes")
        XCTAssertTrue(bridge.isConnected, "Bridge should be brought up so the expert gets a join URL")
        XCTAssertEqual(box.roomURL, "https://room.example/\(session.id)")
        XCTAssertEqual(box.reason, "need eyes")
    }

    func testCompositeNotifierSucceedsIfAnyChannelSucceeds() async throws {
        let composite = CompositeExpertNotifier(notifiers: [
            ConfigurableNotifier(succeed: false), ConfigurableNotifier(succeed: true)
        ])
        let result = try await composite.notifyExpertPool(reason: "x", assetId: nil, sessionId: "s", roomURL: nil)
        XCTAssertTrue(result)

        let allFail = CompositeExpertNotifier(notifiers: [ConfigurableNotifier(succeed: false)])
        let failResult = try await allFail.notifyExpertPool(reason: "x", assetId: nil, sessionId: "s", roomURL: nil)
        XCTAssertFalse(failResult)
    }

    func testWebhookPayloadIncludesRoomURLAndAsset() {
        let payload = WebhookExpertNotifier.payload(reason: "flowchart mismatch", assetId: "Unit 47B",
                                                    sessionId: "sess-1", roomURL: "https://room/x")
        XCTAssertEqual(payload["room_url"] as? String, "https://room/x")
        XCTAssertEqual(payload["asset_id"] as? String, "Unit 47B")
        let text = payload["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Unit 47B"))
        XCTAssertTrue(text.contains("https://room/x"))
    }

    func testStartingSessionResetsStaleEscalation() async throws {
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        _ = await coordinator.requestExpert(reason: "x")
        _ = try service.endSession(outcome: .escalated)
        // A new session should clear any leftover escalation state.
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        XCTAssertEqual(coordinator.state, .idle)
    }
}
