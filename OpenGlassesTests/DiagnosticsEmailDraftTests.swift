import UIKit
import XCTest
@testable import OpenGlasses

final class DiagnosticsEmailDraftTests: XCTestCase {

    private func snapshot(logTail: [String] = []) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            appVersion: "2026.9",
            buildNumber: "380",
            systemName: "iOS",
            systemVersion: "27.0",
            deviceModel: "iPhone18,1",
            localeIdentifier: "en_NZ",
            glassesConnected: false,
            activeModelName: "Test Model",
            logTail: logTail
        )
    }

    // MARK: - Address

    func testSupportAddressIsDefinedOnce() {
        XCTAssertEqual(DiagnosticsReportBuilder.supportEmail, "g@skunkworks.kiwi")
    }

    // MARK: - Draft

    func testDraftGoesToSupportWithTheReportTitleAndBody() {
        let report = DiagnosticsReportBuilder.build(snapshot(logTail: ["connected", "stream started"]))
        let draft = DiagnosticsEmailDraft(report: report)

        XCTAssertEqual(draft.recipients, ["g@skunkworks.kiwi"])
        XCTAssertEqual(draft.subject, report.title)
        XCTAssertEqual(draft.body, report.body)
        XCTAssertTrue(draft.subject.contains("2026.9 (380)"))
    }

    /// The email is not a link: it carries every log line even when the GitHub URL had to drop some.
    func testDraftCarriesTheFullBodyWhenTheIssueLinkIsTrimmed() {
        let lines = (1...60).map { "event \($0) " + String(repeating: "x", count: 80) }
        let report = DiagnosticsReportBuilder.build(snapshot(logTail: lines), urlLimit: 2_000)
        XCTAssertGreaterThan(report.omittedLogLines, 0, "fixture must force the link to trim")

        let draft = DiagnosticsEmailDraft(report: report)
        XCTAssertEqual(draft.body, report.body)
        XCTAssertTrue(draft.body.contains("event 1 "), "the oldest line must survive into the email")
        XCTAssertTrue(draft.body.contains("event 60 "))
        XCTAssertFalse(draft.body.contains("omitted so this fits in a link"))
    }

    func testDraftBodyIsTheMaskedText() {
        let secret = "sk-proj-AbCdEfGhIjKlMnOp0123456789"
        let report = DiagnosticsReportBuilder.build(snapshot(logTail: ["auth header \(secret)"]))
        let draft = DiagnosticsEmailDraft(report: report)

        XCTAssertFalse(draft.body.contains(secret))
        XCTAssertTrue(draft.body.contains(DiagnosticsRedactor.placeholder))
    }

    func testRecipientCanBeInjected() {
        let report = DiagnosticsReportBuilder.build(snapshot())
        XCTAssertEqual(DiagnosticsEmailDraft(report: report, recipient: "qa@example.com").recipients,
                       ["qa@example.com"])
    }

    // MARK: - Route

    func testMailComposerWhenMailCanSendOtherwiseShareSheet() {
        XCTAssertEqual(DiagnosticsEmailRoute.resolve(canSendMail: true), .mailComposer)
        XCTAssertEqual(DiagnosticsEmailRoute.resolve(canSendMail: false), .shareSheet)
    }

    @MainActor
    func testShareSheetFallbackCarriesTheSameSubjectAndBody() {
        let report = DiagnosticsReportBuilder.build(snapshot(logTail: ["one", "two"]))
        let draft = DiagnosticsEmailDraft(report: report)
        let item = DiagnosticsEmailActivityItem(draft: draft)
        let controller = UIActivityViewController(activityItems: [], applicationActivities: nil)

        XCTAssertEqual(item.activityViewController(controller, subjectForActivityType: .mail), draft.subject)
        XCTAssertEqual(item.activityViewController(controller, itemForActivityType: .mail) as? String, draft.body)
        XCTAssertEqual(item.activityViewControllerPlaceholderItem(controller) as? String, draft.body)
    }

    // MARK: - Outcome

    func testMailResultsMapOntoWhatTheSheetReports() {
        // MFMailComposeResult: cancelled 0, saved 1, sent 2, failed 3.
        XCTAssertEqual(DiagnosticsEmailOutcome.mail(result: 0, error: nil), .cancelled)
        XCTAssertEqual(DiagnosticsEmailOutcome.mail(result: 1, error: nil), .saved)
        XCTAssertEqual(DiagnosticsEmailOutcome.mail(result: 2, error: nil), .sent)
        XCTAssertEqual(DiagnosticsEmailOutcome.mail(result: 3, error: nil), .failed)
        XCTAssertEqual(DiagnosticsEmailOutcome.mail(result: 2, error: URLError(.timedOut)), .failed,
                       "an error is a failure whatever the result code says")
    }
}
