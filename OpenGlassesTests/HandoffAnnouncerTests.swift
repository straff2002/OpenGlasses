import XCTest
@testable import OpenGlasses

/// Plan GE P0 — one line out, one line back, nothing on flapping.
@MainActor
final class HandoffAnnouncerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testOnceOutAndOnceBack() {
        var announcer = HandoffAnnouncer()
        XCTAssertEqual(announcer.lineForEnteringPhone(now: at(0), canThinkOnPhone: true, queuedItems: 0),
                       HandoffAnnouncer.lostSignalLine)
        XCTAssertNil(announcer.lineForEnteringPhone(now: at(500), canThinkOnPhone: true, queuedItems: 0),
                     "already told — once per episode")
        XCTAssertEqual(announcer.lineForReturn(now: at(600)), HandoffAnnouncer.backOnlineLine)
        XCTAssertNil(announcer.lineForReturn(now: at(900)), "the wearer already knows")
    }

    func testASecondAnnouncementWithinTwoMinutesIsSuppressedAndOwed() {
        var announcer = HandoffAnnouncer()
        XCTAssertNotNil(announcer.lineForEnteringPhone(now: at(0), canThinkOnPhone: true, queuedItems: 0))
        XCTAssertNil(announcer.lineForReturn(now: at(60)), "inside the two-minute window")
        XCTAssertTrue(announcer.wearerBelievesOffline)
        // A flap back to the phone while the return was held says nothing either.
        XCTAssertNil(announcer.lineForEnteringPhone(now: at(90), canThinkOnPhone: true, queuedItems: 0))
        // Still offline at the quiet moment: nothing owed yet.
        XCTAssertNil(announcer.owedLine(now: at(200), onCloud: false))
        // Back on the cloud once the window has passed: the held return is said.
        XCTAssertEqual(announcer.owedLine(now: at(210), onCloud: true), HandoffAnnouncer.backOnlineLine)
        XCTAssertFalse(announcer.wearerBelievesOffline)
    }

    func testTheSuppressionWindowIsTwoMinutes() {
        XCTAssertEqual(HandoffAnnouncer().suppressionWindow, 120)
        var announcer = HandoffAnnouncer()
        _ = announcer.lineForEnteringPhone(now: at(0), canThinkOnPhone: true, queuedItems: 0)
        XCTAssertNil(announcer.lineForReturn(now: at(119.9)))
        XCTAssertNotNil(announcer.lineForReturn(now: at(120)))
    }

    func testTheSavedWorkSentenceOnlyWithQueuedItems() {
        var empty = HandoffAnnouncer()
        let quiet = empty.lineForEnteringPhone(now: at(0), canThinkOnPhone: true, queuedItems: 0)
        XCTAssertFalse(quiet?.contains("saved") ?? true)

        var queued = HandoffAnnouncer()
        let withWork = queued.lineForEnteringPhone(now: at(0), canThinkOnPhone: true, queuedItems: 3)
        XCTAssertEqual(withWork, HandoffAnnouncer.lostSignalLine + " " + HandoffAnnouncer.workSavedSentence)
    }

    func testSyncLineOnlyWithQueuedItems() {
        XCTAssertNil(HandoffAnnouncer.syncLine(queuedItems: 0))
        XCTAssertEqual(HandoffAnnouncer.syncLine(queuedItems: 1), "Back online. Syncing 1 item.")
        XCTAssertEqual(HandoffAnnouncer.syncLine(queuedItems: 4), "Back online. Syncing 4 items.")
    }

    func testThePlainLineWhenNothingCanThinkOnThePhone() {
        var announcer = HandoffAnnouncer()
        XCTAssertEqual(announcer.lineForEnteringPhone(now: at(0), canThinkOnPhone: false, queuedItems: 0),
                       HandoffAnnouncer.lostSignalPlainLine)
    }

    func testTheSyncLineCountsAsTheReturnAnnouncement() {
        var announcer = HandoffAnnouncer()
        _ = announcer.lineForEnteringPhone(now: at(0), canThinkOnPhone: true, queuedItems: 2)
        announcer.noteSpokenReturn(now: at(300))
        XCTAssertNil(announcer.lineForReturn(now: at(600)), "the sync line already said it")
    }

    func testALiveHandoffIsSaidOnceEvenInsideTheWindow() {
        var announcer = HandoffAnnouncer()
        _ = announcer.lineForEnteringPhone(now: at(0), canThinkOnPhone: true, queuedItems: 0)
        XCTAssertNotNil(announcer.lineForReturn(now: at(130)))
        // Ten seconds after the last line — inside the window — the live session drops for good.
        XCTAssertEqual(announcer.lineForLiveHandoff(now: at(140)), HandoffAnnouncer.liveHandoffLine)
        XCTAssertNil(announcer.lineForLiveHandoff(now: at(150)))
        XCTAssertNil(announcer.lineForEnteringPhone(now: at(500), canThinkOnPhone: true, queuedItems: 0))
    }

    func testCopyNeverNamesThePlanAndSaysAvenkinWhereItNamesTheApp() {
        let lines = [HandoffAnnouncer.lostSignalLine, HandoffAnnouncer.lostSignalPlainLine,
                     HandoffAnnouncer.backOnlineLine, HandoffAnnouncer.workSavedSentence,
                     HandoffAnnouncer.heldFirstLine, HandoffAnnouncer.heldReplacedLine,
                     HandoffAnnouncer.heldExpiredLine, HandoffAnnouncer.heldExpiredNotificationTitle,
                     HandoffAnnouncer.heldExpiredNotificationBody, HandoffAnnouncer.phoneStatusChip,
                     HandoffAnnouncer.liveHandoffLine, OfflineHandoffSettingsRow.title,
                     OfflineHandoffSettingsRow.info]
        for line in lines {
            XCTAssertNil(line.range(of: #"\bPlan [A-Z]{1,2}\b|\bGE\b"#, options: .regularExpression), line)
            XCTAssertFalse(line.contains("OpenGlasses"), line)
        }
        XCTAssertTrue(OfflineHandoffSettingsRow.info.contains("Avenkin"))
    }
}
