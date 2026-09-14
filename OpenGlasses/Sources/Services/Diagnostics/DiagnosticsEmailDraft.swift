import Foundation

/// The email a problem report becomes, before anything is handed to Mail or the share sheet.
///
/// A plain value built from an already-redacted `DiagnosticsReport`, so what the wearer read in
/// the review sheet is exactly what the draft carries: the full masked body, not the
/// URL-trimmed one the GitHub link has to settle for. There is no GitHub account on the other
/// end of an email, which is the point of offering it first.
struct DiagnosticsEmailDraft: Equatable {
    let recipients: [String]
    let subject: String
    /// The complete report body — every log line the review sheet showed.
    let body: String

    init(report: DiagnosticsReport, recipient: String = DiagnosticsReportBuilder.supportEmail) {
        self.recipients = [recipient]
        self.subject = report.title
        self.body = report.body
    }
}

/// Where "Email Report" goes on this device.
///
/// A phone with no Mail account (and every simulator) cannot show a mail composer, and a button
/// that does nothing is worse than a detour. So the decision is one pure function: the composer
/// when Mail can send, otherwise the share sheet carrying the same subject and body — the sheet
/// then says where to send it, because the share sheet cannot prefill a recipient.
enum DiagnosticsEmailRoute: Equatable {
    case mailComposer
    case shareSheet

    static func resolve(canSendMail: Bool) -> DiagnosticsEmailRoute {
        canSendMail ? .mailComposer : .shareSheet
    }
}

/// How the Mail composer ended, in the terms the review sheet reports back. Only `sent` means the
/// report left the phone; a draft in the Drafts folder has not reached anybody.
enum DiagnosticsEmailOutcome: Equatable {
    case sent
    case saved
    case cancelled
    case failed
}
