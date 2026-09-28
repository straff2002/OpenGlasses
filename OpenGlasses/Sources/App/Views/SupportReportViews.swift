import MessageUI
import SwiftUI
import UIKit

/// The offer after a failed AI turn: one line, Send or dismiss. Drawn over the top of every tab, so
/// the person does not have to go looking for a report page when something has just gone wrong.
struct SupportPromptBanner: View {
    let prompt: SupportPrompt
    let onSend: () -> Void
    let onDismiss: () -> Void
    @Environment(\.appAccent) private var accent

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.bubble")
                .font(.body.weight(.semibold))
                .foregroundStyle(OGTheme.warnLabel)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("That didn't work")
                    .font(.subheadline.weight(.semibold))
                Text(verbatim: "\(prompt.at.formatted(date: .omitted, time: .shortened)) — \(prompt.reason).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Send to support", action: onSend)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .accessibilityHint("Shows everything the report would contain. Nothing is sent until you send it.")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
    }
}

/// The support report, in full, before anything leaves the phone.
///
/// The same rule as the problem report in Diagnostics & Support: the person reads the actual file,
/// sees what was masked, and sends it themselves — by Mail, addressed to support with the file
/// attached, or anywhere else through the share sheet.
struct SupportReportSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent

    @State var request: SupportReportRequest
    @State private var document: JobTranscriptExport.Document?
    @State private var problem: String?
    @State private var showingMail = false
    @State private var shareItem: ShareItem?
    @State private var lease: StagedExportLease?
    @State private var status: Status?

    private enum Status: Equatable {
        case sharedInstead
        case finished(DiagnosticsEmailOutcome)
    }

    /// Characters of the file shown on screen. The whole file is attached either way; a day's
    /// report can run long, and the preview is for reading, not scrolling forever.
    private static let previewLimit = 12_000

    private var isDay: Bool {
        if case .day = request.scope { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            OGScrollPage {
                if let reason = request.reason {
                    OGNotice(text: reason, systemImage: "exclamationmark.triangle")
                }

                if isDay {
                    OGSection(footer: "Chats and questions from this day that weren't part of a job. Turn off to send jobs only.") {
                        Toggle("Include conversations outside jobs", isOn: $request.options.otherConversations)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                }

                if let document {
                    content(document)
                } else if let problem {
                    OGStatusLabel(problem, kind: .error)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .navigationTitle("Send to Support")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingMail) {
                if let document {
                    SupportReportMailComposer(document: document, reason: request.reason,
                                              recipient: appState.supportReportRecipient ?? "") { outcome in
                        showingMail = false
                        status = .finished(outcome)
                    }
                    .ignoresSafeArea()
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: item.items, onComplete: item.onComplete)
            }
        }
        .tint(accent)
        .task(id: request.options) { await build() }
        .onDisappear { releaseLease() }
    }

    @ViewBuilder
    private func content(_ document: JobTranscriptExport.Document) -> some View {
        OGNotice(text: maskingSummary(document), systemImage: "eye.slash")

        OGSection(header: "What's in it") {
            Text(verbatim: summary(document))
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }

        if let recipient = appState.supportReportRecipient {
            emailSection(to: recipient)
        } else {
            // An organisation phone with nowhere to send it: never the developer (see
            // `SupportReportRecipient`). Share still works, so the report is not stuck.
            OGStatusLabel("Your organisation hasn't set a support email. Ask your manager for the address and add it in Settings → Diagnostics & Support, or share the file below.",
                          kind: .warn, systemImage: "envelope.badge")
        }

        OGSection {
            Button {
                share(document)
            } label: {
                OGRow("Share the File…", icon: "square.and.arrow.up", mutedIcon: true,
                      subtitle: "Send it another way — Messages, Files, AirDrop")
            }
            .buttonStyle(.plain)
        }

        OGSection(header: "The file", footer: previewFooter(document)) {
            Text(verbatim: preview(document))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
    }

    private func emailSection(to recipient: String) -> some View {
        VStack(spacing: 8) {
            Button {
                email()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "envelope")
                        .font(.subheadline.weight(.semibold))
                    Text("Email to Support")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(accent, in: Capsule())
            }
            .buttonStyle(.plain)

            Text("Goes to \(recipient) with the file attached. You can add to the email before you send it. Change the address in Settings → Diagnostics & Support.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if let status {
                statusLabel(status)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Building

    private func build() async {
        releaseLease()
        document = nil
        problem = nil
        switch await appState.buildSupportReport(request) {
        case .success(let built): document = built
        case .failure(let failure): problem = failure.message
        }
    }

    // MARK: - Sending

    private func email() {
        guard let document else { return }
        if MFMailComposeViewController.canSendMail() {
            status = nil
            showingMail = true
        } else {
            status = .sharedInstead
            share(document)
        }
    }

    private func share(_ document: JobTranscriptExport.Document) {
        releaseLease()
        let coordinator = StagedExportCoordinator.fieldSession
        guard let made = try? JobTranscriptExporter.lease(for: document, coordinator: coordinator) else {
            problem = JobTranscriptExporter.Failure.writeFailed.message
            return
        }
        lease = made
        coordinator.beginShare(made)
        shareItem = ShareItem(
            items: [ProtectedExportActivityItem(fileURL: made.fileURL, displayName: made.displayName)]
        ) { completed in
            coordinator.finishShare(made, outcome: completed ? .completed : .cancelled)
            lease = nil
        }
    }

    /// A file written for a share that never started must not outlive the sheet.
    private func releaseLease() {
        if let lease {
            StagedExportCoordinator.fieldSession.release(lease)
            self.lease = nil
        }
    }

    // MARK: - Words

    private func summary(_ document: JobTranscriptExport.Document) -> String {
        var parts: [String] = []
        parts.append(document.jobCount == 1 ? "1 job" : "\(document.jobCount) jobs")
        parts.append(document.lineCount == 1 ? "1 line of conversation" : "\(document.lineCount) lines of conversation")
        var turns = document.turnCount == 1 ? "1 AI turn" : "\(document.turnCount) AI turns"
        if document.failedTurnCount > 0 { turns += " (\(document.failedTurnCount) failed)" }
        parts.append(turns)
        return parts.joined(separator: " · ")
            + "\nPlus this phone and the glasses, and the app's own event log."
    }

    private func maskingSummary(_ document: JobTranscriptExport.Document) -> String {
        document.redactionHits.isEmpty
            ? "Nothing in this report looked like a key or token."
            : "Masked before you saw it: \(document.redactionHits.joined(separator: ", "))."
    }

    private func preview(_ document: JobTranscriptExport.Document) -> String {
        guard document.body.count > Self.previewLimit else { return document.body }
        return String(document.body.prefix(Self.previewLimit)) + "\n…"
    }

    private func previewFooter(_ document: JobTranscriptExport.Document) -> LocalizedStringKey {
        document.body.count > Self.previewLimit
            ? "The start of the file. The whole file is attached — open it from the email or share sheet to read the rest."
            : "This is the whole file, exactly as it will be sent."
    }

    @ViewBuilder
    private func statusLabel(_ status: Status) -> some View {
        switch status {
        case .sharedInstead:
            OGStatusLabel("This phone has no Mail account set up, so the file opened in the share sheet. Send it to \(appState.supportReportRecipient ?? "your support address").",
                          kind: .warn, systemImage: "envelope.badge")
        case .finished(.sent):
            OGStatusLabel("Report sent. Thank you.", kind: .ok)
        case .finished(.saved):
            OGStatusLabel("Saved to your Mail drafts. It hasn't been sent yet.", kind: .warn)
        case .finished(.cancelled):
            OGStatusLabel("Not sent.", kind: .warn, systemImage: "xmark.circle")
        case .finished(.failed):
            OGStatusLabel("Mail couldn't send the report. Share the file instead.", kind: .error)
        }
    }
}

/// Mail, addressed to support, with the report attached as a text file and a short body saying
/// what it is. The attachment is handed over as data, so no file is written for this route.
struct SupportReportMailComposer: UIViewControllerRepresentable {
    let document: JobTranscriptExport.Document
    let reason: String?
    let recipient: String
    let onFinish: (DiagnosticsEmailOutcome) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([recipient])
        controller.setSubject(document.title)
        var body = [String]()
        if let reason { body.append(reason) }
        body.append("The support report is attached (\(document.displayName)).")
        body.append("Anything else you noticed:")
        body.append("")
        controller.setMessageBody(body.joined(separator: "\n\n"), isHTML: false)
        controller.addAttachmentData(Data(document.body.utf8), mimeType: "text/plain",
                                     fileName: document.displayName)
        PrivacyLog.transfer(.fieldSessionExport, .shareStarted)
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
}
