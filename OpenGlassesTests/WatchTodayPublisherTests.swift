import XCTest
@testable import OpenGlasses

/// Plan KS — the `today` value on the phone: held, rebuilt at push time, pushed only on a change,
/// and folded into every application-context push so `today`, `surfaces` and `job` never clear
/// each other.
@MainActor
final class WatchTodayPublisherTests: XCTestCase {

    private final class FakeSession: WatchSessioning {
        var isActivated = true
        var isPaired = true
        var isWatchAppInstalled = true
        var contexts: [[String: Any]] = []
        func updateApplicationContext(_ applicationContext: [String: Any]) throws {
            contexts.append(applicationContext)
        }
    }

    private var enabled = true
    private var medical: MedicalEgressGuard.Mode = .off
    private var clock = WeatherFixtures.now
    private var accessReady = true
    private var changes = 0
    private var refreshes = 0

    override func setUp() {
        super.setUp()
        enabled = true
        medical = .off
        clock = WeatherFixtures.now
        accessReady = true
        changes = 0
        refreshes = 0
    }

    private func makeToday() -> WatchTodayPublisher {
        WatchTodayPublisher(
            environment: .init(enabled: { [unowned self] in self.enabled },
                               medical: { [unowned self] in self.medical },
                               now: { [unowned self] in self.clock },
                               calendar: { WeatherFixtures.utcCalendar },
                               temperatureUnit: { .celsius },
                               attribution: { WatchTodayAttribution(serviceName: "Apple Weather",
                                                                    legalPageURL: "https://example.invalid/legal") },
                               watchAppInstalled: { true },
                               sourceAccessReady: { [unowned self] in self.accessReady }),
            refresh: { [unowned self] in self.refreshes += 1 },
            onChange: { [unowned self] in self.changes += 1 })
    }

    private func gathered(title: String = "Site visit", locked: Bool = false,
                          at date: Date? = nil) -> MyDayGathered {
        let at = date ?? clock
        let event = MyDayCalendarEvent(id: "e1", title: title, startDate: at.addingTimeInterval(1800),
                                       endDate: at.addingTimeInterval(3600), isAllDay: false, location: nil)
        return MyDayGathered(generatedAt: at, locked: locked, calendarIncluded: true,
                             events: locked ? [] : [event], calendarState: locked ? nil : .available(.calendar),
                             weatherIncluded: true,
                             weather: .init(summary: "Mild.", isDecisionRelevant: false,
                                            report: WeatherFixtures.report()),
                             weatherState: .available(.weather))
    }

    /// Lets a refresh task the publisher started run.
    private func settle() async throws { try await Task.sleep(nanoseconds: 20_000_000) }

    private func decoded(_ data: Data?) -> WatchTodayPayload? { data.flatMap(WatchTodayCodec.decode) }

    // MARK: - The value

    func testNothingGatheredIsAbsent() {
        XCTAssertNil(makeToday().contextValue())
    }

    func testAGatheringIsHeldAndAsksForOnePush() {
        let today = makeToday()
        today.accept(gathered())
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(decoded(today.contextValue())?.events.first?.title, "Site visit")

        today.accept(gathered())
        XCTAssertEqual(changes, 1, "the same day again is not a change")
        today.accept(gathered(title: "Boiler service"))
        XCTAssertEqual(changes, 2)
    }

    func testALockedLookKeepsTheGoodOne() {
        let today = makeToday()
        today.accept(gathered())
        clock = clock.addingTimeInterval(600)
        today.accept(gathered(locked: true))
        XCTAssertEqual(decoded(today.contextValue())?.calendarStatus, .shown)
        XCTAssertEqual(changes, 1)
    }

    func testMedicalComplianceTakesTitlesOffAtTheNextBuild() {
        let today = makeToday()
        today.accept(gathered())
        medical = .init(hipaaMode: true, localOnly: false)
        today.valueMayHaveChanged()
        XCTAssertEqual(changes, 2, "turning Medical Compliance on is a change the watch must get")
        let value = decoded(today.contextValue())
        XCTAssertEqual(value?.redacted, true)
        XCTAssertNil(value?.events.first?.title)
    }

    func testTheSettingOffSendsItsOwnState() {
        let today = makeToday()
        today.accept(gathered())
        enabled = false
        today.valueMayHaveChanged()
        let value = decoded(today.contextValue())
        XCTAssertEqual(value?.isSettingOff, true)
        XCTAssertEqual(value?.events, [])
        XCTAssertNil(value?.weather)
    }

    // MARK: - Looking again

    func testRefreshesOnlyWhenDueEnabledAndUnableToAsk() async throws {
        let today = makeToday()
        today.refreshIfDue()
        try await settle()
        XCTAssertEqual(refreshes, 1, "nothing held: due")

        today.accept(gathered())
        today.refreshIfDue()
        try await settle()
        XCTAssertEqual(refreshes, 1, "just gathered: not due")

        clock = clock.addingTimeInterval(WatchTodaySchedule.foregroundInterval)
        accessReady = false
        today.refreshIfDue()
        try await settle()
        XCTAssertEqual(refreshes, 1, "a refresh that could put a permission sheet up waits")

        accessReady = true
        enabled = false
        today.refreshIfDue()
        try await settle()
        XCTAssertEqual(refreshes, 1, "the setting off: nothing is looked up")

        enabled = true
        today.refreshIfDue()
        try await settle()
        XCTAssertEqual(refreshes, 2)
    }

    // MARK: - One dictionary

    func testTheFoldSetsAndRemovesBothKeysAndLeavesTheRest() {
        let base: [String: Any] = ["status": "idle", "job": ["jobNumber": "J-1"],
                                   "surfaces": Data([1]), "today": Data([2])]
        let cleared = WatchApplicationContext.fold(base, surfaces: nil, today: nil)
        XCTAssertNil(cleared["surfaces"], "a stale value in the base is not left behind")
        XCTAssertNil(cleared["today"])
        XCTAssertEqual(cleared["status"] as? String, "idle")
        XCTAssertNotNil(cleared["job"])

        let both = WatchApplicationContext.fold(["status": "idle"], surfaces: Data([3]), today: Data([4]))
        XCTAssertEqual(both["surfaces"] as? Data, Data([3]))
        XCTAssertEqual(both["today"] as? Data, Data([4]))
    }

    func testTodaySurfacesAndJobSurviveEachOthersPushes() throws {
        let session = FakeSession()
        let today = makeToday()
        var base: [String: Any] = ["status": "idle", "job": ["jobNumber": "J-1"]]
        let surfaces = WatchSurfacePublisher(
            session: session,
            environment: .init(setting: { .automatic }, medical: { .off }, usesMetric: { true },
                               sendsLongLists: { false }, now: { [unowned self] in self.clock }),
            todayValue: { today.contextValue() },
            baseContext: { base })

        // Today arrives: the push carries the job too.
        today.accept(gathered())
        surfaces.push()
        var context = try XCTUnwrap(session.contexts.last)
        XCTAssertNotNil(context[WatchTodayWire.contextKey])
        XCTAssertNotNil(context["job"])

        // A map card arrives: today is still there.
        let card = GlanceSurfaceBuilder.whereAmI(
            wearer: WearerFix(coordinate: GlancePoint(latitude: -36.85, longitude: 174.76), fixAt: clock,
                              horizontalAccuracy: 10),
            street: "Queen Street", locality: "Auckland", mapAllowed: true, now: clock, id: "w1")
        surfaces.accept(.init(surface: card, asked: false))
        context = try XCTUnwrap(session.contexts.last)
        XCTAssertNotNil(context[GlanceWire.contextKey])
        XCTAssertNotNil(context[WatchTodayWire.contextKey], "a card push must not clear today")
        XCTAssertNotNil(context["job"])

        // The job closes and the status goes out: today and the card both stay.
        base = ["status": "listening"]
        surfaces.push()
        context = try XCTUnwrap(session.contexts.last)
        XCTAssertNil(context["job"])
        XCTAssertNotNil(context[GlanceWire.contextKey])
        XCTAssertEqual(decoded(context[WatchTodayWire.contextKey] as? Data)?.events.first?.id, "e1")

        // Another status push: today's bytes are exactly what they were.
        let todayBytes = context[WatchTodayWire.contextKey] as? Data
        surfaces.push()
        XCTAssertEqual(session.contexts.last?[WatchTodayWire.contextKey] as? Data, todayBytes)
    }
}
