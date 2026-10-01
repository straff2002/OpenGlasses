import XCTest
import AVFoundation
@testable import OpenGlasses

/// Plan GU §3 — the app's own route switches are expected; a switch nobody in the app asked for is
/// still a disruption.
final class SelfRouteChangeFilterTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testOwnSwitchesAreIgnored() {
        for reason in [AVAudioSession.RouteChangeReason.categoryChange, .override, .oldDeviceUnavailable] {
            XCTAssertEqual(SelfRouteChangeFilter.verdict(reason: reason, ownSwitchInFlight: true, bluetoothLost: false),
                           .ignore, "\(reason.rawValue)")
        }
    }

    func testForeignSwitchesStillDisrupt() {
        for reason in [AVAudioSession.RouteChangeReason.categoryChange, .override, .oldDeviceUnavailable,
                       .newDeviceAvailable] {
            XCTAssertEqual(SelfRouteChangeFilter.verdict(reason: reason, ownSwitchInFlight: false, bluetoothLost: false),
                           .handle, "another app or \"Hey Meta\" (\(reason.rawValue))")
        }
    }

    func testANewDeviceIsNeverOurs() {
        XCTAssertEqual(SelfRouteChangeFilter.verdict(reason: .newDeviceAvailable, ownSwitchInFlight: true,
                                                     bluetoothLost: false), .handle)
    }

    func testADeviceThatReallyWentAwayMidSwitchIsStillADisconnect() {
        XCTAssertEqual(SelfRouteChangeFilter.verdict(reason: .oldDeviceUnavailable, ownSwitchInFlight: true,
                                                     bluetoothLost: true), .handle)
    }

    // MARK: - Generation window

    func testASwitchIsOursFromBeginUntilItSettles() {
        var gen = RouteSwitchGeneration()
        XCTAssertFalse(gen.isOwnSwitch(at: t0))
        let g = gen.begin()
        XCTAssertTrue(gen.isOwnSwitch(at: t0))
        XCTAssertTrue(gen.isOwnSwitch(at: t0.addingTimeInterval(30)), "in flight however long it takes")
        gen.end(g, at: t0)
        XCTAssertTrue(gen.isOwnSwitch(at: t0.addingTimeInterval(0.5)), "notifications lag the call")
        XCTAssertFalse(gen.isOwnSwitch(at: t0.addingTimeInterval(RouteSwitchGeneration.settleSeconds + 0.01)))
    }

    func testOverlappingSwitchesStayOursUntilTheLastEnds() {
        var gen = RouteSwitchGeneration()
        let a = gen.begin()
        let b = gen.begin()
        XCTAssertNotEqual(a, b)
        gen.end(a, at: t0)
        XCTAssertTrue(gen.isOwnSwitch(at: t0.addingTimeInterval(5)), "b is still in flight")
        gen.end(b, at: t0.addingTimeInterval(5))
        XCTAssertTrue(gen.isOwnSwitch(at: t0.addingTimeInterval(5.5)))
        XCTAssertFalse(gen.isOwnSwitch(at: t0.addingTimeInterval(7)))
    }

    func testAnEarlierEndNeverShortensALaterSettle() {
        var gen = RouteSwitchGeneration()
        let a = gen.begin()
        let b = gen.begin()
        gen.end(b, at: t0.addingTimeInterval(10))
        gen.end(a, at: t0)
        XCTAssertTrue(gen.isOwnSwitch(at: t0.addingTimeInterval(10.5)))
    }
}
