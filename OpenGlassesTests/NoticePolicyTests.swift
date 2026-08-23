import XCTest
@testable import OpenGlasses

/// The surface built after a device session in which four separate bugs turned out to be the same
/// bug: the app worked out what was wrong and dropped the answer before it reached the screen.
/// These tests pin the ways it could go quiet again.
final class NoticePolicyTests: XCTestCase {

    private let t0: TimeInterval = 1_000_000

    private func notice(_ text: String,
                        _ severity: AppNotice.Severity,
                        _ source: AppNotice.Source,
                        at offset: TimeInterval = 0) -> AppNotice {
        AppNotice(text: text, severity: severity, source: source, postedAt: t0 + offset)
    }

    // MARK: - What gets shown

    func testHighestSeverityWins() {
        let notices = [notice("stream paused", .advisory, .camera),
                       notice("session refused", .error, .liveSession)]
        XCTAssertEqual(NoticePolicy.current(from: notices, now: t0)?.text, "session refused")
    }

    /// A fresh instance of an ongoing condition should replace a stale one, not queue behind it.
    func testTiesGoToTheMostRecent() {
        let notices = [notice("older", .error, .liveSession, at: 0),
                       notice("newer", .error, .camera, at: 5)]
        XCTAssertEqual(NoticePolicy.current(from: notices, now: t0 + 5)?.text, "newer")
    }

    func testNothingToSayShowsNothing() {
        XCTAssertNil(NoticePolicy.current(from: [], now: t0))
    }

    // MARK: - Expiry

    /// An advisory the wearer already acted on must not linger, or the surface stops being read.
    func testAdvisoriesExpire() {
        let advisory = notice("put the glasses on", .advisory, .camera)
        XCTAssertFalse(NoticePolicy.isExpired(advisory, now: t0 + 1))
        XCTAssertTrue(NoticePolicy.isExpired(advisory, now: t0 + NoticePolicy.advisoryLifetime))
        XCTAssertNil(NoticePolicy.current(from: [advisory], now: t0 + NoticePolicy.advisoryLifetime))
    }

    /// Errors do not expire: the thing the wearer asked for did not happen, and a timeout would
    /// hide exactly that — which is the whole failure this surface exists to prevent.
    func testErrorsDoNotExpireOnTheirOwn() {
        let error = notice("session refused", .error, .liveSession)
        XCTAssertFalse(NoticePolicy.isExpired(error, now: t0 + 3600))
        XCTAssertEqual(NoticePolicy.current(from: [error], now: t0 + 3600)?.text, "session refused")
    }

    /// An expired advisory must not mask a live error underneath it.
    func testAnExpiredAdvisoryUncoversAnError() {
        let notices = [notice("paused", .advisory, .camera), notice("refused", .error, .liveSession)]
        XCTAssertEqual(NoticePolicy.current(from: notices, now: t0 + 20)?.text, "refused")
    }

    // MARK: - Merging

    /// One notice per source: a queue is something a chatty subsystem fills, and a camera
    /// reporting every dropped frame would bury a failed session behind a hundred advisories.
    func testASourceReplacesItsOwnNotice() {
        var held = [AppNotice]()
        held = NoticePolicy.merge(held, with: notice("first", .advisory, .camera))
        held = NoticePolicy.merge(held, with: notice("second", .advisory, .camera, at: 1))
        XCTAssertEqual(held.count, 1)
        XCTAssertEqual(held.first?.text, "second")
    }

    func testDifferentSourcesCoexist() {
        var held = [AppNotice]()
        held = NoticePolicy.merge(held, with: notice("camera", .advisory, .camera))
        held = NoticePolicy.merge(held, with: notice("glasses", .warning, .glasses))
        XCTAssertEqual(held.count, 2)
    }

    /// Clearing is per source, so a resumed stream cannot silence an unrelated failure.
    func testClearingOneSourceLeavesTheOthers() {
        var held = [AppNotice]()
        held = NoticePolicy.merge(held, with: notice("camera", .advisory, .camera))
        held = NoticePolicy.merge(held, with: notice("session", .error, .liveSession))
        held = NoticePolicy.clearing(held, source: .camera)
        XCTAssertEqual(held.map(\.source), [.liveSession])
    }

    func testSeverityOrders() {
        XCTAssertLessThan(AppNotice.Severity.advisory, .warning)
        XCTAssertLessThan(AppNotice.Severity.warning, .error)
    }
}
