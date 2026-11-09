import Foundation

/// An organisation asking an expert for their card (Plan KW §4).
///
/// The card has to exist before a job can be sent: an organisation lists an expert from their
/// card, and the expert fills it in on their own phone. The invite is how the organisation starts
/// that, the same way a handover starts a job. It's an `.ogexpert` file of its own type, sent by
/// the organisation's own share, and opening it on the expert's phone opens the card form.
///
/// **What it carries:** an invite id, the organisation's name, who invited, where to send the card
/// back, and when it was made and runs out. **What it never carries:** a rate, a customer, a job, a
/// profile, a licence or a key. It is unsigned, like a handover: anyone can write one, and all a
/// forged one gets its reader is an empty card form.
struct ExpertInvite: Codable, Equatable, Sendable {

    static let typeIdentifier = "openglasses.expert-invite"
    static let version = 1
    static let idPrefix = "invite-"
    /// How long an invite stays open after it is made: the same as a handover after Done.
    static let validDays = 30
    static let maxNameLength = 80
    static let maxReplyToLength = 120

    let type: String
    let version: Int
    let inviteId: String
    /// The organisation's name as its phone has it; may be empty on a phone with none.
    let organisation: String
    /// Who sent it, in their own words.
    let invitedBy: String
    /// Where the card goes back: the inviter's number or email, as they typed it.
    let replyTo: String?
    let created: Date
    let expires: Date

    init(inviteId: String = ExpertInvite.newId(), organisation: String, invitedBy: String, replyTo: String?,
         created: Date, expires: Date? = nil) {
        self.type = Self.typeIdentifier
        self.version = Self.version
        self.inviteId = inviteId
        self.organisation = Self.cleaned(organisation, max: Self.maxNameLength)
        self.invitedBy = Self.cleaned(invitedBy, max: Self.maxNameLength)
        let reply = replyTo.map { Self.cleaned($0, max: Self.maxReplyToLength) }
        self.replyTo = (reply?.isEmpty ?? true) ? nil : reply
        // Whole seconds, so the file's ISO 8601 dates read back to the same value.
        let start = Date(timeIntervalSince1970: created.timeIntervalSince1970.rounded(.down))
        self.created = start
        self.expires = expires ?? start.addingTimeInterval(TimeInterval(Self.validDays) * 86_400)
    }

    static func newId() -> String { idPrefix + UUID().uuidString.lowercased() }

    /// The name the expert reads: the organisation, or who sent it when the phone has no name.
    var senderName: String { organisation.isEmpty ? invitedBy : organisation }

    func isExpired(at now: Date) -> Bool { now >= expires }

    /// Why this invite can't be used, or nil.
    var problem: String? {
        guard type == Self.typeIdentifier else { return "it isn't an expert invite" }
        guard version == Self.version else { return "it was made by a newer version of the app" }
        guard inviteId.hasPrefix(Self.idPrefix), inviteId.count <= 64,
              inviteId.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }) else {
            return "its id isn't one this app writes"
        }
        guard !senderName.isEmpty else { return "it doesn't say who it's from" }
        guard expires > created, expires.timeIntervalSince(created) <= TimeInterval(Self.validDays + 1) * 86_400 else {
            return "its dates aren't ones this app writes"
        }
        return nil
    }

    static func cleaned(_ text: String, max: Int) -> String {
        let flat = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        }))
        return String(flat.trimmingCharacters(in: .whitespaces).prefix(max))
    }

    private enum CodingKeys: String, CodingKey {
        case type, version, inviteId = "id", organisation, invitedBy, replyTo, created, expires
    }

    /// Strict on what it reads; fields it doesn't know (a rate, a customer) are dropped, never kept.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        version = try c.decode(Int.self, forKey: .version)
        inviteId = try c.decode(String.self, forKey: .inviteId)
        organisation = Self.cleaned(try c.decodeIfPresent(String.self, forKey: .organisation) ?? "", max: Self.maxNameLength)
        invitedBy = Self.cleaned(try c.decodeIfPresent(String.self, forKey: .invitedBy) ?? "", max: Self.maxNameLength)
        let reply = try c.decodeIfPresent(String.self, forKey: .replyTo).map { Self.cleaned($0, max: Self.maxReplyToLength) }
        replyTo = (reply?.isEmpty ?? true) ? nil : reply
        created = try c.decode(Date.self, forKey: .created)
        expires = try c.decode(Date.self, forKey: .expires)
    }
}

/// An invite this phone was sent and hasn't answered or declined (Plan KW §4). Held in Assisting
/// beside the handovers, under the same protection, retention walk and erasure walk.
struct OpenInvite: Codable, Equatable, Identifiable, Sendable {
    let invite: ExpertInvite
    let receivedAt: Date
    /// Swiped off the Home screen. It stays in Assisting until it runs out.
    var homeDismissed: Bool?

    var id: String { invite.inviteId }
}

// MARK: - The wire

/// The invite as an `.ogexpert` file, and the card file that answers one.
enum ExpertInviteCodec {

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func fileData(_ invite: ExpertInvite) -> Data {
        (try? encoder().encode(invite)) ?? Data()
    }

    private struct TypePeek: Decodable { let type: String }

    /// Whether an `.ogexpert` file's bytes are an invite rather than a card.
    static func isInvite(_ data: Data) -> Bool {
        guard data.count <= ExpertCardCodec.maximumBytes,
              let peek = try? JSONDecoder().decode(TypePeek.self, from: data) else { return false }
        return peek.type == ExpertInvite.typeIdentifier
    }

    /// An invite from a file's bytes. Refused, by name, unless it is exactly a version-1 invite.
    static func read(_ data: Data) -> Result<ExpertInvite, ExpertCardCodec.ReadError> {
        guard data.count <= ExpertCardCodec.maximumBytes else { return .failure(.tooLarge) }
        guard isInvite(data), let invite = try? decoder().decode(ExpertInvite.self, from: data) else {
            return .failure(.notACard)
        }
        if let problem = invite.problem { return .failure(.refused(problem)) }
        return .success(invite)
    }

    /// "invite-northside-heating.ogexpert".
    static func fileName(_ invite: ExpertInvite) -> String {
        let stem = String(invite.senderName.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(40))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "invite" + (stem.isEmpty ? "" : "-" + stem) + "." + ExpertCard.fileExtension
    }

    // MARK: The card that answers an invite

    /// The key a card file carries when it answers an invite. It sits beside the card, not in it:
    /// one card serves every organisation, and an older app ignores the key.
    static let answeringKey = "answeringInvite"

    /// The card's file, saying which invite it answers.
    static func cardFileData(_ card: ExpertCard, answering inviteId: String?) -> Data {
        let plain = ExpertCardCodec.fileData(card)
        guard let inviteId,
              var object = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else { return plain }
        object[answeringKey] = inviteId
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])) ?? plain
    }

    /// The invite a card file says it answers, or nil.
    static func answeredInvite(in data: Data) -> String? {
        guard data.count <= ExpertCardCodec.maximumBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = object[answeringKey] as? String,
              id.hasPrefix(ExpertInvite.idPrefix), id.count <= 64 else { return nil }
        return id
    }
}
