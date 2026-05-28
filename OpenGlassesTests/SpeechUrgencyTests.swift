import XCTest
@testable import OpenGlasses

/// Tests the A2 urgency mapping (rate multiplier + spoken prefix), adapted from neurobridge.
@MainActor
final class SpeechUrgencyTests: XCTestCase {
    typealias Urgency = TextToSpeechService.SpeechUrgency

    func testRateMultipliers() {
        XCTAssertEqual(Urgency.low.rateMultiplier, 1.0, accuracy: 0.0001)
        XCTAssertEqual(Urgency.medium.rateMultiplier, 1.15, accuracy: 0.0001)
        XCTAssertEqual(Urgency.high.rateMultiplier, 1.3, accuracy: 0.0001)
    }

    func testPrefixes() {
        XCTAssertEqual(Urgency.low.prefix, "")
        XCTAssertEqual(Urgency.medium.prefix, "")
        XCTAssertEqual(Urgency.high.prefix, "Important: ")
    }

    func testHigherUrgencySpeaksFaster() {
        XCTAssertGreaterThan(Urgency.high.rateMultiplier, Urgency.medium.rateMultiplier)
        XCTAssertGreaterThan(Urgency.medium.rateMultiplier, Urgency.low.rateMultiplier)
    }
}
