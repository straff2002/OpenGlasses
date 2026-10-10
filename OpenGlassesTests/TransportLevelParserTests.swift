import XCTest
@testable import OpenGlasses

/// Plan HW P1. Three of our documents say the glasses video rides Wi-Fi and field reports say
/// Bluetooth Classic. The SDK has no API to ask, but its device manager logs the link level a
/// device connected with, and the SDK's camera module spells out what the levels are: a stream
/// "requires medium (BTC) or high (WiFi) bandwidth link". So `high` is Wi-Fi, `medium` is
/// Bluetooth Classic, and `low` is Bluetooth Low Energy by elimination.
///
/// The identifiers in these lines are invented. The interpolated parts of the real lines have
/// not been seen on a device, so the parser has to read a level however it is written, and has
/// to answer `unknown`, never a guess, when a line is not one it knows.
final class TransportLevelParserTests: XCTestCase {

    private func connected(_ level: String) -> String {
        "DeviceManager: Device fixture-device-01 connected with \(level) link, requesting firmware version"
    }

    private func level(after lines: [String]) -> GlassesTransportLevel {
        var parser = TransportLevelParser()
        parser.consume(lines)
        return parser.level
    }

    // MARK: - Each level, however it is written

    func testHighIsWiFi() {
        XCTAssertEqual(level(after: [connected("high")]), .wifi)
    }

    func testMediumIsBluetoothClassic() {
        XCTAssertEqual(level(after: [connected("medium")]), .bluetoothClassic)
    }

    func testLowIsBluetoothLowEnergy() {
        XCTAssertEqual(level(after: [connected("low")]), .bluetoothLowEnergy)
    }

    func testALevelIsReadWithALeadingDotOrATypeInFrontOrInCapitals() {
        for written in [".medium", "LinkLevel.medium", "MWDATCore.LinkLevel.medium", "Medium",
                        "MEDIUM", "a medium", "<medium>"] {
            XCTAssertEqual(level(after: [connected(written)]), .bluetoothClassic, written)
        }
    }

    /// The SDK's own log file wraps each message in its own prefix. The line is the same line.
    func testALineIsReadInsideTheLogFilesPrefix() {
        let line = "[ARCLog] [error] [tid:4242] [DeviceManager.connect] [DeviceManager.swift:101] "
            + connected(".high")
        XCTAssertEqual(level(after: [line]), .wifi)
    }

    // MARK: - The fallback line

    func testTheFallbackLineNamesTheLevelFallenBackTo() {
        let line = "DeviceManager: .medium link unavailable (accessory not connected), falling back to .low"
        XCTAssertEqual(level(after: [line]), .bluetoothLowEnergy,
                       "the level after 'falling back to', not the one that was unavailable")
    }

    // MARK: - Order

    func testTheLatestLineWins() {
        XCTAssertEqual(level(after: [connected("high"), connected("medium")]), .bluetoothClassic)
        XCTAssertEqual(level(after: [connected("medium"), connected("high")]), .wifi)
    }

    func testLinesThatSayNothingAboutTheLinkDoNotDisturbTheLevel() {
        XCTAssertEqual(level(after: [
            connected("medium"),
            "DeviceManager: Device fixture-device-01 firmware version received",
            "[ARCLog] [error] [tid:7] [Session.start] [Session.swift:12] session start failed",
        ]), .bluetoothClassic)
    }

    // MARK: - Did it change while the stream ran

    func testASecondLevelDuringTheSessionIsAChange() {
        var parser = TransportLevelParser()
        parser.consume(connected("high"))
        parser.beginSession()
        XCTAssertFalse(parser.changedDuringSession, "the level in force at the start is not a change")

        parser.consume(connected("high"))
        XCTAssertFalse(parser.changedDuringSession, "the same level said again is not a change")

        parser.consume(connected("medium"))
        XCTAssertTrue(parser.changedDuringSession)
        XCTAssertEqual(parser.level, .bluetoothClassic)
    }

    func testWhatWasSaidBeforeTheSessionIsNotAChangeInIt() {
        var parser = TransportLevelParser()
        parser.consume([connected("low"), connected("medium"), connected("high")])
        parser.beginSession()
        XCTAssertEqual(parser.level, .wifi)
        XCTAssertFalse(parser.changedDuringSession)
    }

    func testAFirstLevelInASessionThatBeganWithNoneIsNotAChange() {
        var parser = TransportLevelParser()
        parser.beginSession()
        parser.consume(connected("medium"))
        XCTAssertFalse(parser.changedDuringSession)
        parser.consume(connected("low"))
        XCTAssertTrue(parser.changedDuringSession)
    }

    // MARK: - Unknown, never a guess

    func testEmptyInputIsUnknown() {
        XCTAssertEqual(level(after: []), .unknown)
        XCTAssertEqual(level(after: ["", "   "]), .unknown)
    }

    func testARewordedLineIsUnknown() {
        for line in [
            "DeviceManager: Device fixture-device-01 linked at medium bandwidth",
            "DeviceManager: Device fixture-device-01 is up over the medium transport",
            "DeviceManager: link level medium",
        ] {
            XCTAssertNil(TransportLevelParser.statement(in: line), line)
            XCTAssertEqual(level(after: [line]), .unknown, line)
        }
    }

    /// A connection line with a level word nobody has seen is the newest statement about the
    /// link and was not understood. The older level must not be left standing as if it still
    /// held.
    func testAConnectionLineWithAnUnreadableLevelReplacesTheOlderLevelWithUnknown() {
        XCTAssertEqual(level(after: [connected("medium"), connected("ultra")]), .unknown)
        XCTAssertEqual(level(after: [connected("medium"), connected("<private>")]), .unknown,
                       "a level the system log has redacted is not readable either")
        XCTAssertEqual(level(after: [connected("medium or high")]), .unknown,
                       "two levels where one was expected is not an answer")
    }

    /// The slot may hold the transport's own name instead of a level; the SDK uses those names
    /// everywhere else in its log. They name a radio outright.
    func testTheTransportsOwnNameIsReadToo() {
        XCTAssertEqual(level(after: [connected("BTC")]), .bluetoothClassic)
        XCTAssertEqual(level(after: [connected("WiFi")]), .wifi)
        XCTAssertEqual(level(after: [connected("Wi-Fi")]), .wifi)
        XCTAssertEqual(level(after: [connected("BLE")]), .bluetoothLowEnergy)
        XCTAssertEqual(level(after: [connected("medium (BTC)")]), .bluetoothClassic,
                       "a level and its own transport are one link said twice")
        XCTAssertEqual(level(after: [connected("medium (WiFi)")]), .unknown,
                       "a level and a different transport is not an answer")
        XCTAssertEqual(level(after: [connected("Bluetooth")]), .unknown,
                       "plain Bluetooth does not say which of the two")
    }

    func testALevelWordInsideALongerWordIsNotALevel() {
        XCTAssertEqual(level(after: [connected("lowest")]), .unknown)
        XCTAssertEqual(level(after: [connected("highlighted")]), .unknown)
        XCTAssertEqual(level(after: [connected("medium_v2")]), .unknown)
    }

    /// The file on the one phone looked at is full of these and has no connection line at all.
    /// A transport's errors say which radio failed, not which one is carrying the video.
    func testTransportErrorLinesAreUnknown() {
        let lines = [
            "[ARCLog] [error] [tid:11] [BTCTransport.send] [BTCTransport.swift:88] Bluetooth Classic write failed: accessory disconnected",
            "[ARCLog] [error] [tid:11] [BTCTransport.close] [BTCTransport.swift:140] accessory disconnected with medium link still open",
            "[ARCLog] [error] [tid:12] [WiFiTransport.open] [WiFiTransport.swift:52] high bandwidth link not available",
            "[ARCLog] [error] [tid:12] [BLETransport.read] [BLETransport.swift:31] low energy read timed out",
        ]
        for line in lines {
            XCTAssertNil(TransportLevelParser.statement(in: line), line)
        }
        XCTAssertEqual(level(after: lines), .unknown)
    }

    func testNeitherLevelAvailableNamesNoLinkInUse() {
        let line = "DeviceManager: Neither .medium nor .low link levels are available. Missing requirements: accessory protocol"
        XCTAssertNil(TransportLevelParser.statement(in: line))
        XCTAssertEqual(level(after: [line]), .unknown)
    }
}
