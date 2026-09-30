import CoreLocation
import XCTest
@testable import OpenGlasses

/// Plan GH P0 — "where did I park?" in words and on the HUD.
final class ParkingRecallPhraserTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let here = CLLocationCoordinate2D(latitude: -36.8500, longitude: 174.7600)

    /// A coordinate `meters` from `here` along `bearing` degrees (small-distance approximation).
    private func offset(_ meters: Double, bearing: Double) -> CLLocationCoordinate2D {
        let radians = bearing * .pi / 180
        let dLat = meters * cos(radians) / 111_320
        let dLon = meters * sin(radians) / (111_320 * cos(here.latitude * .pi / 180))
        return CLLocationCoordinate2D(latitude: here.latitude + dLat, longitude: here.longitude + dLon)
    }

    private func spot(_ coordinate: CLLocationCoordinate2D?, level: String? = "2", space: String? = "41",
                      zone: String? = nil, capture: ParkingSpot.Capture = .voice,
                      savedAgo: TimeInterval = 7200, lag: TimeInterval = 0) -> ParkingSpot {
        let saved = now.addingTimeInterval(-savedAgo)
        return ParkingSpot(coordinate: coordinate, horizontalAccuracy: 10,
                           locationAt: coordinate == nil ? nil : saved.addingTimeInterval(-lag),
                           level: level, space: space, zone: zone, savedAt: saved, capture: capture)
    }

    func testDetailPhrases() {
        XCTAssertEqual(ParkingRecallPhraser.detailPhrase(spot(nil, zone: "Green")),
                       "on level 2, space 41, in the green zone")
        XCTAssertEqual(ParkingRecallPhraser.detailPhrase(spot(nil, level: "-1", space: nil, zone: "Row G")),
                       "on level minus 1, in row G")
        XCTAssertEqual(ParkingRecallPhraser.detailPhrase(spot(nil, level: "G", space: nil)), "on the ground floor")
        XCTAssertEqual(ParkingRecallPhraser.detailPhrase(spot(nil, level: "Blue", space: nil)), "on the blue level")
        XCTAssertNil(ParkingRecallPhraser.detailPhrase(spot(nil, level: nil, space: nil)))
    }

    func testSpokenRecallGivesDistanceDirectionAgeAndOffersDirections() {
        let text = ParkingRecallPhraser.spoken(spot(offset(300, bearing: 45)), from: here, now: now, metric: true)
        XCTAssertTrue(text.hasPrefix("You parked on level 2, space 41."), text)
        XCTAssertTrue(text.contains("about 300 metres north-east"), text)
        XCTAssertTrue(text.contains("2 hours ago"), text)
        XCTAssertTrue(text.hasSuffix("Want directions?"), text)
    }

    func testAStaleFixIsCalledOut() {
        let text = ParkingRecallPhraser.spoken(spot(offset(300, bearing: 0), capture: .carPlayDisconnect, lag: 12 * 60),
                                               from: here, now: now, metric: true)
        XCTAssertTrue(text.contains("12 minutes before it was saved"), text)
    }

    func testAMotionSpotIsHedged() {
        let text = ParkingRecallPhraser.spoken(spot(offset(500, bearing: 180), level: nil, space: nil,
                                                    capture: .motion, savedAgo: 600),
                                               from: here, now: now, metric: true)
        XCTAssertTrue(text.hasPrefix("I think I know where you parked."), text)
        XCTAssertTrue(text.contains("south"), text)
        XCTAssertTrue(text.contains("automatically when your drive ended 10 minutes ago"), text)
    }

    func testNoCoordinateMeansNoDirectionsOffer() {
        let text = ParkingRecallPhraser.spoken(spot(nil), from: here, now: now, metric: true)
        XCTAssertTrue(text.contains("don't have a map position"), text)
        XCTAssertFalse(text.contains("Want directions"), text)
    }

    func testRightHereNeedsNoDirections() {
        let text = ParkingRecallPhraser.spoken(spot(offset(8, bearing: 90)), from: here, now: now, metric: false)
        XCTAssertTrue(text.contains("right around here"), text)
        XCTAssertFalse(text.contains("Want directions"), text)
    }

    func testHUDLine() {
        XCTAssertEqual(ParkingRecallPhraser.hudLine(spot(offset(300, bearing: 45)), from: here, metric: true),
                       "Car · L2 · 41 · 300 m NE")
        XCTAssertEqual(ParkingRecallPhraser.hudLine(spot(nil, level: "B2", space: nil), from: here, metric: true),
                       "Car · B2")
    }

    func testAgePhrasesAndCompassPoints() {
        XCTAssertEqual(ParkingRecallPhraser.agePhrase(30), "just now")
        XCTAssertEqual(ParkingRecallPhraser.agePhrase(5 * 60), "5 minutes ago")
        XCTAssertEqual(ParkingRecallPhraser.agePhrase(3600), "an hour ago")
        XCTAssertEqual(ParkingRecallPhraser.agePhrase(26 * 3600), "a day ago")
        XCTAssertEqual(ParkingRecallPhraser.compassPoint(44).short, "NE")
        XCTAssertEqual(ParkingRecallPhraser.compassPoint(350).short, "N")
        XCTAssertEqual(ParkingRecallPhraser.compassPoint(-90).spoken, "west")
    }
}
