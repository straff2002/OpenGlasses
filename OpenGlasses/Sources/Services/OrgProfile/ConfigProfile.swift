import Foundation

/// Plan CT P1 — an organisation's configuration profile: what this device may do, signed by the
/// vendor's profile key and verified by `ProfileVerification`.
///
/// A profile sets values and bounds; it never carries code, prompts or secrets. Its settings are
/// decoded **lossily** — a profile is written against one app version and scanned on another, so
/// an unknown key or a malformed value is the normal case, and `ProfileApplier` names every one it
/// drops instead of failing the whole profile.
struct ConfigProfile: Codable, Equatable, Sendable {
    /// The one value `format` may hold; anything else is not a profile.
    static let formatId = "openglasses.org-profile"
    /// The newest schema this build understands. A newer profile is refused with a reason rather
    /// than applied with semantics this build does not know.
    static let supportedSchemaVersion = 1
    /// The bounds the app holds `leaseDays` to, whatever the profile says — so a typo is neither a
    /// one-day lease nor no expiry at all.
    static let leaseDaysRange = 7...365
    /// Bounds for the two erasure windows (`eraseAfterLapseDays`, `undeliveredEraseDays`).
    static let erasureDaysRange = 1...365
    /// How long a revoked phone retries delivering the firm's records before erasing them anyway.
    static let defaultUndeliveredEraseDays = 30

    let format: String
    let schemaVersion: Int
    /// Which embedded public key signed this profile (`ProfileVerification.productionKeys`).
    let keyId: String
    /// Stable across re-mints of the same link, so a revocation can name the profile it ends.
    let profileId: String
    /// Shown on the managed row and as the reason on every locked control.
    let organizationName: String
    let issued: Date
    /// The organisation's own term for this profile. Nil means none beyond the lease.
    var policyExpiry: Date?
    /// How long the phone stays the firm's without hearing from the profile's URL. Held to
    /// `leaseDaysRange` by the applier.
    var leaseDays: Int
    /// Opt-in: erase the firm's content this many days after a lease lapses unheard. Absent means
    /// a lapse only ever locks.
    var eraseAfterLapseDays: Int?
    /// How long a revoked phone keeps retrying to deliver session logs and unsent reports before
    /// erasing them anyway. Absent means `defaultUndeliveredEraseDays`.
    var undeliveredEraseDays: Int?
    /// The Field Assist licence code the profile's entitlement rides on. It is signed by the
    /// licence key, separately, and its own `expires` is the entitlement clock — the profile never
    /// restates it.
    var licenceCode: String?
    /// The vault pack enrolment installs, and where the organisation's own manuals come from.
    var vaultPack: VaultPackReference?
    /// Skill packs the profile refers to by id; a profile never embeds one.
    var skillPacks: [String]?
    /// Enrolments on this link that have been revoked — the leaver case on a shared crew link.
    var revokedEnrolmentIds: [String]?
    /// The settings, keyed by the raw `SettingKey` name. Raw on purpose: see `RawSetting`.
    var settings: [String: RawSetting]

    struct VaultPackReference: Codable, Equatable, Sendable {
        let packId: String
        /// An organisation-hosted location for its own documents. A pointer, never bytes.
        var documentsSource: String?
    }

    init(keyId: String, profileId: String, organizationName: String, issued: Date,
         policyExpiry: Date? = nil, leaseDays: Int, eraseAfterLapseDays: Int? = nil,
         undeliveredEraseDays: Int? = nil, licenceCode: String? = nil,
         vaultPack: VaultPackReference? = nil, skillPacks: [String]? = nil,
         revokedEnrolmentIds: [String]? = nil, settings: [String: RawSetting] = [:],
         format: String = ConfigProfile.formatId,
         schemaVersion: Int = ConfigProfile.supportedSchemaVersion) {
        self.format = format
        self.schemaVersion = schemaVersion
        self.keyId = keyId
        self.profileId = profileId
        self.organizationName = organizationName
        self.issued = issued
        self.policyExpiry = policyExpiry
        self.leaseDays = leaseDays
        self.eraseAfterLapseDays = eraseAfterLapseDays
        self.undeliveredEraseDays = undeliveredEraseDays
        self.licenceCode = licenceCode
        self.vaultPack = vaultPack
        self.skillPacks = skillPacks
        self.revokedEnrolmentIds = revokedEnrolmentIds
        self.settings = settings
    }
}

/// One entry of a profile's `settings`, decoded without failing.
///
/// A value this build cannot read — a number where a flag belongs, a nested object — decodes to a
/// nil `value` rather than throwing, so one bad entry is one named drop in the applier's report,
/// not a refused profile.
struct RawSetting: Codable, Equatable, Sendable {
    let value: ProfileValue?
    /// `"default"` or `"ceiling"`; anything else is reported by the applier.
    let disposition: String?

    init(value: ProfileValue?, disposition: String?) {
        self.value = value
        self.disposition = disposition
    }

    init(_ value: ProfileValue, _ disposition: ProfileDisposition) {
        self.init(value: value, disposition: disposition.rawValue)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try? container.decodeIfPresent(ProfileValue.self, forKey: .value)
        disposition = try? container.decodeIfPresent(String.self, forKey: .disposition)
    }
}

/// Whether the organisation sets a starting value or a bound nothing downstream may widen.
enum ProfileDisposition: String, Codable, Sendable {
    /// A starting value the person may change afterwards.
    case `default`
    /// A bound that no user, login, entitlement or later feature may widen.
    case ceiling
}

/// The value types a profile setting can hold. Deliberately few: flags, strings and string lists.
enum ProfileValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case string(String)
    case strings([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let list = try? container.decode([String].self) {
            self = .strings(list)
        } else {
            throw DecodingError.typeMismatch(
                ProfileValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "not a flag, string or string list"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let flag): try container.encode(flag)
        case .string(let text): try container.encode(text)
        case .strings(let list): try container.encode(list)
        }
    }
}

/// A whole-link revocation, hosted at the profile's URL in place of the profile. Signed with the
/// profile key under its own domain, so neither document can be replayed as the other.
struct ProfileRevocation: Codable, Equatable, Sendable {
    static let formatId = "openglasses.org-revocation"

    let format: String
    let keyId: String
    /// The profile this revocation ends. A revocation for another profile changes nothing here.
    let profileId: String
    let issued: Date

    init(keyId: String, profileId: String, issued: Date, format: String = ProfileRevocation.formatId) {
        self.format = format
        self.keyId = keyId
        self.profileId = profileId
        self.issued = issued
    }
}

/// How a profile reached this device. Recorded with every applied profile, because the source
/// decides removal and the wording of the managed row.
enum ProfileSource: String, Codable, CaseIterable, Sendable {
    /// `openglasses://enrol?url=…` — emailed or messaged.
    case link
    /// A QR code scanned with the phone camera.
    case scan
    /// A licence key whose signed `profile` claim named the profile (Plan CT 3a). Removal clears the
    /// licence it enrolled with: the key was the organisation's, whoever typed it.
    case licence
    /// Managed App Configuration written by an MDM. **No reader ships yet** (Plan CT, decided
    /// 2026-09-24); the case exists so removal and precedence are built and tested for it now.
    case managedConfig

    /// The key a Managed App Configuration dictionary (`com.apple.configuration.managed`) carries
    /// the signed profile under — the document itself, or the HTTPS URL it is hosted at. Never raw
    /// settings: one trust path, one verification.
    static let managedConfigProfileKey = "orgProfile"

    /// A profile an MDM delivered is not removable on the phone — the MDM would reapply it — so
    /// the managed row names who manages the device instead of offering a button that cannot work.
    var isLocallyRemovable: Bool { self != .managedConfig }
}

/// What an ingress adapter hands over: the signed document, or the HTTPS URL it is hosted at.
enum ProfileDelivery: Equatable, Sendable {
    case inline(String)
    case pointer(URL)
}

/// The seam every way a profile arrives plugs into — the link, the scanner and, later, the MDM
/// reader. An adapter yields deliveries and its source and nothing else: verification and apply
/// live in one place, so a new ingress adds no trust path of its own.
protocol ProfileIngress {
    var source: ProfileSource { get }
    func deliveries() -> AsyncStream<ProfileDelivery>
}
