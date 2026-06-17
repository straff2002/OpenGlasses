import XCTest
@testable import OpenGlasses

/// Tests for the pure alternative-trigger gate (Additional Capabilities #5): confidence threshold +
/// debounce window + suppression, with the clock passed in.
final class TriggerGateTests: XCTestCase {

    func testFirstValidEventFires() {
        var gate = TriggerGate(debounceInterval: 2.0, minimumConfidence: 0.6)
        XCTAssertTrue(gate.shouldFire(at: 0, confidence: 1.0, suppressed: false))
        XCTAssertEqual(gate.lastFiredAt, 0)
    }

    func testSuppressedNeverFires() {
        var gate = TriggerGate()
        XCTAssertFalse(gate.shouldFire(at: 0, confidence: 1.0, suppressed: true))
        XCTAssertNil(gate.lastFiredAt)   // a suppressed event must not start the debounce clock
    }

    func testBelowConfidenceThresholdDoesNotFire() {
        var gate = TriggerGate(minimumConfidence: 0.6)
        XCTAssertFalse(gate.shouldFire(at: 0, confidence: 0.59, suppressed: false))
        XCTAssertNil(gate.lastFiredAt)
    }

    func testAtConfidenceThresholdFires() {
        var gate = TriggerGate(minimumConfidence: 0.6)
        XCTAssertTrue(gate.shouldFire(at: 0, confidence: 0.6, suppressed: false))
    }

    func testWithinDebounceWindowDoesNotFire() {
        var gate = TriggerGate(debounceInterval: 2.0)
        XCTAssertTrue(gate.shouldFire(at: 10, suppressed: false))
        XCTAssertFalse(gate.shouldFire(at: 11.9, suppressed: false))  // < 2s later
        XCTAssertEqual(gate.lastFiredAt, 10)                          // unchanged by the rejected event
    }

    func testAfterDebounceWindowFiresAgain() {
        var gate = TriggerGate(debounceInterval: 2.0)
        XCTAssertTrue(gate.shouldFire(at: 10, suppressed: false))
        XCTAssertTrue(gate.shouldFire(at: 12.0, suppressed: false))   // exactly 2s later
        XCTAssertEqual(gate.lastFiredAt, 12.0)
    }

    func testRejectedEventDoesNotAdvanceDebounce() {
        var gate = TriggerGate(debounceInterval: 2.0, minimumConfidence: 0.6)
        XCTAssertFalse(gate.shouldFire(at: 5, confidence: 0.1, suppressed: false))  // too quiet
        XCTAssertTrue(gate.shouldFire(at: 5, confidence: 1.0, suppressed: false))   // still fires
    }

    func testResetClearsDebounce() {
        var gate = TriggerGate(debounceInterval: 2.0)
        XCTAssertTrue(gate.shouldFire(at: 10, suppressed: false))
        gate.reset()
        XCTAssertNil(gate.lastFiredAt)
        XCTAssertTrue(gate.shouldFire(at: 10.5, suppressed: false))  // would've been debounced
    }
}
