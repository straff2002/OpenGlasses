import MessageUI
import SwiftUI
import UIKit

/// The in-app Mail composer, filled in from a problem report's email draft.
///
/// Deliberately separate from the Field Assist `ReportMailComposer`: that one carries a job record
/// and its attachments, this one carries a masked diagnostics body to a fixed support address.
/// Same shape, same rule — iOS never sends mail on its own, the wearer taps Send.
struct DiagnosticsReportMailComposer: UIViewControllerRepresentable {

    let draft: DiagnosticsEmailDraft
    let onFinish: (DiagnosticsEmailOutcome) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients(draft.recipients)
        controller.setSubject(draft.subject)
        controller.setMessageBody(draft.body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let onFinish: (DiagnosticsEmailOutcome) -> Void

        init(onFinish: @escaping (DiagnosticsEmailOutcome) -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            onFinish(DiagnosticsEmailOutcome.mail(result: result.rawValue, error: error))
        }
    }

    /// The device's own answer, asked when the wearer taps Email Report.
    @MainActor
    static var route: DiagnosticsEmailRoute {
        DiagnosticsEmailRoute.resolve(canSendMail: MFMailComposeViewController.canSendMail())
    }
}

extension DiagnosticsEmailOutcome {
    /// Mail's result code mapped onto what the sheet says. Takes the raw value so a test can
    /// assert the mapping without MessageUI on screen; an error wins over whatever the code says.
    static func mail(result: Int, error: Error?) -> DiagnosticsEmailOutcome {
        if error != nil { return .failed }
        switch MFMailComposeResult(rawValue: result) {
        case .sent: return .sent
        case .saved: return .saved
        case .failed: return .failed
        default: return .cancelled
        }
    }
}

/// The share-sheet fallback's item: the full report body, with the report title offered as the
/// subject so a mail app picked from the sheet opens with the same subject the composer would have.
final class DiagnosticsEmailActivityItem: NSObject, UIActivityItemSource {
    let draft: DiagnosticsEmailDraft

    init(draft: DiagnosticsEmailDraft) {
        self.draft = draft
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        draft.body
    }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        draft.body
    }

    func activityViewController(_ controller: UIActivityViewController,
                                subjectForActivityType type: UIActivity.ActivityType?) -> String {
        draft.subject
    }
}
