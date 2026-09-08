import Foundation

/// One job report, staged and waiting for the operator's thumb (Plan EM §5).
///
/// Staged rather than sent: the tool builds this and publishes it on the session; the app root
/// subscribes and opens the composer, exactly the way a staged figure reaches the phone. Nothing
/// in here has left the device — a request that is never completed is a report that was never sent,
/// and the queue still holds the record.
struct DeliveryRequest: Identifiable, Equatable {

    /// A file that rides along: the work order the customer reads, or the JSON a job system parses.
    struct Attachment: Equatable {
        enum Kind: String, Equatable {
            case pdf
            case json

            var mimeType: String {
                switch self {
                case .pdf: return "application/pdf"
                case .json: return "application/json"
                }
            }

            /// The UTI the Messages composer wants, which is not the MIME type.
            var uti: String {
                switch self {
                case .pdf: return "com.adobe.pdf"
                case .json: return "public.json"
                }
            }
        }

        let url: URL
        let kind: Kind
        /// What the file is called when it arrives — the job reference, not the session's uuid.
        let filename: String

        init(url: URL, kind: Kind, filename: String? = nil) {
            self.url = url
            self.kind = kind
            self.filename = filename ?? url.lastPathComponent
        }

        var data: Data? { try? Data(contentsOf: url) }
    }

    let id: String
    let channel: DeliveryChannel
    let recipients: [String]
    let subject: String
    /// The full record, for a channel with room for it.
    let body: String
    /// Two or three lines, for a channel that has to fit in a message bubble.
    let shortBody: String
    let attachments: [Attachment]
    /// The record itself, so the unattended route can queue exactly what the composer showed.
    let record: WorkRecord
    /// The stock checks this report answers for. They become `sent` when it is sent, and stay
    /// `requested` when it is not.
    let partsRequestIds: [String]

    init(id: String = UUID().uuidString,
         channel: DeliveryChannel,
         recipients: [String],
         subject: String,
         body: String,
         shortBody: String,
         attachments: [Attachment] = [],
         record: WorkRecord,
         partsRequestIds: [String] = []) {
        self.id = id
        self.channel = channel
        self.recipients = recipients
        self.subject = subject
        self.body = body
        self.shortBody = shortBody
        self.attachments = attachments
        self.record = record
        self.partsRequestIds = partsRequestIds
    }

    var sessionId: String { record.sessionId }
    var jobReference: String? { record.jobReference }

    /// Build the request for a decided channel. The three shapes come off one record, so the PDF a
    /// person reads, the JSON a system parses and the sentence in a message bubble cannot disagree.
    static func make(record: WorkRecord, channel: DeliveryChannel, recipients: [String],
                     attachments: [Attachment], partsRequestIds: [String]? = nil) -> DeliveryRequest {
        DeliveryRequest(
            channel: channel,
            recipients: recipients,
            subject: record.reportSubject,
            body: record.summary,
            shortBody: record.shortSummary,
            // A channel with no way to carry a file carries none, whatever it was handed.
            attachments: channel.carriesAttachments ? attachments : [],
            record: record,
            partsRequestIds: partsRequestIds
                ?? record.partsRequests.filter { $0.status == .requested }.map(\.id))
    }

    /// What the technician is told is about to happen, before anybody taps anything.
    var confirmation: String {
        var line = "Job report ready to go by \(channel.spokenName)"
        if !recipients.isEmpty { line += " to \(recipients.joined(separator: ", "))" }
        line += "."
        switch attachments.count {
        case 0:
            line += channel.carriesAttachments
                ? " The summary only — the record has no exported files to attach."
                : " \(channel.label) can't carry a file, so it takes the summary and the job reference; the full record goes by email or to the office."
        case 1: line += " The \(attachments[0].kind.rawValue.uppercased()) is attached."
        default:
            line += " The work order PDF and the JSON record are attached."
        }
        if channel == .endpoint {
            line += " It goes to the office endpoint as soon as there is a connection."
        } else {
            line += " Check it on the phone and tap Send."
        }
        return line
    }
}

/// How a staged delivery ended. iOS never sends anything on its own: every one of these is a
/// person's decision, reported back so the record's own state can follow it.
enum DeliveryOutcome: Equatable {
    case sent
    /// Mail kept it as a draft. Not sent — the record stays pending.
    case saved
    /// Handed to another app or to the queue, which cannot tell us whether it arrived. WhatsApp and
    /// Telegram are opened by URL scheme and report nothing back; a queued endpoint delivery is
    /// confirmed by the queue, not by the composer. Treated as **not sent**, on purpose: a record
    /// nobody can prove left is a record that must stay in the queue.
    case handedOff
    case cancelled
    case failed(String)

    /// Only a confirmed send moves anything. Everything else leaves the record where it was.
    var isSent: Bool { self == .sent }

    /// The word the audit log records.
    var auditLabel: String {
        switch self {
        case .sent: return "sent"
        case .saved: return "saved"
        case .handedOff: return "handed_off"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }
}

extension WorkRecord {

    /// "Job 4471 — Lennox SLP99 Furnace Service" — the subject line, and the name the exported
    /// files take so an inbox does not fill with `work_order.pdf`.
    var reportSubject: String {
        let job = jobReference.flatMap { $0.isEmpty ? nil : $0 }
        return job.map { "Job \($0) — \(vaultName)" } ?? "\(vaultName) — job record \(sessionId.prefix(8))"
    }

    /// A file name safe for a mail attachment: the job reference where there is one, else the
    /// session, and nothing that needs escaping.
    var reportFileStem: String {
        let raw = jobReference.flatMap { $0.isEmpty ? nil : $0 } ?? String(sessionId.prefix(8))
        let cleaned = raw.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        return "job-" + String(cleaned)
    }

    /// The record in the two or three lines a message bubble has room for. Not a summary of the
    /// summary — the counts and the job reference, so the person reading it knows what is coming
    /// and by what name to look for it.
    var shortSummary: String {
        var lines: [String] = [reportSubject + "."]
        if let equipment {
            lines.append("Equipment: \(equipment.model).")
        }
        let done = tasks(status: .done).count
        let open = tasks.filter { $0.status.isOpen }.count
        let refused = notDone.count
        var counts: [String] = []
        counts.append("\(done) task\(done == 1 ? "" : "s") done")
        if open > 0 { counts.append("\(open) still open") }
        if refused > 0 { counts.append("\(refused) not done") }
        lines.append(counts.joined(separator: ", ") + ".")
        if !partsRequests.isEmpty {
            let numbers = partsRequests.map { "\($0.quantity) × \($0.part.number)" }
            lines.append("Parts requested: " + numbers.joined(separator: ", ") + ".")
        }
        lines.append("Time on site: \(Self.minutesPhrase(minutes: billableMinutes)).")
        return lines.joined(separator: "\n")
    }
}

/// What a composer is filled in with, decided without MessageUI so both of its states are provable.
///
/// The device is the only thing that can say whether Messages will carry a file
/// (`MFMessageComposeViewController.canSendAttachments()`), and on a simulator Mail cannot send at
/// all — so "can it?" is an input here, not something this type asks.
struct ReportComposerModel: Equatable {

    let request: DeliveryRequest
    /// Whether this composer can carry files at all, as the device answered it.
    let canSendAttachments: Bool

    init(request: DeliveryRequest, canSendAttachments: Bool = true) {
        self.request = request
        self.canSendAttachments = canSendAttachments
    }

    var recipients: [String] { request.recipients }
    var subject: String { request.subject }

    /// Mail gets the record; Messages gets the short form, because a bubble is not a work order.
    var body: String {
        switch request.channel {
        case .email: return request.body
        case .messages, .whatsapp, .telegram: return request.shortBody
        case .shareSheet, .endpoint: return request.body
        }
    }

    /// The files this composer will actually attach — none when the device says it cannot.
    var attachments: [DeliveryRequest.Attachment] {
        canSendAttachments ? request.attachments : []
    }

    /// A line appended to the body when the record could not ride along, so the reader is not left
    /// wondering where the PDF is. Nil when everything is attached.
    var attachmentNote: String? {
        guard !request.attachments.isEmpty, attachments.isEmpty else { return nil }
        return "The full work record couldn't be attached to this message; it is being sent separately."
    }

    /// Body as the composer is actually filled in, note included.
    var filledBody: String {
        guard let attachmentNote else { return body }
        return body + "\n\n" + attachmentNote
    }
}
