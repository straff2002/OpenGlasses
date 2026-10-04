import AppIntents
import XCTest
@testable import OpenGlasses

/// The "Ask Avenkin" control hands a press to the app as a timestamp in the App Group. A press is
/// acted on once, while fresh, and never later.
final class PendingAskRequestTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "PendingAskRequestTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func store() -> PendingAskRequest {
        PendingAskRequest(defaults: defaults, now: { [unowned self] in self.clock })
    }

    func testNoPressMeansNothingToTake() {
        XCTAssertFalse(store().consume())
    }

    func testAFreshPressIsTakenOnce() {
        store().record()
        clock += 2
        XCTAssertTrue(store().consume(), "a press two seconds ago should start an ask")
        XCTAssertFalse(store().consume(), "the same press must not start a second ask")
        XCTAssertNil(defaults.object(forKey: PendingAskRequest.key))
    }

    func testAPressAtTheLimitIsStillFresh() {
        store().record()
        clock += PendingAskRequest.maximumAge
        XCTAssertTrue(store().consume())
    }

    func testAStalePressIsDroppedAndCleared() {
        store().record()
        clock += PendingAskRequest.maximumAge + 0.5
        XCTAssertFalse(store().consume(), "a press the app never saw in time must not fire later")
        XCTAssertNil(defaults.object(forKey: PendingAskRequest.key), "a stale press is cleared, not kept")
        clock -= PendingAskRequest.maximumAge   // even if the clock steps back, it stays gone
        XCTAssertFalse(store().consume())
    }

    func testAPressFarInTheFutureIsNotTrusted() {
        store().record()
        clock -= 60   // wall clock stepped back after the press
        XCTAssertFalse(store().consume())
        XCTAssertNil(defaults.object(forKey: PendingAskRequest.key))
    }

    func testASecondPressRefreshesTheStamp() {
        store().record()
        clock += PendingAskRequest.maximumAge - 1
        store().record()
        clock += 5
        XCTAssertTrue(store().consume(), "the later press is the one that counts")
        XCTAssertFalse(store().consume())
    }

    func testFreshnessWindow() {
        XCTAssertTrue(PendingAskRequest.isFresh(age: 0))
        XCTAssertTrue(PendingAskRequest.isFresh(age: -PendingAskRequest.futureTolerance))
        XCTAssertFalse(PendingAskRequest.isFresh(age: -PendingAskRequest.futureTolerance - 0.01))
        XCTAssertFalse(PendingAskRequest.isFresh(age: 30))
        XCTAssertLessThanOrEqual(PendingAskRequest.maximumAge, 10, "an old press must expire quickly")
    }

    func testAGarbageValueIsClearedNotActedOn() {
        defaults.set("not a timestamp", forKey: PendingAskRequest.key)
        XCTAssertFalse(store().consume())
    }

    /// The press must bring the app up — the microphone cannot start from the background — and the
    /// control's intent stays out of Shortcuts, where the "Ask Avenkin" App Shortcut already is.
    func testTheControlIntentOpensTheAppAndStaysOutOfShortcuts() {
        XCTAssertTrue(AskAvenkinControlIntent.supportedModes.contains(.foreground(.immediate)))
        XCTAssertFalse(AskAvenkinControlIntent.supportedModes.contains(.background))
        XCTAssertFalse(AskAvenkinControlIntent.isDiscoverable)
        XCTAssertEqual(AskAvenkinControlIntent.title.key, "Ask Avenkin")
    }

    /// The key is shared by two processes; the notification name is what the app listens for.
    func testTheSharedNamesArePinned() {
        XCTAssertEqual(PendingAskRequest.key, "pendingAskRequestedAt")
        XCTAssertEqual(PendingAskRequest.notificationName, "com.openglasses.app.ask-requested")
        XCTAssertNotEqual(PendingAskRequest.notificationName, SharedAppState.listeningChangedNotification)
    }
}
