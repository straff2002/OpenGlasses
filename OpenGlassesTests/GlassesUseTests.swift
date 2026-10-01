import XCTest
@testable import OpenGlasses

/// The SDK's link × the wearer's Disconnect → whether the app may use the glasses.
///
/// Disconnect cannot drop the link (the SDK has no app-side disconnect), so it is kept as a
/// stand-down beside it. Without this the wearer's Disconnect was undone at once: the pill still
/// said Connected and the wake word came back on the glasses' mic.
final class GlassesUseTests: XCTestCase {

    private func connectedUse() -> GlassesUse {
        var use = GlassesUse()
        use.linkChanged(.connected)
        return use
    }

    func testConnectedLinkIsInUse() {
        let use = connectedUse()
        XCTAssertTrue(use.inUse)
        XCTAssertFalse(use.isPaused)
    }

    func testOnlyAConnectedLinkIsInUse() {
        for phase: GlassesConnectionPhase in [.noGlassesAdded, .addedDisconnected, .connecting] {
            var use = GlassesUse()
            use.linkChanged(phase)
            XCTAssertFalse(use.inUse, "\(phase)")
        }
    }

    func testStandDownWhileConnectedTakesTheGlassesOutOfUse() {
        var use = connectedUse()
        use.standDown()
        XCTAssertFalse(use.inUse)
        XCTAssertTrue(use.stoodDown)
        XCTAssertTrue(use.isPaused, "the link is still up: connected, paused")
        XCTAssertEqual(use.link, .connected, "the link stays the SDK's truth")
    }

    func testStandDownWhileNotConnectedIsANoOp() {
        for phase: GlassesConnectionPhase in [.noGlassesAdded, .addedDisconnected, .connecting] {
            var use = GlassesUse()
            use.linkChanged(phase)
            use.standDown()
            XCTAssertFalse(use.stoodDown, "\(phase): nothing in use to stand down")
            use.linkChanged(.connected)
            XCTAssertTrue(use.inUse, "\(phase): a later connection is live")
        }
    }

    func testExplicitConnectLiftsTheStandDown() {
        var use = connectedUse()
        use.standDown()
        use.resume()
        XCTAssertTrue(use.inUse)
        XCTAssertFalse(use.isPaused)
    }

    func testLinkDroppingWhileStoodDownClearsItAndTheNextConnectionIsLive() {
        var use = connectedUse()
        use.standDown()
        use.linkChanged(.addedDisconnected)   // into the case
        XCTAssertFalse(use.stoodDown)
        XCTAssertFalse(use.inUse)
        use.linkChanged(.connected)           // back on the face
        XCTAssertTrue(use.inUse, "glasses put back on are live without another tap")
    }

    func testAnyExitFromConnectedClearsTheStandDown() {
        for phase: GlassesConnectionPhase in [.noGlassesAdded, .addedDisconnected, .connecting] {
            var use = connectedUse()
            use.standDown()
            use.linkChanged(phase)
            XCTAssertFalse(use.stoodDown, "\(phase)")
        }
    }

    func testRepeatedConnectedReportsKeepTheStandDown() {
        var use = connectedUse()
        use.standDown()
        use.linkChanged(.connected)
        XCTAssertTrue(use.stoodDown, "a link that never left connected has not dropped")
        XCTAssertFalse(use.inUse)
    }

    func testResumeWithoutAStandDownChangesNothing() {
        var use = GlassesUse()
        use.linkChanged(.addedDisconnected)
        let before = use
        use.resume()
        XCTAssertEqual(use, before)
    }
}
