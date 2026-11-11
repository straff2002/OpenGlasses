import MessageUI
import SwiftUI
import UIKit

// Plan KT §7.1 — one presenter for any draft. The platform's Mail and Messages composers, filled
// from plain content: Field Assist's job report and parts order (`ReportMailComposer`,
// `ReportMessageComposer`) and a My Day card's draft both go through these. The wearer's thumb on
// the composer's Send is the send; nothing here sends by itself.

/// A file a composer carries.
struct ComposeAttachment: Equatable {
    let data: Data
    let mimeType: String
    let typeIdentifier: String
    let filename: String
}

struct MailComposeContent: Equatable {
    var recipients: [String]
    var subject: String?
    var body: String
    var attachments: [ComposeAttachment] = []
}

struct MessageComposeContent: Equatable {
    var recipients: [String]
    var body: String
    var attachments: [ComposeAttachment] = []
}

/// `MFMailComposeViewController`, reporting its raw `MFMailComposeResult` and any error.
struct MailComposeSheet: UIViewControllerRepresentable {

    let content: MailComposeContent
    let onFinish: (Int, Error?) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients(content.recipients)
        if let subject = content.subject { controller.setSubject(subject) }
        controller.setMessageBody(content.body, isHTML: false)
        for attachment in content.attachments {
            controller.addAttachmentData(attachment.data, mimeType: attachment.mimeType,
                                         fileName: attachment.filename)
        }
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let onFinish: (Int, Error?) -> Void

        init(onFinish: @escaping (Int, Error?) -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            onFinish(result.rawValue, error)
        }
    }
}

/// `MFMessageComposeViewController`, reporting its raw `MessageComposeResult`.
struct MessageComposeSheet: UIViewControllerRepresentable {

    let content: MessageComposeContent
    let onFinish: (Int) -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.recipients = content.recipients
        controller.body = content.body
        for attachment in content.attachments {
            controller.addAttachmentData(attachment.data, typeIdentifier: attachment.typeIdentifier,
                                         filename: attachment.filename)
        }
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        private let onFinish: (Int) -> Void

        init(onFinish: @escaping (Int) -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            onFinish(result.rawValue)
        }
    }
}

/// Presents a card's draft composer. The root hosts it, except while the My Day page is up as a
/// sheet of its own — a sheet cannot be presented from under another — when the page hosts it.
struct DraftComposerHost: ViewModifier {
    @ObservedObject var appState: AppState
    let onPage: Bool

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { appState.draftComposerOnPage == onPage ? appState.draftComposerRequest : nil },
            set: { newValue in
                // A swipe-down is a cancel.
                if newValue == nil, appState.draftComposerOnPage == onPage,
                   let request = appState.draftComposerRequest {
                    appState.finishDraftHandOff(request, result: .cancelled)
                }
            })) { request in
            DraftComposerSheet(request: request) { result in
                appState.finishDraftHandOff(request, result: result)
            }
        }
    }
}

/// A card's draft in whichever composer its route names.
struct DraftComposerSheet: View {
    let request: DraftComposerRequest
    let onFinish: (PreparedCardState.HandOffResult) -> Void

    var body: some View {
        #if DEBUG
        if UITestSupport.isSet(.standInComposer) {
            DraftComposerStandIn(route: request.route, onFinish: onFinish)
        } else {
            composer
        }
        #else
        composer
        #endif
    }

    @ViewBuilder
    private var composer: some View {
        switch request.route {
        case .messagesComposer(let recipients, let body):
            MessageComposeSheet(content: MessageComposeContent(recipients: recipients, body: body)) {
                onFinish(DraftComposerRouter.messageResult($0))
            }
            .ignoresSafeArea()
        case .mailComposer(let recipients, let subject, let body):
            MailComposeSheet(content: MailComposeContent(recipients: recipients, subject: subject, body: body)) {
                onFinish(DraftComposerRouter.mailResult($0, error: $1))
            }
            .ignoresSafeArea()
        case .openURL, .copy:
            // Never presented: those routes open another app or the clipboard directly.
            EmptyView()
        }
    }
}

#if DEBUG
/// UI tests only (`UITestSupport.Flag.standInComposer`): the simulator has no Messages or Mail
/// composer, so a plain sheet stands where it would be. It shows the text it was given and reports
/// what the real composer would — sent or cancelled — and sends nothing.
private struct DraftComposerStandIn: View {
    let route: DraftComposerRoute
    let onFinish: (PreparedCardState.HandOffResult) -> Void

    private var text: String {
        switch route {
        case .messagesComposer(_, let body), .mailComposer(_, _, let body): body
        case .openURL, .copy(_): ""
        }
    }

    var body: some View {
        NavigationStack {
            Text(text)
                .padding()
                .accessibilityIdentifier("draftComposer.body")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { onFinish(.cancelled) }
                            .accessibilityIdentifier("draftComposer.cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") { onFinish(.sent) }
                            .accessibilityIdentifier("draftComposer.send")
                    }
                }
        }
    }
}
#endif
