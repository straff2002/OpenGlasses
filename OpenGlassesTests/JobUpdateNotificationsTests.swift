import UserNotifications
import XCTest
@testable import OpenGlasses

/// The notification for an update from the office: which job and what kind, never the office's
/// text; shown while the app is open, which is the only time one arrives; and nothing else's
/// foreground behaviour changed by it.
final class JobUpdateNotificationsTests: XCTestCase {

    func testItSaysTheJobAndTheKindAndNothingElse() {
        XCTAssertEqual(JobUpdateNotifications.title, "Update from the office")
        XCTAssertEqual(JobUpdateNotifications.body(jobLabel: "Job 1007", updateKind: "parts"), "Job 1007: parts update")
        XCTAssertEqual(JobUpdateNotifications.body(jobLabel: "Job 1007", updateKind: "schedule"), "Job 1007: new time")
        XCTAssertEqual(JobUpdateNotifications.body(jobLabel: "Job 1007", updateKind: "note"), "Job 1007: note from the office")
        // A kind a later office defines is an update all the same, and its word is not shown.
        XCTAssertEqual(JobUpdateNotifications.body(jobLabel: "Job 1007", updateKind: "recall-notice"), "Job 1007: update")
        // A job with no number is not given one.
        XCTAssertEqual(JobUpdateNotifications.body(jobLabel: nil, updateKind: "parts"), "One of your jobs: parts update")
        XCTAssertEqual(JobUpdateNotifications.body(jobLabel: "", updateKind: "note"), "One of your jobs: note from the office")
    }

    func testOneNotificationAJob() {
        XCTAssertEqual(JobUpdateNotifications.identifier(jobID: "job-2031"), "field-assist.office-update.job-2031")
        XCTAssertNotEqual(JobUpdateNotifications.identifier(jobID: "job-2031"),
                          JobUpdateNotifications.identifier(jobID: "job-2032"))
        XCTAssertTrue(JobUpdateNotifications.isUpdate(identifier: JobUpdateNotifications.identifier(jobID: "job-2031")))
        XCTAssertFalse(JobUpdateNotifications.isUpdate(identifier: JobSendNotifications.identifier))
    }

    /// With the app open an update is shown; every other notification is presented exactly as
    /// when no delegate answers at all.
    func testOnlyAnUpdateIsShownWhileTheAppIsOpen() {
        XCTAssertEqual(JobSendNotificationRouter.presentation(identifier: JobUpdateNotifications.identifier(jobID: "job-2031")),
                       [.banner, .list, .sound])
        for other in [JobSendNotifications.identifier, "timer-1", "alarm", "geofence.home", ""] {
            XCTAssertEqual(JobSendNotificationRouter.presentation(identifier: other), [], other)
        }
    }
}
