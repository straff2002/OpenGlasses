import XCTest
@testable import OpenGlasses

/// Build 799: the glasses refused every whole-page picture and the report said only
/// `unknown(displayError)`, and the band channel "failed 4" with no case. These pin what the report
/// now keeps: the Display's refusal as a closed vocabulary (never the SDK's message as written), a
/// bounded history of failed sends, and the band and wrist channels' failure cases. Every message
/// here is shaped like the SDK's prefixes; none is quoted from a device.
final class DisplayFailureReasonTests: XCTestCase {

    // MARK: - The Display's refusal

    func testAKnownPrefixPicksTheKindAndAKnownCodeIsKept() {
        let reason = DisplayRefusalReason(sdkMessage: "Display request rejected: DISPLAY_ERROR_CODE_RENDER_FAILED")
        XCTAssertEqual(reason.kind, .requestRejected)
        XCTAssertEqual(reason.code, "RENDER_FAILED")
        XCTAssertEqual(reason.token, "requestRejected.RENDER_FAILED")
    }

    func testTheLongerCodeWinsOverTheOneInsideIt() {
        let reason = DisplayRefusalReason(sdkMessage: "Display request rejected: DISPLAY_ERROR_CODE_CAPABILITY_NOT_ACTIVE")
        XCTAssertEqual(reason.code, "CAPABILITY_NOT_ACTIVE")
    }

    func testANumericCodeIsKeptAndNothingElseOfTheTail() {
        let reason = DisplayRefusalReason(sdkMessage: "DisplayChannel: Received error event: code=42 something private")
        XCTAssertEqual(reason.token, "errorEvent.42")
        XCTAssertEqual(DisplayRefusalReason(sdkMessage: "DisplayChannel: DWA error: code=abc").token, "glassesAppError")
        XCTAssertEqual(DisplayRefusalReason(sdkMessage: "DisplayChannel: DWA error: code=12345678").token,
                       "glassesAppError", "a number longer than a code is not kept")
    }

    func testEachKnownPrefix() {
        let cases: [(String, DisplayRefusalReason.Kind)] = [
            ("DisplayChannel: Channel error: x", .channelError),
            ("DisplayChannel: Failed to send DWA request messageID=7", .sendFailed),
            ("Transport send failed for display request", .sendFailed),
            ("Failed to serialize display payload", .serializeFailed),
            ("DisplayChannel: Failed to serialize display request payload", .serializeFailed),
            ("Failed to parse display response", .responseUnreadable),
            ("DisplayChannel: Failed to parse DisplayResponsePayload", .responseUnreadable),
            ("DisplayImageResolver: image header fetch failed: x", .imageFetchFailed),
            ("Display: Failed to start listening on display channel", .listenFailed),
            ("DisplayChannel: recoverable cold-start error 3", .coldStart),
        ]
        for (message, kind) in cases {
            XCTAssertEqual(DisplayRefusalReason(sdkMessage: message).kind, kind, message)
        }
    }

    func testAnUnknownMessageKeepsOnlyItsLength() {
        let reason = DisplayRefusalReason(sdkMessage: "Something new from the glasses about Jane's furnace")
        XCTAssertEqual(reason.kind, .unrecognised)
        XCTAssertEqual(reason, DisplayRefusalReason(kind: .unrecognised, length: 51))
        XCTAssertTrue(reason.token.hasSuffix(".len51"))
        XCTAssertFalse(reason.token.contains("Jane"))
    }

    func testEveryTokenSurvivesThePrivacyFilter() {
        let messages = ["Display request rejected: DISPLAY_ERROR_CODE_CAPABILITY_NOT_ACTIVE",
                        "DisplayChannel: Received error event: code=123456", "anything at all"]
        for message in messages {
            let token = DisplayRefusalReason(sdkMessage: message).token
            XCTAssertEqual(PrivacyToken(token).description, token, "the log would drop \(token)")
        }
    }

    // MARK: - The history of failed sends

    func testTheFailureLogKeepsTheNewestAndCountsEveryOne() {
        var log = HUDSendFailureLog(capacity: 2)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        log.record(.picture, outcome: .retriedWithoutPicture, reason: "refused requestRejected.RENDER_FAILED", at: start)
        log.record(.picture, outcome: .retriedWithoutPicture, reason: "refused requestRejected.RENDER_FAILED",
                   at: start.addingTimeInterval(60))
        log.record(.screen, outcome: .timedOut, reason: "unknown(sendTimedOut)", at: start.addingTimeInterval(120))
        XCTAssertEqual(log.entries.count, 2)
        let lines = log.reportLines(timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(lines[0], "Display send failures since launch: refused requestRejected.RENDER_FAILED 2,"
                       + " unknown(sendTimedOut) 1")
        XCTAssertEqual(lines[1], "Display send failures (last 2, oldest first):")
        XCTAssertEqual(lines[2], "  2027-01-15 08:01:00: picture, refused requestRejected.RENDER_FAILED, retried-without-picture")
        XCTAssertEqual(lines[3], "  2027-01-15 08:02:00: screen, unknown(sendTimedOut), timed-out")
    }

    func testAnEmptyFailureLogSaysSo() {
        XCTAssertEqual(HUDSendFailureLog().reportLines(), ["Display send failures: none since launch"])
    }

    // MARK: - The band and wrist channels

    func testTheBandLineCarriesTheFailureCasesAndTheEnds() {
        var stats = LensPageStats()
        stats.update("metaRayBan") { entry in
            entry.bandFailures = 4
            entry.bandFailureReasons = ["sessionNotStarted": 3, "addFailed": 1]
            entry.bandEnds = ["inputsEnded": 1]
        }
        XCTAssertTrue(LensPageReport.lines(for: stats).contains(
            "    Band: swipes acted on 0 (halves 0, pages 0, text pages 0, pans 0), nothing to do 0,"
                + " dropped in a burst 0, other inputs 0; listening 0, failed 4 (sessionNotStarted 3, addFailed 1),"
                + " ended 1 (inputsEnded 1)"))
    }

    func testTheWristLineCarriesTheFailureCases() {
        var stats = LensPageStats()
        stats.update("metaRayBan") { entry in
            entry.wristFailures = 1
            entry.wristFailureReasons = ["sessionNotStarted": 1]
            entry.wristEnds = 2
        }
        XCTAssertTrue(LensPageReport.lines(for: stats).contains { $0.hasSuffix("failed 1 (sessionNotStarted 1), ended 2") })
    }
}
