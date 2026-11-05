import XCTest
@testable import OpenGlasses

/// Plan GM P1a — **Go** on the wrist: which card and row it means, and the honest reply kinds
/// (started, refused with a reason, open the phone).
final class WatchStartGuidanceCommandTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let tower = GlancePoint(latitude: -36.8484, longitude: 174.7622)
    private let pharmacy = GlancePoint(latitude: -36.851, longitude: 174.765)

    private func place(id: String = "p") -> GlanceSurface {
        GlanceSurface(id: id, createdAt: now, expiresAt: nil, mapAllowed: true,
                      kind: .place(PlaceCard(name: "Sky Tower", subtitle: nil, coordinate: tower, wearer: nil,
                                             straightLineMeters: 0, bearingDegrees: 0, routeMeters: nil, etas: [])))
    }

    private func places() -> GlanceSurface {
        GlanceSurface(id: "n", createdAt: now, expiresAt: nil, mapAllowed: true,
                      kind: .places(PlacesCard(query: "pharmacy", rows: [
                          PlaceRow(id: "0", name: "Unichem", category: nil, meters: 200, coordinate: pharmacy),
                          PlaceRow(id: "1", name: "Life", category: nil, meters: 400, coordinate: tower),
                      ], wearer: nil)))
    }

    // MARK: - Resolution

    func testAPlaceCardStartsToItsPlace() {
        XCTAssertEqual(WatchStartGuidance.resolve(surfaceId: "p", placeId: nil, live: place()),
                       .start(.init(coordinate: tower, label: "Sky Tower")))
    }

    func testANearbyRowStartsToThatRow() {
        XCTAssertEqual(WatchStartGuidance.resolve(surfaceId: "n", placeId: "1", live: places()),
                       .start(.init(coordinate: tower, label: "Life")))
        XCTAssertEqual(WatchStartGuidance.resolve(surfaceId: "n", placeId: "7", live: places()),
                       .refuse(WatchStartGuidance.goneMessage))
        XCTAssertEqual(WatchStartGuidance.resolve(surfaceId: "n", placeId: nil, live: places()),
                       .refuse(WatchStartGuidance.goneMessage))
    }

    func testACardThatHasGoneIsRefused() {
        XCTAssertEqual(WatchStartGuidance.resolve(surfaceId: "old", placeId: nil, live: place()),
                       .refuse(WatchStartGuidance.goneMessage))
        XCTAssertEqual(WatchStartGuidance.resolve(surfaceId: "p", placeId: nil, live: nil),
                       .refuse(WatchStartGuidance.goneMessage))
        XCTAssertEqual(WatchStartGuidance.resolve(surfaceId: nil, placeId: nil, live: place()),
                       .refuse(WatchStartGuidance.goneMessage))
    }

    func testWhereAmIHasNowhereToGo() {
        let whereAmI = GlanceSurface(id: "w", createdAt: now, expiresAt: nil, mapAllowed: true,
                                     kind: .whereAmI(WhereCard(wearer: WearerFix(coordinate: tower, fixAt: now,
                                                                                 horizontalAccuracy: 5),
                                                               street: nil, locality: nil)))
        XCTAssertEqual(WatchStartGuidance.resolve(surfaceId: "w", placeId: nil, live: whereAmI),
                       .refuse(WatchStartGuidance.nowhereMessage))
    }

    // MARK: - Replies

    func testStartedCarriesTheSpokenConfirmation() {
        let reply = WatchStartGuidance.reply(spoken: "Starting walking directions to Sky Tower — 700 metres, about 9 minutes.",
                                             error: nil, appIsActive: false)
        XCTAssertEqual(reply, .started("Starting walking directions to Sky Tower — 700 metres, about 9 minutes."))
        let dictionary = WatchStartGuidance.dictionary(reply)
        XCTAssertEqual(dictionary["status"] as? String, "started")
        XCTAssertNotNil(dictionary["response"], "the watch reads `response` as success")
        XCTAssertNil(dictionary["error"])
    }

    func testNoFixInTheBackgroundAsksForThePhone() {
        let reply = WatchStartGuidance.reply(spoken: nil, error: NavigationError.noLocation, appIsActive: false)
        XCTAssertEqual(reply, .openPhone)
        XCTAssertEqual(WatchStartGuidance.dictionary(reply)["error"] as? String, WatchStartGuidance.openPhoneMessage)
    }

    func testNoFixWithThePhoneOpenIsAPlainRefusal() {
        XCTAssertEqual(WatchStartGuidance.reply(spoken: nil, error: NavigationError.noLocation, appIsActive: true),
                       .refused(NavigationError.noLocation.localizedDescription))
    }

    func testOtherFailuresSayWhy() {
        let reply = WatchStartGuidance.reply(spoken: nil, error: NavigationError.noRoute, appIsActive: false)
        XCTAssertEqual(reply, .refused("No walking route found."))
        XCTAssertEqual(WatchStartGuidance.dictionary(reply)["error"] as? String, "No walking route found.")
    }

    // MARK: - Protocol

    func testTheCommandIsInTheWatchVocabulary() {
        XCTAssertNotNil(WatchConnectivityManager.commandToken(WatchStartGuidance.command))
        XCTAssertEqual(WatchStartGuidance.command, "startGuidance")
    }
}
