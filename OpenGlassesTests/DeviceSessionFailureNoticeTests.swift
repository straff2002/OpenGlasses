import XCTest
@testable import OpenGlasses

/// Plan LT §7 — the "session ended by device" notice also points at an out-of-date glasses
/// install, which shows as a session that ends just after it starts.
final class DeviceSessionFailureNoticeTests: XCTestCase {

    #if !AVENKIN_PHONE_ONLY
    func testSessionEndedMentionsAGlassesUpdate() {
        let notice = DeviceSessionFailureReason.sessionEndedByDevice.notice
        XCTAssertTrue(notice.contains("If it ends just after it starts, open Meta AI and check for a glasses update."),
                      notice)
        XCTAssertTrue(notice.contains("broadcast"), "the broadcast advice stays")
        XCTAssertTrue(notice.contains("case"), "the case advice stays")
    }
    #endif

    /// Spoken as well as shown, so it must pass the spoken-error gate (200 characters).
    func testEveryNoticeStillPassesTheSpokenGate() {
        for reason in [DeviceSessionFailureReason.deviceUnavailable, .sessionEndedByDevice, .developerAppUnavailable] {
            XCTAssertTrue(SpokenErrorPolicy.looksHuman(reason.notice), reason.notice)
            XCTAssertLessThanOrEqual(reason.notice.count, 200)
        }
    }
}
