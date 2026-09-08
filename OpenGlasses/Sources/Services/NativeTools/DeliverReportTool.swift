import Foundation

/// Sends the job report — or rather, gets it ready and puts the operator's thumb on Send.
///
/// The tool resolves the channel and who it goes to, builds the report in its three shapes off one
/// record, and **stages** it on the session. The app root opens the composer from there, the same
/// way a staged figure reaches the phone. Nothing here presents anything and nothing here sends
/// anything: iOS requires a person to tap Send, and that requirement is the human-in-the-loop step
/// rather than an obstacle to route around.
@MainActor
final class DeliverReportTool: NativeTool {
    let name = "deliver_report"
    let description = """
    Send the job report for the active Field Assist session — "send the job report to base", \
    "email this to the office", "message the job to Dave", "share the report". Pass 'channel' \
    (email, messages, whatsapp, telegram, share, endpoint) when the technician names one; leave it \
    out to use the organisation's default. Pass 'to' with a contact name, email address or phone \
    number when they name somebody; leave it out to use the configured recipients. The report is \
    the deterministic work record — the same one 'read back the job' speaks — with the work order \
    PDF and the JSON record attached on channels that can carry a file; WhatsApp and Telegram get \
    the short summary and the job reference. The composer opens on the technician's phone with \
    everything filled in and **they** tap Send; nothing leaves the device until they do. Parts \
    requests included in the report are marked sent once it goes. If the channel is not allowed \
    for this job, the tool says so and names the ones that are. Requires an active session.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "channel": [
                "type": "string",
                "enum": ["email", "messages", "whatsapp", "telegram", "share", "endpoint"],
                "description": "How to send it. Omit to use the organisation's default channel."
            ],
            "to": [
                "type": "string",
                "description": "Who to send it to — a contact name, an email address, or a phone number. Omit to use the configured recipients."
            ]
        ],
        "required": [] as [String]
    ]

    /// Session to stage on; nil means the shared service. Injectable for tests.
    private let injectedSession: FieldSessionService?
    /// The delivery rules in force. Injectable so a test does not depend on this device's settings.
    private let settings: () -> DeliverySettings
    /// Contact-name → phone number resolution. Injected so a headless test never touches Contacts.
    private let resolveContact: (String) -> [String]
    /// Contact-name → email resolution. Injected for the same reason.
    private let resolveEmail: (String) -> [ContactLookupHelper.ResolvedEmail]

    init(sessionService: FieldSessionService? = nil,
         settings: @escaping () -> DeliverySettings = { DeliverySettings.load() },
         resolveContact: @escaping (String) -> [String] = { name in
             ContactLookupHelper.resolve(name: name).map(\.phoneNumber)
         },
         resolveEmail: @escaping (String) -> [ContactLookupHelper.ResolvedEmail] = { name in
             ContactLookupHelper.resolveEmails(name: name)
         }) {
        self.injectedSession = sessionService
        self.settings = settings
        self.resolveContact = resolveContact
        self.resolveEmail = resolveEmail
    }

    private var session: FieldSessionService { injectedSession ?? .shared }

    func execute(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        guard let record = session.workRecord() else {
            return "No active Field Assist session. Start a session — the report is the record of one visit."
        }

        let policy = DeliveryPolicy(settings: settings())
        let requested = (args["channel"] as? String).flatMap { DeliveryChannel.named($0) }
        if let raw = args["channel"] as? String, requested == nil,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "I don't know a channel called '\(raw)'. \(policy.allowedSentence())"
        }
        guard let channel = requested ?? policy.defaultChannel else {
            return "No channel is allowed for job reports on this device. "
                + "Set one up in Settings → Field Assist → Job reports."
        }

        switch resolve(spoken: args["to"] as? String, for: channel) {
        case .refused(let message): return message
        case .resolved(let named):
            switch policy.decide(channel: channel, spoken: named) {
            case .refused(let reason):
                return reason
            case .allowed(let recipients):
                let request = DeliveryRequest.make(
                    record: record, channel: channel, recipients: recipients,
                    attachments: session.reportAttachments())
                session.stageDelivery(request)
                return request.confirmation
            }
        }
    }

    /// What the technician said turned into an address this channel can use.
    ///
    /// A name becomes a number — or an address — through the contact lookup the messaging tools
    /// already use. Either way the tool never invents a recipient: a name Contacts does not know,
    /// or one that fits two people, gets a question rather than a guess, because the wrong inbox is
    /// the one mistake in this whole flow nobody would notice until the wrong person had the
    /// customer's job record.
    private func resolve(spoken raw: String?, for channel: DeliveryChannel) -> RecipientResolution {
        let wanted = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return .resolved([]) }

        switch channel {
        case .shareSheet, .endpoint:
            // Neither takes a recipient; naming one is not an error, it is simply not used.
            return .resolved([])
        case .email:
            if wanted.contains("@") { return .resolved([wanted]) }
            switch ContactLookupHelper.pickEmail(from: resolveEmail(wanted)) {
            case .one(let match):
                return .resolved([match.address])
            case .none:
                return .refused("No contact matching '\(wanted)' has an email address I can use. "
                                + "Say the address, or set the office address in Settings → Field Assist → Job reports.")
            case .ambiguous(let names):
                return .refused("'\(wanted)' could be \(Self.orList(names)). Say which one, or say the address.")
            }
        case .messages, .whatsapp, .telegram:
            if ContactLookupHelper.isPhoneNumber(wanted) { return .resolved([wanted]) }
            let matches = resolveContact(wanted)
            guard let first = matches.first else {
                return .refused("No contact matching '\(wanted)' has a number I can use. "
                                + "Say the number, or set a default in Settings → Field Assist → Job reports.")
            }
            return .resolved([first])
        }
    }

    /// Names read back the way a person would say them: "Dave Smith or Dave Jones".
    private static func orList(_ names: [String]) -> String {
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " or " + last
    }

    /// An address this channel can use, or the sentence explaining why there is none.
    private enum RecipientResolution {
        case resolved([String])
        case refused(String)
    }
}
