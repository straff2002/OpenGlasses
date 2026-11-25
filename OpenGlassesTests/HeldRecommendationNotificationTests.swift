import UserNotifications
import XCTest
@testable import OpenGlasses

/// What was held while the wearer was away reaches them as a quiet notification, never speech.
/// Field report (b770): spoken through the phone speaker with the phone locked beside them, the
/// line was heard back by the phone's own mic as a request to run the held Shortcut.
final class HeldRecommendationNotificationTests: XCTestCase {

    func testItIsSilentAndPassive() {
        let content = HeldRecommendationNotification.content(
            body: "While you were away, I held one suggestion: Run the Shortcut “Check Email”.")
        XCTAssertNil(content.sound)
        XCTAssertEqual(content.interruptionLevel, .passive)
        XCTAssertEqual(content.title, "Held while you were away")
        XCTAssertEqual(content.body, "While you were away, I held one suggestion: Run the Shortcut “Check Email”.")
    }

    /// A tap opens the assistant.
    @MainActor
    func testATapOpensTheAssistant() {
        let content = HeldRecommendationNotification.content(body: "x")
        XCTAssertEqual(JobSendNotificationRouter.requestedTab(from: content.userInfo), .voice)
    }

    /// With the app open it is still shown — the wearer may be looking at the app when "back"
    /// fires — and still without a sound.
    func testShownWithoutASoundWhileTheAppIsOpen() {
        XCTAssertEqual(JobSendNotificationRouter.presentation(identifier: HeldRecommendationNotification.identifier),
                       [.banner, .list])
    }

    /// The re-engagement handler posts the notification and never speaks the held line.
    func testReEngagementNeverSpeaksTheHeldLine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("OpenGlasses/Sources/App/OpenGlassesApp.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "presenceMonitor.onReEngage = {"))
        let handler = String(source[start.upperBound...].prefix(600))
        XCTAssertTrue(handler.contains("HeldRecommendationNotification.post"), handler)
        XCTAssertFalse(handler.contains("speak("), handler)
    }
}
