import XCTest
@testable import OpenGlasses

/// Plan GU §4 — the "Reply audio" setting and the measured switch time behind Automatic.
final class ReplyRoutePolicyTests: XCTestCase {

    private func decide(_ mode: ReplyAudioMode, measured: Double? = nil, threshold: Double = 0.7,
                        route: MicRoute = .glasses, display: Bool = false, realtime: Bool = false,
                        carPlay: Bool = false) -> ReplyRoute {
        ReplyRoutePolicy.decide(.init(mode: mode, measuredSwitchSeconds: measured, thresholdSeconds: threshold,
                                      conversationRoute: route, displayGlasses: display,
                                      realtime: realtime, carPlay: carPlay))
    }

    func testCallQualityHoldsTheLink() {
        XCTAssertEqual(decide(.callQuality, measured: 0.1), .holdCallLink)
    }

    func testFullQualityReleasesItEveryTime() {
        XCTAssertEqual(decide(.fullQuality), .fullQuality)
        XCTAssertEqual(decide(.fullQuality, measured: 5), .fullQuality)
        XCTAssertEqual(decide(.fullQuality, route: .headset), .fullQuality)
    }

    func testAutomaticFollowsTheMeasuredSwitch() {
        XCTAssertEqual(decide(.automatic, measured: 0.5), .fullQuality)
        XCTAssertEqual(decide(.automatic, measured: 0.7), .holdCallLink, "under the limit, not at it")
        XCTAssertEqual(decide(.automatic, measured: 1.2), .holdCallLink)
        XCTAssertEqual(decide(.automatic, measured: 1.2, threshold: 1.5), .fullQuality)
        XCTAssertEqual(decide(.automatic, measured: nil), .holdCallLink, "unmeasured is not fast")
    }

    func testExclusionsAlwaysHoldTheLink() {
        for mode in ReplyAudioMode.allCases {
            XCTAssertEqual(decide(mode, measured: 0.1, route: .phone), .holdCallLink, "nothing to release")
            XCTAssertEqual(decide(mode, measured: 0.1, display: true), .holdCallLink)
            XCTAssertEqual(decide(mode, measured: 0.1, realtime: true), .holdCallLink)
            XCTAssertEqual(decide(mode, measured: 0.1, carPlay: true), .holdCallLink)
        }
    }

    func testTheThresholdIsClamped() {
        XCTAssertEqual(ReplyRoutePolicy.thresholdRange, 0.3...2.0)
        XCTAssertEqual(ReplyRoutePolicy.defaultThreshold, 0.7)
        XCTAssertEqual(ReplyRoutePolicy.clampedThreshold(0.1), 0.3)
        XCTAssertEqual(ReplyRoutePolicy.clampedThreshold(9), 2.0)
        XCTAssertEqual(ReplyRoutePolicy.clampedThreshold(.nan), 0.7)
        XCTAssertEqual(decide(.automatic, measured: 0.25, threshold: 0.1), .fullQuality, "0.25 < clamped 0.3")
        XCTAssertEqual(decide(.automatic, measured: 0.35, threshold: 0.1), .holdCallLink)
    }

    func testSettingsDefaults() {
        let keys = ["replyAudioMode", "replySwitchTimeLimit"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        XCTAssertEqual(Config.replyAudioMode, .callQuality, "the P1 default")
        XCTAssertEqual(Config.replySwitchTimeLimit, 0.7)
        Config.setReplySwitchTimeLimit(5)
        XCTAssertEqual(Config.replySwitchTimeLimit, 2.0)
        Config.setReplyAudioMode(.automatic)
        XCTAssertEqual(Config.replyAudioMode, .automatic)
    }

    // MARK: - Switch-time ledger

    func testRollingMedianPerDevice() {
        var ledger = SwitchTimeLedger()
        XCTAssertNil(ledger.median(device: "a"))
        ledger.record(0.4, device: "a")
        XCTAssertEqual(ledger.median(device: "a"), 0.4)
        ledger.record(1.0, device: "a")
        XCTAssertEqual(ledger.median(device: "a")!, 0.7, accuracy: 1e-9)
        ledger.record(0.5, device: "a")
        XCTAssertEqual(ledger.median(device: "a"), 0.5, "an outlier does not drag it")
        ledger.record(3.0, device: "b")
        XCTAssertEqual(ledger.median(device: "b"), 3.0, "per device")
    }

    func testTheWindowDropsTheOldest() {
        var ledger = SwitchTimeLedger()
        for _ in 0..<SwitchTimeLedger.window { ledger.record(2.0, device: "a") }
        for _ in 0..<(SwitchTimeLedger.window / 2 + 1) { ledger.record(0.3, device: "a") }
        XCTAssertEqual(ledger.median(device: "a"), 0.3, "recent switches win")
        XCTAssertEqual(ledger.samples["a"]?.count, SwitchTimeLedger.window)
    }

    func testRejectsNonsense() {
        var ledger = SwitchTimeLedger()
        ledger.record(-1, device: "a")
        ledger.record(.infinity, device: "a")
        XCTAssertNil(ledger.median(device: "a"))
    }

    func testRoundTripsAndKeysAreOpaque() throws {
        var ledger = SwitchTimeLedger()
        ledger.record(0.6, device: SwitchTimeLedger.deviceKey(portUID: "Greig's Ray-Ban Meta-uid"))
        let decoded = try JSONDecoder().decode(SwitchTimeLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(decoded, ledger)
        let key = SwitchTimeLedger.deviceKey(portUID: "Greig's Ray-Ban Meta-uid")
        XCTAssertFalse(key.lowercased().contains("greig"), "never the wearer's device name")
        XCTAssertEqual(key, SwitchTimeLedger.deviceKey(portUID: "Greig's Ray-Ban Meta-uid"), "stable")
        XCTAssertNotEqual(key, SwitchTimeLedger.deviceKey(portUID: "other"))
    }
}
