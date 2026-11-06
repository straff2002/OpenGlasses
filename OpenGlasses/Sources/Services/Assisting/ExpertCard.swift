import Foundation

/// The expert's card (Plan KM §1, §7, P2): who they are and how to reach them, filled in once on
/// their own phone and shared as a file or a QR code with every organisation they work for.
///
/// **What it carries:** a card id, the name, a number, a FaceTime handle, the channel jobs should
/// come by, the specialties, and the trades and places the expert is licensed for. **What it
/// never carries:** a kind, on-call hours or a rate. Those are the organisation's to set on its
/// own list (decision 6: the card is the same for every organisation, and an organisation's
/// terms are its own), so this type has no field for any of them and the decoder ignores one.
///
/// **The card id is the identity.** An organisation that imports the card lists the expert under
/// that id, so the handover it sends is addressed to it, and the expert's reply carries it back:
/// the reply matches its list entry exactly, by the id, not by spelling a name the same way.
struct ExpertCard: Codable, Equatable, Sendable {

    static let typeIdentifier = "openglasses.expert-card"
    static let version = 1
    /// Every card id starts with this, which is how an organisation's phone knows a list entry
    /// came from a card and so must be answered by the same card.
    static let idPrefix = "card-"

    static let fileExtension = "ogexpert"
    /// Declared in `Info.plist`, opened as a copy.
    static let utiIdentifier = "com.openglasses.app.expert-card"
    static let mimeType = "application/vnd.openglasses.expert-card+json"

    static let maxLicences = 10
    static let maxLicenceLength = 80
    /// What fits in a QR code a phone camera reads easily; a longer card goes as a file.
    static let maxCodeBytes = 1_200

    let type: String
    let version: Int
    let cardId: String
    let name: String
    let phone: String?
    let faceTimeHandle: String?
    let handoverChannel: EscalationContact.HandoverChannel?
    let specialties: [String]
    /// The trades and places licensed for, in the expert's words ("Gas, England and Wales").
    let licences: [String]

    init(cardId: String = ExpertCard.newId(), name: String, phone: String? = nil, faceTimeHandle: String? = nil,
         handoverChannel: EscalationContact.HandoverChannel? = nil, specialties: [String] = [],
         licences: [String] = []) {
        self.init(type: Self.typeIdentifier, version: Self.version, cardId: cardId, name: name, phone: phone,
                  faceTimeHandle: faceTimeHandle, handoverChannel: handoverChannel, specialties: specialties,
                  licences: licences)
    }

    private init(type: String, version: Int, cardId: String, name: String, phone: String?, faceTimeHandle: String?,
                 handoverChannel: EscalationContact.HandoverChannel?, specialties: [String], licences: [String]) {
        self.type = type
        self.version = version
        self.cardId = cardId
        // The list entry's own cleaning, so what the organisation lists is what the card said.
        let contact = EscalationContact(id: cardId, name: name, phone: phone, faceTimeHandle: faceTimeHandle,
                                        handoverChannel: handoverChannel, specialties: specialties)
        self.name = contact.name
        self.phone = contact.phone
        self.faceTimeHandle = contact.faceTimeHandle
        self.handoverChannel = handoverChannel
        self.specialties = contact.specialties
        self.licences = Self.cleanedLicences(licences)
    }

    static func newId() -> String { idPrefix + UUID().uuidString.lowercased() }

    static func isCardId(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// As a contact the picker and the call can use: the organisation's own entry is built from
    /// this, with its own kind, hours and rate added there.
    var contact: EscalationContact {
        EscalationContact(id: cardId, name: name, phone: phone, faceTimeHandle: faceTimeHandle,
                          handoverChannel: handoverChannel, specialties: specialties)
    }

    /// Why this card can't be shared or imported, or nil.
    var problem: String? {
        guard type == Self.typeIdentifier else { return "it isn't an expert card" }
        guard version == Self.version else { return "it was made by a newer version of the app" }
        guard Self.isCardId(cardId), cardId.count <= 64,
              cardId.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }) else {
            return "its id isn't one this app writes"
        }
        if let problem = contact.problem { return problem }
        if licences.count > Self.maxLicences { return "it lists more than \(Self.maxLicences) licences" }
        return nil
    }

    static func cleanedLicences(_ lines: [String]) -> [String] {
        lines.flatMap { $0.split(whereSeparator: \.isNewline) }
            .map { String(String.UnicodeScalarView($0.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
                .trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { String($0.prefix(maxLicenceLength)) }
            .prefix(maxLicences).map { $0 }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, version, cardId = "id", name, phone, faceTimeHandle = "faceTime", handoverChannel = "handover",
             specialties, licences
    }

    /// Lenient on what it ignores, strict on what it reads: unknown fields — a kind, a rate, hours
    /// someone added by hand — are dropped, never applied.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Type and version kept as read, so `problem` names a card of another type or version.
        self.init(type: try c.decode(String.self, forKey: .type),
                  version: try c.decode(Int.self, forKey: .version),
                  cardId: try c.decode(String.self, forKey: .cardId),
                  name: try c.decode(String.self, forKey: .name),
                  phone: try c.decodeIfPresent(String.self, forKey: .phone),
                  faceTimeHandle: try c.decodeIfPresent(String.self, forKey: .faceTimeHandle),
                  handoverChannel: try? c.decodeIfPresent(EscalationContact.HandoverChannel.self, forKey: .handoverChannel),
                  specialties: try c.decodeIfPresent([String].self, forKey: .specialties) ?? [],
                  licences: try c.decodeIfPresent([String].self, forKey: .licences) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(version, forKey: .version)
        try c.encode(cardId, forKey: .cardId)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(phone, forKey: .phone)
        try c.encodeIfPresent(faceTimeHandle, forKey: .faceTimeHandle)
        try c.encodeIfPresent(handoverChannel, forKey: .handoverChannel)
        if !specialties.isEmpty { try c.encode(specialties, forKey: .specialties) }
        if !licences.isEmpty { try c.encode(licences, forKey: .licences) }
    }
}

// MARK: - The card as a file and as a code

/// The card's two wire forms: an `.ogexpert` JSON file, and the same JSON compacted into a QR code.
enum ExpertCardCodec {

    enum ReadError: Error, Equatable {
        case notACard
        case tooLarge
        case refused(String)
    }

    /// Generous for one card, and a ceiling on what a reader parses.
    static let maximumBytes = 16 * 1024

    static func fileData(_ card: ExpertCard) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? encoder.encode(card)) ?? Data()
    }

    /// The text the QR code carries: the card's JSON, compact. Nil when it is too long for a code a
    /// phone reads easily; the file always works.
    static func codeText(_ card: ExpertCard) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(card), data.count <= ExpertCard.maxCodeBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A card from a file's bytes or a scanned code's text. Refused, by name, unless it is exactly
    /// a version-1 card that would stand as a list entry.
    static func read(_ data: Data) -> Result<ExpertCard, ReadError> {
        guard data.count <= maximumBytes else { return .failure(.tooLarge) }
        guard let card = try? JSONDecoder().decode(ExpertCard.self, from: data) else { return .failure(.notACard) }
        guard card.type == ExpertCard.typeIdentifier else { return .failure(.notACard) }
        if let problem = card.problem { return .failure(.refused(problem)) }
        return .success(card)
    }

    static func read(code text: String) -> Result<ExpertCard, ReadError> {
        read(Data(text.utf8))
    }

    static func isCardFile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == ExpertCard.fileExtension
    }

    /// "sam-ferreira.ogexpert": the name, never a number.
    static func fileName(_ card: ExpertCard) -> String {
        let stem = String(card.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(40))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (stem.isEmpty ? "expert-card" : stem) + "." + ExpertCard.fileExtension
    }

    static func describe(_ error: ReadError) -> String {
        switch error {
        case .notACard: return "That isn't an expert card this app can read."
        case .tooLarge: return "That card is larger than this app opens."
        case .refused(let why): return "That expert card can't be used: \(why)."
        }
    }
}

// MARK: - The expert's own card, on their phone

/// The one card this phone's owner made (§7). The wearer's own details, entered on purpose: a
/// preference, kept until they delete it. Registered in `DataStoreRegistry` as `expertCard`.
final class ExpertCardStore: @unchecked Sendable {
    static let shared = ExpertCardStore()
    static let key = "assistingExpertCard"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var card: ExpertCard? {
        guard let data = defaults.data(forKey: Self.key),
              let card = try? JSONDecoder().decode(ExpertCard.self, from: data), card.problem == nil else { return nil }
        return card
    }

    /// Save the card, or say why it can't stand.
    @discardableResult
    func save(_ card: ExpertCard) -> String? {
        if let problem = card.problem { return problem }
        guard let data = try? JSONEncoder().encode(card) else { return "the card could not be saved" }
        defaults.set(data, forKey: Self.key)
        return nil
    }

    func remove() { defaults.removeObject(forKey: Self.key) }
}
