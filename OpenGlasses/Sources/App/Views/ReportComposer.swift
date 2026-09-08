import MessageUI
import SwiftUI
import UIKit

/// The in-app Mail composer, filled in from a staged job report (Plan EM §5).
///
/// The operator's thumb is the point: iOS will not let an app send mail on the user's behalf, and
/// that is the human-in-the-loop step this feature wants rather than a limitation it works around.
/// Everything the composer shows — subject, body, attachments — comes off the deterministic record.
struct ReportMailComposer: UIViewControllerRepresentable {

    let model: ReportComposerModel
    let onFinish: (DeliveryOutcome) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients(model.recipients)
        controller.setSubject(model.subject)
        controller.setMessageBody(model.filledBody, isHTML: false)
        for attachment in model.attachments {
            guard let data = attachment.data else { continue }
            controller.addAttachmentData(data, mimeType: attachment.kind.mimeType,
                                         fileName: attachment.filename)
        }
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let onFinish: (DeliveryOutcome) -> Void

        init(onFinish: @escaping (DeliveryOutcome) -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            onFinish(ReportComposerOutcome.mail(result: result.rawValue, error: error))
        }
    }
}

/// The in-app Messages composer. The PDF rides along when the device can carry one; when it cannot,
/// the body says so rather than leaving the reader to wonder where the work order went.
struct ReportMessageComposer: UIViewControllerRepresentable {

    let model: ReportComposerModel
    let onFinish: (DeliveryOutcome) -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.recipients = model.recipients
        controller.body = model.filledBody
        for attachment in model.attachments {
            guard let data = attachment.data else { continue }
            controller.addAttachmentData(data, typeIdentifier: attachment.kind.uti,
                                         filename: attachment.filename)
        }
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        private let onFinish: (DeliveryOutcome) -> Void

        init(onFinish: @escaping (DeliveryOutcome) -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            onFinish(ReportComposerOutcome.message(result: result.rawValue))
        }
    }
}

/// Mapping the composers' results onto the outcome the record follows. Pure, and separate from the
/// view controllers, so "cancelled leaves the record pending" is a thing a test can assert without
/// MessageUI on screen.
enum ReportComposerOutcome {

    static func mail(result: Int, error: Error?) -> DeliveryOutcome {
        if let error { return .failed(error.localizedDescription) }
        switch MFMailComposeResult(rawValue: result) {
        case .sent: return .sent
        // A draft in the Drafts folder is not a report anybody has received.
        case .saved: return .saved
        case .failed: return .failed("Mail could not send the report.")
        default: return .cancelled
        }
    }

    static func message(result: Int) -> DeliveryOutcome {
        switch MessageComposeResult(rawValue: result) {
        case .sent: return .sent
        case .failed: return .failed("Messages could not send the report.")
        default: return .cancelled
        }
    }
}

/// What this device can actually do about a chosen channel.
///
/// A simulator has no Mail account (`canSendMail()` is false) and plenty of iPads have no SMS. The
/// honest answer there is the share sheet with both files, not a composer that cannot appear —
/// so the decision is made here, in one pure function, and reported to the technician.
enum ReportComposerAvailability {

    struct Resolution: Equatable {
        let channel: DeliveryChannel
        /// Non-nil when the channel had to change, in the words the technician hears.
        let note: String?
    }

    static func resolve(_ channel: DeliveryChannel, canSendMail: Bool, canSendText: Bool) -> Resolution {
        switch channel {
        case .email where !canSendMail:
            return Resolution(channel: .shareSheet,
                              note: "This device has no Mail account set up, so the report is in the share sheet with both files.")
        case .messages where !canSendText:
            return Resolution(channel: .shareSheet,
                              note: "This device can't send messages, so the report is in the share sheet with both files.")
        default:
            return Resolution(channel: channel, note: nil)
        }
    }

    /// The device's own answers, asked once at presentation time.
    @MainActor
    static func resolveOnDevice(_ channel: DeliveryChannel) -> Resolution {
        resolve(channel,
                canSendMail: MFMailComposeViewController.canSendMail(),
                canSendText: MFMessageComposeViewController.canSendText())
    }

    /// Whether the Messages composer on this device will carry a file at all.
    @MainActor
    static var messagesCanAttach: Bool { MFMessageComposeViewController.canSendAttachments() }
}
