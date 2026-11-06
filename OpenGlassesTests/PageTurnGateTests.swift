import XCTest
@testable import OpenGlasses

/// Plan KP P0 — the stale-frame rule for page turns and card actions.
final class PageTurnGateTests: XCTestCase {

    func testATurnIssuedAgainstTheCurrentFrameIsAccepted() {
        XCTAssertTrue(PageTurnGate.accept(turnRevision: 7, currentRevision: 7))
        XCTAssertTrue(PageTurnGate.accept(turnRevision: 0, currentRevision: 0))
        XCTAssertTrue(PageTurnGate.accept(turnRevision: .max, currentRevision: .max))
    }

    func testATurnIssuedBeforeAnotherRenderIsStale() {
        // A notification rendered between "next" and the page render bumped the revision.
        XCTAssertFalse(PageTurnGate.accept(turnRevision: 7, currentRevision: 8))
        XCTAssertFalse(PageTurnGate.accept(turnRevision: 0, currentRevision: 1))
        XCTAssertFalse(PageTurnGate.accept(turnRevision: 3, currentRevision: 1_000))
    }

    func testATurnFromAFutureRevisionIsRejected() {
        // Can't happen in order; if it ever does, never draw it.
        XCTAssertFalse(PageTurnGate.accept(turnRevision: 9, currentRevision: 8))
    }

    func testOnlyTheLatestOfSeveralQueuedTurnsIsDrawn() {
        var current: UInt64 = 10
        let first = current          // "next" pressed
        current += 1                 // that page rendered
        let second = current         // "next" pressed again
        current += 1                 // a notification rendered
        XCTAssertFalse(PageTurnGate.accept(turnRevision: first, currentRevision: current))
        XCTAssertFalse(PageTurnGate.accept(turnRevision: second, currentRevision: current))
        XCTAssertTrue(PageTurnGate.accept(turnRevision: current, currentRevision: current))
    }
}
