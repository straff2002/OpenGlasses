import Foundation

// Plan KT §7.1 — how a card's draft leaves the phone. Every route ends at the platform's own Send
// (or another app the wearer confirms in): nothing here can send by itself (§7.2). The choice is a
// pure function of the channel and what the device can do, so "Mail composer, else `mailto:`,
// else copy" (decision 2) is a table test.

/// One way to hand a draft over, tried in order until one works.
enum DraftComposerRoute: Equatable, Sendable {
    /// `MFMessageComposeViewController`, with a result.
    case messagesComposer(recipients: [String], body: String)
    /// `MFMailComposeViewController`, with a result.
    case mailComposer(recipients: [String], subject: String?, body: String)
    /// Another app by URL (`sms:`, `mailto:`, `whatsapp://send`), with no result.
    case openURL(URL, app: DraftChannel)
    /// The draft on the clipboard, and a line saying so.
    case copy(String)

    /// Whether the platform reports what happened.
    var reportsResult: Bool {
        switch self {
        case .messagesComposer, .mailComposer: true
        case .openURL, .copy: false
        }
    }
}

/// What this device can do, asked once when the wearer presses the button.
struct DraftComposerAvailability: Equatable, Sendable {
    var canSendText: Bool
    var canSendMail: Bool
    var whatsappInstalled: Bool
}

enum DraftComposerRouter {

    /// The routes for `draft`, best first. The presenter opens the first that works.
    static func routes(for draft: PreparedDraft, availability: DraftComposerAvailability) -> [DraftComposerRoute] {
        let addresses = draft.recipient.addresses
        switch draft.channel {
        case .messages:
            return messagesRoutes(addresses: addresses.filter(isPhoneLike), body: draft.text,
                                  canSendText: availability.canSendText)
        case .email:
            let emails = addresses.filter { $0.contains("@") }
            if availability.canSendMail {
                return [.mailComposer(recipients: emails, subject: draft.subject, body: draft.text)]
            }
            var routes: [DraftComposerRoute] = []
            if let url = mailtoURL(to: emails, subject: draft.subject, body: draft.text) {
                routes.append(.openURL(url, app: .email))
            }
            routes.append(.copy(draft.text))
            return routes
        case .whatsapp:
            let phones = addresses.filter(isPhoneLike)
            if availability.whatsappInstalled, let phone = phones.first,
               let url = whatsappURL(phone: phone, text: draft.text) {
                return [.openURL(url, app: .whatsapp)]
            }
            return messagesRoutes(addresses: phones, body: draft.text, canSendText: availability.canSendText)
        }
    }

    private static func messagesRoutes(addresses: [String], body: String, canSendText: Bool) -> [DraftComposerRoute] {
        if canSendText { return [.messagesComposer(recipients: addresses, body: body)] }
        var routes: [DraftComposerRoute] = []
        if let url = smsURL(to: addresses.first, body: body) { routes.append(.openURL(url, app: .messages)) }
        routes.append(.copy(body))
        return routes
    }

    static func isPhoneLike(_ address: String) -> Bool {
        !address.contains("@") && address.contains(where: \.isNumber)
    }

    static func digits(_ phone: String) -> String { phone.filter { $0.isNumber || $0 == "+" } }

    /// `sms:<number>&body=…`, as `send_message` builds it.
    static func smsURL(to phone: String?, body: String) -> URL? {
        guard let encoded = body.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) else { return nil }
        return URL(string: "sms:\(phone.map(digits) ?? "")&body=\(encoded)")
    }

    static func mailtoURL(to recipients: [String], subject: String?, body: String) -> URL? {
        func encoded(_ value: String) -> String? { value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) }
        guard let to = recipients.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let bodyValue = encoded(body) else { return nil }
        var query = ""
        if let subject, !subject.isEmpty, let subjectValue = encoded(subject) { query += "subject=\(subjectValue)&" }
        query += "body=\(bodyValue)"
        return URL(string: "mailto:\(to)?\(query)")
    }

    static func whatsappURL(phone: String, text: String) -> URL? {
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) else { return nil }
        return URL(string: "whatsapp://send?phone=\(digits(phone))&text=\(encoded)")
    }

    /// Query-value characters: `&`, `=`, `+` and `#` are encoded so a draft cannot end its own
    /// parameter early.
    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#?")
        return set
    }()

    // MARK: - Results

    /// `MessageComposeResult` raw values: 0 cancelled, 1 sent, 2 failed.
    static func messageResult(_ raw: Int) -> PreparedCardState.HandOffResult {
        raw == 1 ? .sent : .cancelled
    }

    /// `MFMailComposeResult` raw values: 0 cancelled, 1 saved, 2 sent, 3 failed. A saved draft is
    /// not a sent message, so the card stays.
    static func mailResult(_ raw: Int, error: Error?) -> PreparedCardState.HandOffResult {
        error == nil && raw == 2 ? .sent : .cancelled
    }
}
