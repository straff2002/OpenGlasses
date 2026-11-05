import XCTest
@testable import OpenGlasses

/// Plan GM P1a — the surface push over a fake session (never `WCSession.default`): it goes without
/// reachability, carries the phone's status with it, clears the key on expiry, and sends nothing
/// under Never.
@MainActor
final class WatchSurfacePublisherTests: XCTestCase {

    private final class FakeSession: WatchSessioning {
        var isActivated = true
        var isPaired = true
        var isWatchAppInstalled = true
        var contexts: [[String: Any]] = []
        func updateApplicationContext(_ applicationContext: [String: Any]) throws {
            contexts.append(applicationContext)
        }
    }

    private var session: FakeSession!
    private var setting: WatchMapCardsSetting = .automatic
    private var medical: MedicalEgressGuard.Mode = .off
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var base: [String: Any]? = ["status": "idle", "job": ["jobNumber": "J-1"]]

    override func setUp() {
        super.setUp()
        session = FakeSession()
        setting = .automatic
        medical = .off
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        base = ["status": "idle", "job": ["jobNumber": "J-1"]]
    }

    private func makePublisher() -> WatchSurfacePublisher {
        WatchSurfacePublisher(
            session: session,
            environment: .init(setting: { [unowned self] in self.setting },
                               medical: { [unowned self] in self.medical },
                               usesMetric: { false },
                               sendsLongLists: { false },
                               now: { [unowned self] in self.clock }),
            baseContext: { [unowned self] in self.base })
    }

    private func whereAmI(id: String = "w1") -> GlanceSurface {
        GlanceSurfaceBuilder.whereAmI(
            wearer: WearerFix(coordinate: GlancePoint(latitude: -36.85, longitude: 174.76), fixAt: clock,
                              horizontalAccuracy: 10),
            street: "Queen Street", locality: "Auckland", mapAllowed: true, now: clock, id: id)
    }

    private func pushedSet(_ context: [String: Any]?) -> GlanceSurfaceSet? {
        (context?[WatchSurfacePublisher.contextKey] as? Data).flatMap(GlanceSurfaceCodec.decode)
    }

    // MARK: -

    func testACardIsPushedWithoutReachabilityAndKeepsTheStatus() throws {
        // The fake has no notion of reachability at all: the push never asks.
        let publisher = makePublisher()
        publisher.accept(.init(surface: whereAmI(), asked: false))

        let context = try XCTUnwrap(session.contexts.last)
        XCTAssertEqual(context["status"] as? String, "idle")
        XCTAssertNotNil(context["job"], "the job travels with the card, or the watch would clear it")
        let set = try XCTUnwrap(pushedSet(context))
        XCTAssertEqual(set.current?.id, "w1")
        XCTAssertFalse(set.playsTap, "automatic cards arrive silently")
        XCTAssertFalse(set.usesMetric)
    }

    func testAnAskedCardTaps() throws {
        makePublisher().accept(.init(surface: whereAmI(), asked: true))
        XCTAssertTrue(try XCTUnwrap(pushedSet(session.contexts.last)).playsTap)
    }

    func testNeverSendsNothing() {
        setting = .never
        let publisher = makePublisher()
        publisher.accept(.init(surface: whereAmI(), asked: true))
        XCTAssertTrue(session.contexts.isEmpty)

        // A status push still goes, without a surfaces key.
        publisher.push()
        XCTAssertEqual(session.contexts.count, 1)
        XCTAssertNil(session.contexts.last?[WatchSurfacePublisher.contextKey])
    }

    func testOnlyWhenAskedHoldsBackAnAutomaticCard() {
        setting = .onlyWhenAsked
        let publisher = makePublisher()
        publisher.accept(.init(surface: whereAmI(), asked: false))
        XCTAssertTrue(session.contexts.isEmpty)
        publisher.accept(.init(surface: whereAmI(id: "w2"), asked: true))
        XCTAssertEqual(pushedSet(session.contexts.last)?.current?.id, "w2")
    }

    func testSwitchingToNeverDropsAHeldCardFromTheNextPush() {
        let publisher = makePublisher()
        publisher.accept(.init(surface: whereAmI(), asked: false))
        setting = .never
        publisher.push()
        XCTAssertNil(session.contexts.last?[WatchSurfacePublisher.contextKey])
    }

    func testExpiryClearsTheKey() {
        let publisher = makePublisher()
        publisher.accept(.init(surface: whereAmI(), asked: false))
        XCTAssertNotNil(session.contexts.last?[WatchSurfacePublisher.contextKey])

        clock = clock.addingTimeInterval(5 * 60)   // where-am-I lasts 5 minutes
        publisher.push()
        let context = session.contexts.last
        XCTAssertNil(context?[WatchSurfacePublisher.contextKey], "absent key clears, as job does")
        XCTAssertEqual(context?["status"] as? String, "idle")
    }

    func testLocalOnlyTurnsTheMapOffEvenForACardAcceptedBefore() throws {
        let publisher = makePublisher()
        publisher.accept(.init(surface: whereAmI(), asked: false))
        XCTAssertEqual(try XCTUnwrap(pushedSet(session.contexts.last)).current?.mapAllowed, true)

        medical = .localOnly
        publisher.push()
        XCTAssertEqual(try XCTUnwrap(pushedSet(session.contexts.last)).current?.mapAllowed, false)
    }

    func testNoWatchNoPush() {
        session.isWatchAppInstalled = false
        let publisher = makePublisher()
        publisher.accept(.init(surface: whereAmI(), asked: true))
        publisher.push()
        session.isWatchAppInstalled = true
        session.isPaired = false
        publisher.push()
        session.isPaired = true
        session.isActivated = false
        publisher.push()
        XCTAssertTrue(session.contexts.isEmpty)
    }

    func testNoStatusNoPush() {
        base = nil
        makePublisher().accept(.init(surface: whereAmI(), asked: false))
        XCTAssertTrue(session.contexts.isEmpty, "a context without the status would clear the job")
    }

    func testTheBusFeedsThePublisher() {
        let bus = GlanceSurfaceBus()
        let publisher = makePublisher()
        publisher.observe(bus)
        bus.publish(whereAmI(id: "from-bus"))
        XCTAssertEqual(pushedSet(session.contexts.last)?.current?.id, "from-bus")
    }
}
