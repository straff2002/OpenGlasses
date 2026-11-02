import Combine
import UIKit
import XCTest
@testable import OpenGlasses

/// Owner decision: Medical Compliance has no live expert stream, Local Only or not. The job and the
/// help request carry on without it.
@MainActor
final class ExpertStreamMedicalPolicyTests: XCTestCase {

    private typealias Policy = ExpertStreamMedicalPolicy
    private let medical = MedicalEgressGuard.Mode(hipaaMode: true, localOnly: false)

    private final class FakeTransport: ExpertStreamTransport {
        let displayName = "Fake"
        let isAvailable = true
        private(set) var isStreaming = false
        private(set) var starts = 0
        func start(framePublisher: PassthroughSubject<UIImage, Never>) async throws -> String? {
            starts += 1
            isStreaming = true
            return "https://example.invalid/room"
        }
        func stop() async { isStreaming = false }
    }

    private var transport = FakeTransport()
    private var previousMode: (() -> MedicalEgressGuard.Mode)!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var tempRoot: URL!

    private func bridge() -> ExpertStreamBridge {
        let transports = Dictionary(uniqueKeysWithValues: ExpertStreamKind.allCases.map {
            ($0, transport as ExpertStreamTransport)
        })
        return ExpertStreamBridge(transports: transports, framePublisher: PassthroughSubject<UIImage, Never>())
    }

    private func coordinator() -> EscalationCoordinator {
        let coordinator = EscalationCoordinator()
        coordinator.notifier = StubExpertNotifier()
        coordinator.bridge = bridge()
        coordinator.sessionService = FieldSessionService(sessionsRoot: tempRoot)
        return coordinator
    }

    override func setUp() {
        super.setUp()
        previousMode = MedicalEgressGuard.currentMode
        previousEntitlement = EntitlementTestScope.grant()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExpertStreamMedical-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        MedicalEgressGuard.currentMode = previousMode
        EntitlementTestScope.restore(previousEntitlement)
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - The decision

    func testRefusedInMedicalCompliance() {
        XCTAssertEqual(Policy.decide(medical), .refuse)
    }

    func testRefusedInLocalOnly() {
        XCTAssertEqual(Policy.decide(.localOnly), .refuse)
    }

    func testAllowedOtherwise() {
        XCTAssertEqual(Policy.decide(.off), .allow)
    }

    /// Local Only binds only with the mode on, so alone it is not a reason to refuse.
    func testALeftoverLocalOnlySwitchIsNotARefusal() {
        XCTAssertEqual(Policy.decide(.init(hipaaMode: false, localOnly: true)), .allow)
    }

    func testARunningStreamEndsWhenTheModeTurnsOn() {
        XCTAssertEqual(Policy.whileRunning(isStreaming: true, mode: medical), .end)
        XCTAssertEqual(Policy.whileRunning(isStreaming: true, mode: .localOnly), .end)
    }

    func testARunningStreamCarriesOnOutsideTheMode() {
        XCTAssertEqual(Policy.whileRunning(isStreaming: true, mode: .off), .carryOn)
    }

    func testNothingRunningIsNothingToEnd() {
        XCTAssertEqual(Policy.whileRunning(isStreaming: false, mode: medical), .carryOn)
    }

    func testTheWordsSayWhyAndThatTheJobCarriesOn() {
        XCTAssertTrue(Policy.refusalMessage.contains("Medical Compliance"))
        XCTAssertTrue(Policy.refusalMessage.contains("job record"))
        XCTAssertTrue(Policy.endedMessage.contains("Medical Compliance"))
        XCTAssertTrue(Policy.endedMessage.contains("job carries on"))
        XCTAssertTrue(Policy.liveViewOffSummary.contains("Medical Compliance"))
    }

    // MARK: - Every route

    func testTheBrowserStreamRefuses() {
        MedicalEgressGuard.currentMode = { self.medical }
        let service = WebRTCStreamingService()
        XCTAssertEqual(service.startStreaming(framePublisher: PassthroughSubject<UIImage, Never>()), "")
        XCTAssertFalse(service.isStreaming)
        XCTAssertEqual(service.errorMessage, Policy.refusalMessage)
    }

    func testThePeerTransportRefuses() async {
        MedicalEgressGuard.currentMode = { self.medical }
        await assertRefused(WebRTCPeerTransport())
    }

    func testTheMeetingLinkRefusesAndOpensNothing() async {
        MedicalEgressGuard.currentMode = { self.medical }
        let meeting = MeetingLinkTransport()
        var opened = false
        meeting.opener = { _ in opened = true }
        await assertRefused(meeting)
        XCTAssertFalse(opened)
    }

    func testTheFieldAssistTransportRefusesThroughTheStreamer() async {
        MedicalEgressGuard.currentMode = { self.medical }
        await assertRefused(MJPEGExpertTransport(streamer: WebRTCStreamingService()))
    }

    private func assertRefused(_ transport: ExpertStreamTransport,
                               line: UInt = #line) async {
        do {
            _ = try await transport.start(framePublisher: PassthroughSubject<UIImage, Never>())
            XCTFail("a stream started in Medical Compliance", line: line)
        } catch {
            XCTAssertEqual(error.localizedDescription, Policy.refusalMessage, line: line)
        }
        XCTAssertFalse(transport.isStreaming, line: line)
    }

    func testTheBridgeNeverReachesATransport() async {
        MedicalEgressGuard.currentMode = { self.medical }
        let bridge = bridge()
        do {
            try await bridge.connect(sessionId: "s", expertId: nil)
            XCTFail("the bridge connected in Medical Compliance")
        } catch {
            XCTAssertEqual(error.localizedDescription, Policy.refusalMessage)
        }
        XCTAssertEqual(transport.starts, 0)
        XCTAssertNil(bridge.roomURL)
    }

    func testTheBridgeConnectsOutsideTheMode() async throws {
        MedicalEgressGuard.currentMode = { .off }
        let bridge = bridge()
        try await bridge.connect(sessionId: "s", expertId: nil)
        XCTAssertTrue(bridge.isConnected)
    }

    // MARK: - The job carries on

    func testAHelpRequestStillPagesWithNoStream() async {
        MedicalEgressGuard.currentMode = { self.medical }
        let coordinator = coordinator()
        let state = await coordinator.requestExpert(reason: "Readings disagree with the manual")
        XCTAssertEqual(state, .awaitingExpert(reason: "Readings disagree with the manual"))
        XCTAssertEqual(transport.starts, 0)
        XCTAssertEqual(coordinator.liveViewSummary(), Policy.liveViewOffSummary)
    }

    func testAnExpertCanStillJoinWithNoLiveMedia() async {
        MedicalEgressGuard.currentMode = { self.medical }
        let coordinator = coordinator()
        await coordinator.requestExpert(reason: "Help")
        let joined = await coordinator.markExpertJoined(expertId: "expert-1")
        XCTAssertEqual(joined.state, .expertConnected(expertId: "expert-1"))
        XCTAssertFalse(joined.liveMedia)
    }

    /// The stream goes. The escalation does not.
    func testEndingTheLiveViewLeavesTheEscalationStanding() async {
        MedicalEgressGuard.currentMode = { .off }
        let coordinator = coordinator()
        let state = await coordinator.requestExpert(reason: "Help")
        XCTAssertTrue(coordinator.bridge.isConnected)

        MedicalEgressGuard.currentMode = { self.medical }
        await coordinator.endLiveView()
        XCTAssertFalse(coordinator.bridge.isConnected)
        XCTAssertFalse(transport.isStreaming)
        XCTAssertEqual(coordinator.state, state)
    }

    // MARK: - Wiring

    private static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func testTurningTheModeOnReachesARunningStream() throws {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "OpenGlasses/Sources/App/OpenGlassesApp.swift"), encoding: .utf8)
        let hook = try XCTUnwrap(source.range(of: "hipaaService.onModeChanged = {"))
        XCTAssertTrue(source[hook.lowerBound...].prefix(900).contains("enforceExpertStreamRules()"))
    }

    func testTheModeSaysSoInItsOwnList() throws {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "OpenGlasses/Sources/App/Views/HIPAASettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("title: \"Live Expert View\""))
        XCTAssertTrue(source.contains("title: \"Live Streaming\""))
    }
}
