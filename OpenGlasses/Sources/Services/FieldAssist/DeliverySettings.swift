import Foundation

/// A way the job report can leave the phone (Plan EM §5).
///
/// The channels a technician's thumb goes through and the one nobody touches are the same
/// enumeration on purpose: whether a record left by a tap or by an endpoint is the organisation's
/// decision, and a decision has to be expressible in one list.
enum DeliveryChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The in-app Mail composer, with the PDF and the JSON attached.
    case email
    /// The in-app Messages composer (iMessage / SMS); the PDF rides along when the device allows it.
    case messages
    case whatsapp
    case telegram
    /// The system share sheet, with both files.
    case shareSheet = "share_sheet"
    /// The organisation's own HTTP endpoint, through the offline queue. Nobody taps anything.
    case endpoint

    var id: String { rawValue }

    /// Every channel that goes through a person on this device. The endpoint is deliberately not
    /// one of them — it is the unattended route, and it is off until an organisation configures it.
    static var localChannels: Set<DeliveryChannel> {
        [.email, .messages, .whatsapp, .telegram, .shareSheet]
    }

    var label: String {
        switch self {
        case .email: return "Email"
        case .messages: return "Messages"
        case .whatsapp: return "WhatsApp"
        case .telegram: return "Telegram"
        case .shareSheet: return "Share…"
        case .endpoint: return "Endpoint"
        }
    }

    /// How the tool names the channel in a sentence it speaks.
    var spokenName: String {
        switch self {
        case .email: return "email"
        case .messages: return "a message"
        case .whatsapp: return "WhatsApp"
        case .telegram: return "Telegram"
        case .shareSheet: return "the share sheet"
        case .endpoint: return "the office endpoint"
        }
    }

    /// Whether the channel can carry the work order PDF and the JSON record at all. WhatsApp and
    /// Telegram are opened by URL scheme, which has no way to attach a file — they get the short
    /// summary and the job reference, and the record follows by another route.
    var carriesAttachments: Bool {
        switch self {
        case .email, .shareSheet, .endpoint: return true
        // Messages *may*, and only the device can say — `MFMessageComposeViewController
        // .canSendAttachments()` decides at compose time.
        case .messages: return true
        case .whatsapp, .telegram: return false
        }
    }

    /// Whether the channel needs somebody to send it to. The share sheet picks its own destination,
    /// and the endpoint is the destination.
    var needsRecipient: Bool {
        switch self {
        case .email, .messages, .whatsapp, .telegram: return true
        case .shareSheet, .endpoint: return false
        }
    }

    /// What a spoken word means. "Text", "SMS" and "iMessage" are all Messages; "base", "office"
    /// and "the system" mean whatever the organisation configured, so they are not resolved here.
    static func named(_ raw: String) -> DeliveryChannel? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "email", "mail", "e-mail": return .email
        case "message", "messages", "text", "sms", "imessage": return .messages
        case "whatsapp", "whats app": return .whatsapp
        case "telegram": return .telegram
        case "share", "share_sheet", "share sheet", "airdrop", "files": return .shareSheet
        case "endpoint", "api", "server": return .endpoint
        default: return nil
        }
    }
}

/// Where a finished job report is allowed to go, and to whom.
///
/// Stored on the device today. [Plan CT](../../../docs/plans/CT-org-configuration-profiles.md)'s
/// organisation profile is where these belong — a dispatcher decides the crew's destinations, not
/// each technician — so the type is shaped for that handover: `applying(organisation:)` merges a
/// profile in with the ceiling rule CT uses everywhere (an organisation may subtract a channel,
/// never add one the device refused), and nothing else in the app reads the fields directly.
struct DeliverySettings: Codable, Equatable {

    /// Where a job report goes by default when nobody names anybody.
    var emailRecipients: [String] = []
    /// Numbers or addresses for the Messages composer.
    var messageRecipients: [String] = []
    /// The organisation's HTTP endpoint. Empty means there is none, and the unattended route is off.
    var endpoint: String = ""
    /// Bearer token for `endpoint`. **Never encoded** — it lives in the Keychain, so it is absent
    /// from the stored blob, from an exported profile and from anything this type is serialised into.
    var endpointToken: String = ""
    /// The channels this device is allowed to use. Defaults to every local channel; the endpoint
    /// joins only once one is configured.
    var allowedChannels: Set<DeliveryChannel> = DeliveryChannel.localChannels

    init(emailRecipients: [String] = [], messageRecipients: [String] = [],
         endpoint: String = "", endpointToken: String = "",
         allowedChannels: Set<DeliveryChannel> = DeliveryChannel.localChannels) {
        self.emailRecipients = emailRecipients
        self.messageRecipients = messageRecipients
        self.endpoint = endpoint
        self.endpointToken = endpointToken
        self.allowedChannels = allowedChannels
    }

    /// `endpointToken` is deliberately absent: the token is a secret and a secret is not part of
    /// the settings blob. Everything else round-trips.
    enum CodingKeys: String, CodingKey {
        case emailRecipients = "email_recipients"
        case messageRecipients = "message_recipients"
        case endpoint
        case allowedChannels = "allowed_channels"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emailRecipients = try container.decodeIfPresent([String].self, forKey: .emailRecipients) ?? []
        messageRecipients = try container.decodeIfPresent([String].self, forKey: .messageRecipients) ?? []
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        allowedChannels = try container.decodeIfPresent(Set<DeliveryChannel>.self, forKey: .allowedChannels)
            ?? DeliveryChannel.localChannels
        endpointToken = ""
    }

    /// The endpoint as a URL, or nil when there is none or what is stored is not one.
    var endpointURL: URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            return nil
        }
        return url
    }

    var hasEndpoint: Bool { endpointURL != nil }

    /// Merge an organisation's profile over the device's settings.
    ///
    /// Recipients and the endpoint are the organisation's to set. Channels **subtract**: an
    /// organisation that forbids WhatsApp forbids it, and one that permits a channel this device
    /// has switched off does not switch it back on. Nothing calls this yet — CT is not built — but
    /// the rule is the one CT's ceilings follow, and it is proven here rather than assumed later.
    func applying(organisation: DeliverySettings) -> DeliverySettings {
        DeliverySettings(
            emailRecipients: organisation.emailRecipients.isEmpty ? emailRecipients : organisation.emailRecipients,
            messageRecipients: organisation.messageRecipients.isEmpty ? messageRecipients : organisation.messageRecipients,
            endpoint: organisation.endpoint.isEmpty ? endpoint : organisation.endpoint,
            endpointToken: organisation.endpointToken.isEmpty ? endpointToken : organisation.endpointToken,
            allowedChannels: allowedChannels.intersection(organisation.allowedChannels))
    }

    // MARK: - Storage

    static let storageKey = "fieldAssistDeliverySettings"
    static let tokenKeychainKey = "fieldAssistDeliveryToken"

    /// Read the stored settings, with the token pulled from the Keychain rather than the blob.
    static func load(defaults: UserDefaults = .standard) -> DeliverySettings {
        var settings = DeliverySettings()
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(DeliverySettings.self, from: data) {
            settings = decoded
        }
        settings.endpointToken = KeychainService.string(for: tokenKeychainKey) ?? ""
        return settings
    }

    /// Persist. The token goes to the Keychain; everything else to `UserDefaults` beside the other
    /// Field Assist settings.
    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
        _ = KeychainService.setString(endpointToken, for: Self.tokenKeychainKey)
    }
}

/// May this report go by this channel, to these people, with these files?
///
/// Pure, so the answer is the same in a test, on the session screen and inside the tool. A refusal
/// carries the sentence the assistant says rather than an error code, because the technician is
/// the one who has to do something about it.
struct DeliveryPolicy: Equatable {

    let settings: DeliverySettings

    init(settings: DeliverySettings) {
        self.settings = settings
    }

    enum Decision: Equatable {
        case allowed(recipients: [String])
        case refused(reason: String)

        var isAllowed: Bool { if case .allowed = self { return true }; return false }
        var reason: String? { if case .refused(let reason) = self { return reason }; return nil }
    }

    /// Channels this device may actually use right now, in the order the settings screen lists them.
    var availableChannels: [DeliveryChannel] {
        DeliveryChannel.allCases.filter { channel in
            guard settings.allowedChannels.contains(channel) else { return false }
            return channel != .endpoint || settings.hasEndpoint
        }
    }

    /// The channel "send the job report" means when nobody names one: email if it can be addressed,
    /// then Messages, then the share sheet, then whatever else is left. Nil when nothing is allowed.
    var defaultChannel: DeliveryChannel? {
        let available = availableChannels
        if available.contains(.email), !defaultRecipients(for: .email).isEmpty { return .email }
        if available.contains(.messages), !defaultRecipients(for: .messages).isEmpty { return .messages }
        if available.contains(.shareSheet) { return .shareSheet }
        return available.first
    }

    /// The addresses configured for a channel, with nothing invented.
    func defaultRecipients(for channel: DeliveryChannel) -> [String] {
        switch channel {
        case .email: return settings.emailRecipients.filter { !$0.isEmpty }
        case .messages, .whatsapp, .telegram: return settings.messageRecipients.filter { !$0.isEmpty }
        case .shareSheet, .endpoint: return []
        }
    }

    /// The whole decision: allowed, and to whom. `spoken` wins over the defaults — a technician who
    /// names a contact means that contact.
    func decide(channel: DeliveryChannel, spoken: [String] = []) -> Decision {
        guard settings.allowedChannels.contains(channel) else {
            return .refused(reason: "\(channel.label) isn't one of the channels this job's reports may use. "
                            + allowedSentence())
        }
        if channel == .endpoint, !settings.hasEndpoint {
            return .refused(reason: "No endpoint is configured for job reports. Set one in Settings → Field Assist → Job reports, or send it by email.")
        }
        let named = spoken.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let recipients = named.isEmpty ? defaultRecipients(for: channel) : named
        if channel.needsRecipient, recipients.isEmpty {
            return .refused(reason: "There's nobody to send it to by \(channel.spokenName). "
                            + "Say who, or set a default in Settings → Field Assist → Job reports.")
        }
        return .allowed(recipients: recipients)
    }

    /// "Allowed channels are email and the share sheet." — the half of a refusal that tells the
    /// technician what they *can* do.
    func allowedSentence() -> String {
        let names = availableChannels.map(\.spokenName)
        switch names.count {
        case 0: return "No channel is allowed for job reports on this device."
        case 1: return "The only channel allowed is \(names[0])."
        default:
            let list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
            return "Allowed channels are \(list)."
        }
    }
}
