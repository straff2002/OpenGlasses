import XCTest
@testable import OpenGlasses

/// Roadmap W04.2 — in-flight teardown.
///
/// Driven with fakes rather than the real services: the point under test is the coordinator's
/// decision (which sessions close, which are left alone, and what happens to a released one), and
/// the real participants reach the wearables SDK on construction.
@MainActor
final class MedicalEgressCoordinatorTests: XCTestCase {

    private final class FakeSession: MedicalEgressTeardown {
        let openRoutes: [NetworkRoute]
        private(set) var tearDowns = 0
        init(_ routes: [NetworkRoute]) { openRoutes = routes }
        func tearDownForMedicalEgress() { tearDowns += 1 }
    }

    private var center: NotificationCenter!
    private var previousMode: (() -> MedicalEgressGuard.Mode)!

    override func setUp() {
        super.setUp()
        center = NotificationCenter()
        previousMode = MedicalEgressGuard.currentMode
    }

    override func tearDown() {
        MedicalEgressGuard.currentMode = previousMode
        super.tearDown()
    }

    private func setMode(_ mode: MedicalEgressGuard.Mode) {
        MedicalEgressGuard.currentMode = { mode }
    }

    // MARK: - What closes

    func testBlockedSessionsAreTornDownAndPermittedOnesAreNot() {
        let coordinator = MedicalEgressCoordinator(observing: center)
        let realtime = FakeSession([.openAIRealtimeSession])
        let gateway = FakeSession([.openClawGatewaySocket])
        let modelDownload = FakeSession([.localModelDownload])
        [realtime, gateway, modelDownload].forEach(coordinator.register)

        setMode(.localOnly)
        coordinator.modeDidChange()

        XCTAssertEqual(realtime.tearDowns, 1)
        XCTAssertEqual(gateway.tearDowns, 1)
        XCTAssertEqual(modelDownload.tearDowns, 0,
                       "a permitted route's session must not be collateral damage")
        XCTAssertEqual(Set(coordinator.lastTornDownRoutes),
                       [.openAIRealtimeSession, .openClawGatewaySocket])
    }

    func testNothingIsTornDownWhenTheModeIsOff() {
        let coordinator = MedicalEgressCoordinator(observing: center)
        let realtime = FakeSession([.openAIRealtimeSession])
        coordinator.register(realtime)

        setMode(.off)
        coordinator.modeDidChange()

        XCTAssertEqual(realtime.tearDowns, 0)
        XCTAssertEqual(coordinator.lastTornDownRoutes, [])
    }

    /// A session holding several routes closes if *any* of them is refused: there is no partial
    /// teardown, because a socket is open or it is not.
    func testASessionWithAnyBlockedRouteCloses() {
        let coordinator = MedicalEgressCoordinator(observing: center)
        let mixed = FakeSession([.localModelDownload, .geminiLiveSession])
        coordinator.register(mixed)

        setMode(.localOnly)
        coordinator.modeDidChange()
        XCTAssertEqual(mixed.tearDowns, 1)
        XCTAssertEqual(coordinator.lastTornDownRoutes, [.geminiLiveSession])
    }

    // MARK: - Registration

    func testRegisteringTwiceDoesNotTearDownTwice() {
        let coordinator = MedicalEgressCoordinator(observing: center)
        let realtime = FakeSession([.openAIRealtimeSession])
        coordinator.register(realtime)
        coordinator.register(realtime)
        XCTAssertEqual(coordinator.registeredCount, 1)

        setMode(.localOnly)
        coordinator.modeDidChange()
        XCTAssertEqual(realtime.tearDowns, 1)
    }

    /// Weak by design: the coordinator listens, it does not own. A released service must not be
    /// kept alive by being registered, and must not crash a later mode change.
    func testAReleasedParticipantIsDroppedRatherThanRetained() {
        let coordinator = MedicalEgressCoordinator(observing: center)
        autoreleasepool {
            let transient = FakeSession([.openAIRealtimeSession])
            coordinator.register(transient)
            XCTAssertEqual(coordinator.registeredCount, 1)
        }
        XCTAssertEqual(coordinator.registeredCount, 0)

        setMode(.localOnly)
        coordinator.modeDidChange()
        XCTAssertEqual(coordinator.lastTornDownRoutes, [])
    }

    // MARK: - The signal

    /// The compliance switch has `HIPAAComplianceService.onModeChanged`; the Local Only switch
    /// writes `Config` directly and had no signal at all, which is the gap this notification
    /// closes.
    func testTheLocalOnlySwitchNotificationDrivesTheTeardown() {
        let coordinator = MedicalEgressCoordinator(observing: center)
        let realtime = FakeSession([.openAIRealtimeSession])
        coordinator.register(realtime)

        setMode(.localOnly)
        center.post(name: MedicalEgressCoordinator.modeDidChangeNotification, object: nil)

        XCTAssertEqual(realtime.tearDowns, 1)
    }

    func testTeardownIsIdempotentAcrossRepeatedModeChanges() {
        let coordinator = MedicalEgressCoordinator(observing: center)
        let realtime = FakeSession([.openAIRealtimeSession])
        coordinator.register(realtime)

        setMode(.localOnly)
        coordinator.modeDidChange()
        coordinator.modeDidChange()
        XCTAssertEqual(realtime.tearDowns, 2,
                       "a second mode change asks again; the service is responsible for making a "
                       + "redundant close cheap, not the coordinator")
    }
}
