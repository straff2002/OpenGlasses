import Foundation

/// Who a job report is for (Plan HD).
///
/// Two audiences, because the question the transcript asks has two answers: the technician's own
/// office (or the organisation's systems), which may read what was said on site, and everybody
/// else — the customer, or an address nobody set up — who gets the work and not the conversation.
enum ReportAudience: String, Codable, Equatable, Sendable {
    case office
    case customer
}

/// Whether a job report carries what was said on the job, and in which file (Plan HD).
///
/// The work-order PDF never does — it may become an invoice, so it is the customer's document
/// whoever it is sent to. What this type decides is the rest: whether the JSON record keeps its
/// `transcript`, whether the separate transcript PDF may be (or must be) attached, and what the
/// send sheet says about both.
///
/// **Deny by default.** The audience is decided from configuration, never from the content: a
/// report is the office's only when every address it is going to is one the device or the
/// organisation set up for job reports, or it goes to the organisation's endpoint. One unknown
/// address, an empty list, or the share sheet — whose destination the app cannot see — makes it a
/// customer report, unless the technician says otherwise and the organisation lets them.
///
/// Pure: every input is a value, so every row of the plan's table is a test.
enum ReportTranscriptPolicy {

    /// What an organisation profile says about transcripts going to the office.
    /// Absent means the technician decides.
    enum InternalRule: String, Equatable, Sendable, CaseIterable {
        /// The JSON carries it and the transcript PDF is always attached.
        case always
        /// Neither the JSON nor a PDF carries it, even to the office.
        case never
    }

    struct Organisation: Equatable, Sendable {
        var internalRule: InternalRule?
        /// Only configured office destinations count as internal: the technician's "this is going
        /// to my office" is withdrawn, so a transcript can never leave for an address the
        /// organisation did not set up.
        var forbidsCustomerTranscript: Bool

        init(internalRule: InternalRule? = nil, forbidsCustomerTranscript: Bool = false) {
            self.internalRule = internalRule
            self.forbidsCustomerTranscript = forbidsCustomerTranscript
        }
    }

    /// What the device and the organisation have set up.
    struct Context: Equatable, Sendable {
        /// Every address configured for job reports: the device's Job reports defaults and the
        /// organisation profile's report recipients. Email addresses and phone numbers together.
        var officeAddresses: [String]
        var organisation: Organisation

        init(officeAddresses: [String] = [], organisation: Organisation = Organisation()) {
            self.officeAddresses = officeAddresses
            self.organisation = organisation
        }
    }

    /// What the technician chose on the send sheet. The voice and car paths have no sheet and use
    /// `standard`, which is what an untouched sheet means.
    struct Choice: Equatable, Sendable {
        /// "This is going to my office" — the opt-in for a destination the app cannot classify.
        var markedAsOffice: Bool
        /// "Include transcript (internal)".
        var attachTranscript: Bool

        init(markedAsOffice: Bool = false, attachTranscript: Bool = false) {
            self.markedAsOffice = markedAsOffice
            self.attachTranscript = attachTranscript
        }

        static let standard = Choice()
    }

    /// Why the audience is what it is.
    enum AudienceSource: String, Equatable, Sendable {
        /// The organisation's endpoint — its ops platform.
        case endpoint
        /// Every recipient is a configured office address.
        case configuredAddresses = "configured_addresses"
        /// The technician said it is going to their office.
        case markedByTechnician = "marked_by_technician"
        /// At least one recipient is not a configured office address.
        case unknownAddress = "unknown_address"
        /// Nobody to send it to yet.
        case noRecipient = "no_recipient"
        /// The share sheet, whose destination the app cannot see.
        case shareSheet = "share_sheet"
    }

    /// Why the JSON record carries no transcript. The raw value is what the record says.
    enum OmissionReason: String, Codable, Equatable, Sendable {
        case customerDestination = "customer_destination"
        case organisationPolicy = "organisation_policy"
    }

    /// "Include transcript (internal)", as the send sheet shows it.
    enum ToggleState: Equatable, Sendable {
        /// The technician decides; `on` is what they chose (off unless they turned it on).
        case available(on: Bool)
        case lockedOn(reason: String)
        case lockedOff(reason: String)
        /// Shown, off and disabled — a customer report.
        case unavailable(reason: String)
        /// Not shown — the channel carries no file at all.
        case hidden(reason: String)

        var isOn: Bool {
            switch self {
            case .available(let on): return on
            case .lockedOn: return true
            case .lockedOff, .unavailable, .hidden: return false
            }
        }

        var isEditable: Bool {
            if case .available = self { return true }
            return false
        }

        var isShown: Bool {
            if case .hidden = self { return false }
            return true
        }

        /// The sentence under the toggle.
        var note: String {
            switch self {
            case .available(let on):
                return on
                    ? ReportTranscriptPolicy.attachedNote
                    : ReportTranscriptPolicy.availableNote
            case .lockedOn(let reason), .lockedOff(let reason), .unavailable(let reason),
                 .hidden(let reason):
                return reason
            }
        }
    }

    /// The whole decision for one report.
    struct Decision: Equatable, Sendable {
        let audience: ReportAudience
        let source: AudienceSource
        /// Whether the JSON record keeps its `transcript` (and the assistant's words in its
        /// citations).
        let jsonIncludesTranscript: Bool
        /// Why it does not, when it does not.
        let omittedReason: OmissionReason?
        let transcriptPDF: ToggleState
        /// Whether the sheet offers "This is going to my office".
        let offersOfficeOptIn: Bool
        /// Whether the organisation withdrew that opt-in for a destination that would have had it.
        let officeOptInWithdrawn: Bool
        /// What the technician chose, kept so a rebuild (the device fallback) can carry it over.
        let choice: Choice

        var attachesTranscriptPDF: Bool { transcriptPDF.isOn }

        /// Whether this report carries any of the conversation, in either file.
        var carriesTranscript: Bool { jsonIncludesTranscript || attachesTranscriptPDF }

        /// One line naming who the report is for, and why the app thinks so.
        var audienceLine: String {
            switch source {
            case .endpoint: return "Your organisation's office system — internal."
            case .configuredAddresses: return "Your office — every address is set up for job reports."
            case .markedByTechnician: return "Your office — you said so below."
            case .unknownAddress: return "A customer — at least one address isn't set up as your office."
            case .noRecipient: return "Nobody is chosen yet, so it's treated as going to a customer."
            case .shareSheet: return "You choose where in the share sheet, so it's treated as going to a customer."
            }
        }

        /// The footer under the office opt-in, or the reason it is not there. Nil when the report
        /// is the office's by configuration, or carries no file at all.
        var officeOptInFooter: String? {
            if officeOptInWithdrawn {
                return "Your organisation sends transcripts only to the office addresses it set up."
            }
            guard offersOfficeOptIn else { return nil }
            return "A report to a customer carries no transcript. Turn this on only if it's going to your own office."
        }

        /// What the two report files carry, in one sentence. Nil when the channel carries no file.
        var dataFileLine: String? {
            guard transcriptPDF.isShown else { return nil }
            return jsonIncludesTranscript
                ? "The work order never includes what was said. The data file (JSON) does, for your office."
                : "Neither the work order nor the data file includes what was said."
        }

        /// What the audit line records: who it was for, and which files carried the transcript.
        var auditTranscript: [String] {
            var files: [String] = []
            if jsonIncludesTranscript, transcriptPDF.isShown { files.append("json") }
            if attachesTranscriptPDF { files.append("pdf") }
            return files
        }
    }

    // MARK: - Copy

    static let availableNote = "A separate PDF of who said what and when — the phone's speech-to-text, not checked by anyone. For your office, never the customer."
    static let attachedNote = "The transcript PDF goes with this report. Anyone you add in the composer receives it too."
    static let alwaysReason = "Your organisation attaches the transcript to every report to the office."
    static let neverReason = "Your organisation keeps transcripts out of job reports."
    static let customerReason = "Only for reports to your office. This one is for a customer, so no transcript goes with it."

    static func noFilesReason(_ channel: DeliveryChannel) -> String {
        switch channel {
        case .endpoint: return "The office system takes the job record, not files."
        case .messages: return "This phone can't attach a file to a message, so only the summary goes."
        default: return "\(channel.label) can't carry a file, so only the summary goes."
        }
    }

    // MARK: - The decision

    /// Who a destination is, before the technician says anything.
    static func audience(channel: DeliveryChannel, recipients: [String],
                         officeAddresses: [String]) -> (ReportAudience, AudienceSource) {
        switch channel {
        case .endpoint:
            return (.office, .endpoint)
        case .shareSheet:
            return (.customer, .shareSheet)
        case .email, .messages, .whatsapp, .telegram:
            let named = recipients.map(normalise).filter { !$0.isEmpty }
            guard !named.isEmpty else { return (.customer, .noRecipient) }
            let office = Set(officeAddresses.map(normalise).filter { !$0.isEmpty })
            return named.allSatisfy(office.contains)
                ? (.office, .configuredAddresses)
                : (.customer, .unknownAddress)
        }
    }

    /// The decision for one report.
    ///
    /// - Parameter carriesFiles: whether this channel, on this device, carries a file at all —
    ///   `AttachmentBudget.standard(for:canSendAttachments:).carriesFiles`.
    static func decide(channel: DeliveryChannel, recipients: [String], carriesFiles: Bool,
                       context: Context, choice: Choice = .standard) -> Decision {
        let organisation = context.organisation
        let derived = audience(channel: channel, recipients: recipients,
                               officeAddresses: context.officeAddresses)
        let wouldOffer = derived.0 == .customer && carriesFiles
        let offers = wouldOffer && !organisation.forbidsCustomerTranscript
        var (who, source) = derived
        if offers, choice.markedAsOffice {
            who = .office
            source = .markedByTechnician
        }

        let rule = organisation.internalRule
        let json = who == .office && rule != .never
        let omitted: OmissionReason?
        if who == .customer {
            omitted = .customerDestination
        } else if rule == .never {
            omitted = .organisationPolicy
        } else {
            omitted = nil
        }

        let pdf: ToggleState
        if !carriesFiles {
            pdf = .hidden(reason: noFilesReason(channel))
        } else if who == .customer {
            pdf = .unavailable(reason: customerReason)
        } else {
            switch rule {
            case .always: pdf = .lockedOn(reason: alwaysReason)
            case .never: pdf = .lockedOff(reason: neverReason)
            case nil: pdf = .available(on: choice.attachTranscript)
            }
        }

        return Decision(audience: who, source: source, jsonIncludesTranscript: json,
                        omittedReason: omitted, transcriptPDF: pdf, offersOfficeOptIn: offers,
                        officeOptInWithdrawn: wouldOffer && organisation.forbidsCustomerTranscript,
                        choice: choice)
    }

    /// An export taken for the record rather than for a send — the field-session tool, or the
    /// records a phone owes its organisation on leaving. The office audience: the JSON keeps the
    /// transcript unless the organisation says `never`, and no transcript PDF is made.
    static func archive(context: Context) -> Decision {
        let never = context.organisation.internalRule == .never
        return Decision(audience: .office, source: .configuredAddresses,
                        jsonIncludesTranscript: !never,
                        omittedReason: never ? .organisationPolicy : nil,
                        transcriptPDF: never ? .lockedOff(reason: neverReason)
                                             : .available(on: false),
                        offersOfficeOptIn: false, officeOptInWithdrawn: false,
                        choice: .standard)
    }

    /// An address as configuration compares it: email case-insensitively, a phone number by its
    /// digits, so "+64 21 000 000" and "+6421000000" are the same office.
    static func normalise(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.contains("@") else { return trimmed }
        let phoneCharacters = CharacterSet(charactersIn: "+0123456789 -().")
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy(phoneCharacters.contains),
              trimmed.contains(where: \.isNumber) else { return trimmed }
        return trimmed.filter(\.isNumber)
    }
}

// MARK: - Reading the configuration

extension ReportTranscriptPolicy.Context {
    /// What this device and its organisation profile have set up, read through `Config` so the
    /// profile's clamp applies.
    static func current(settings: DeliverySettings = Config.deliverySettings) -> Self {
        Self(officeAddresses: settings.emailRecipients + settings.messageRecipients
                + Config.organizationReportRecipients,
             organisation: .init(internalRule: Config.organizationReportTranscriptInternal,
                                 forbidsCustomerTranscript: Config.organizationForbidsCustomerTranscript))
    }
}
