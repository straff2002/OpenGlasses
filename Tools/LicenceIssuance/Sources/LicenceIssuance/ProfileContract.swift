import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto // swift-crypto: the same API on Linux (the service's containers)
#endif

/// The organisation-profile contract, shared by `make-org-profile` and preset-built profiles (JS P0b), so a
/// profile minted by hand and one built from a preset are the same bytes. The structs, the allow-list and the
/// directions must stay identical to ConfigProfile and SettingKey in the app (OpenGlasses/Sources/Services/OrgProfile).
/// Nested so the app's test bundle, which compiles these sources beside the app's own types, sees no clashes.
public enum ProfileContract {
    public enum Value: Codable, Equatable {
        case bool(Bool), string(String), strings([String])
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) { self = .bool(flag) }
            else if let text = try? container.decode(String.self) { self = .string(text) }
            else if let list = try? container.decode([String].self) { self = .strings(list) }
            else { throw DecodingError.typeMismatch(Value.self, .init(codingPath: decoder.codingPath, debugDescription: "not a flag, string or string list")) }
        }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .bool(let flag): try container.encode(flag)
            case .string(let text): try container.encode(text)
            case .strings(let list): try container.encode(list)
            }
        }
        var typeName: String {
            switch self { case .bool: return "bool"; case .string: return "string"; case .strings: return "strings" }
        }
    }
    public struct Setting: Codable, Equatable {
        public let value: Value; public let disposition: String
        public init(value: Value, disposition: String) { self.value = value; self.disposition = disposition }
    }
    public struct VaultPack: Codable, Equatable {
        public let packId: String; public let documentsSource: String?
        public init(packId: String, documentsSource: String?) { self.packId = packId; self.documentsSource = documentsSource }
    }
    /// The provider and model only — never a key.
    public struct AIModel: Codable, Equatable {
        public let provider: String; public let model: String; public let baseURL: String?; public let name: String?
        public init(provider: String, model: String, baseURL: String? = nil, name: String? = nil) {
            self.provider = provider; self.model = model; self.baseURL = baseURL; self.name = name
        }
    }
    /// PBKDF2-HMAC-SHA256 of the administrator passcode. Never the passcode.
    public struct PasscodeVerifier: Codable, Equatable {
        public let salt: String; public let iterations: Int; public let hash: String
        public init(salt: String, iterations: Int, hash: String) { self.salt = salt; self.iterations = iterations; self.hash = hash }
    }
    public struct OfficeAuthority: Codable, Equatable {
        public let organizationID: String; public let administratorPublicKey: String; public let transportPolicy: String
    }
    /// Plan LR — where the company's own vaults are listed: a pointer, never content. Mirrors
    /// `ConfigProfile.CompanyVaultsReference`. `generation` rises with every change the partner
    /// makes, so a phone fetches the catalog only when it is above the one it has applied;
    /// `minAppBuild` is the oldest build that can read it (older builds ignore the field).
    public struct CompanyVaults: Codable, Equatable {
        public let catalog: String; public let generation: Int; public let minAppBuild: Int?
        public init(catalog: String, generation: Int, minAppBuild: Int? = nil) {
            self.catalog = catalog; self.generation = generation; self.minAppBuild = minAppBuild
        }
    }
    /// Plan HA C2 — mirrors `ConfigProfile.LockdownSpec`.
    public struct Lockdown: Codable, Equatable {
        public let open: [String]?; public let lock: [String]?; public let closedTools: [String]?
        public init(open: [String]? = nil, lock: [String]? = nil, closedTools: [String]? = nil) {
            self.open = open; self.lock = lock; self.closedTools = closedTools
        }
    }

    /// What `make-org-profile make` reads, field for field.
    public struct Input: Codable, Equatable {
        public var profileId: String
        public var organizationName: String
        public var leaseDays: Int
        public var policyExpiry: String?
        public var eraseAfterLapseDays: Int?
        public var undeliveredEraseDays: Int?
        public var licenceCode: String?
        public var vaultPack: VaultPack?
        public var skillPacks: [String]?
        public var revokedEnrolmentIds: [String]?
        public var settings: [String: Setting]?
        public var aiModel: AIModel?
        public var edition: String?
        public var adminCard: String?
        public var lockdown: Lockdown?
        public var officeAuthority: OfficeAuthority?
        /// Sealed company credentials by name (`Credential`), never a readable key.
        public var credentials: [String: String]?
        /// Plan LR: the company vault catalog. Absent on every profile without company vaults.
        public var companyVaults: CompanyVaults?
        public init(profileId: String, organizationName: String, leaseDays: Int, policyExpiry: String? = nil,
                    eraseAfterLapseDays: Int? = nil, undeliveredEraseDays: Int? = nil, licenceCode: String? = nil,
                    vaultPack: VaultPack? = nil, skillPacks: [String]? = nil, revokedEnrolmentIds: [String]? = nil,
                    settings: [String: Setting]? = nil, aiModel: AIModel? = nil, edition: String? = nil,
                    adminCard: String? = nil, lockdown: Lockdown? = nil, officeAuthority: OfficeAuthority? = nil,
                    credentials: [String: String]? = nil, companyVaults: CompanyVaults? = nil) {
            self.profileId = profileId; self.organizationName = organizationName; self.leaseDays = leaseDays
            self.policyExpiry = policyExpiry; self.eraseAfterLapseDays = eraseAfterLapseDays
            self.undeliveredEraseDays = undeliveredEraseDays; self.licenceCode = licenceCode; self.vaultPack = vaultPack
            self.skillPacks = skillPacks; self.revokedEnrolmentIds = revokedEnrolmentIds; self.settings = settings
            self.aiModel = aiModel; self.edition = edition; self.adminCard = adminCard; self.lockdown = lockdown
            self.officeAuthority = officeAuthority; self.credentials = credentials
            self.companyVaults = companyVaults
        }
    }

    /// The signed document, mirroring the app's `ConfigProfile`.
    public struct Document: Codable, Equatable {
        public let format: String
        public let schemaVersion: Int
        public let keyId: String
        public let profileId: String
        public let organizationName: String
        public let issued: Date
        public let policyExpiry: Date?
        public let leaseDays: Int
        public let eraseAfterLapseDays: Int?
        public let undeliveredEraseDays: Int?
        public let licenceCode: String?
        public let vaultPack: VaultPack?
        public let skillPacks: [String]?
        public let revokedEnrolmentIds: [String]?
        public let aiModel: AIModel?
        public let edition: String?
        public let adminPasscode: PasscodeVerifier?
        public let adminCard: String?
        public let lockdown: Lockdown?
        public let officeAuthority: OfficeAuthority?
        public let credentials: [String: String]?
        /// Optional and omitted when nil, so a profile without company vaults is the bytes it was.
        public let companyVaults: CompanyVaults?
        public let settings: [String: Setting]
    }

    /// Why `check` refused an input. The message is what `make-org-profile` prints after "error: ".
    public struct Invalid: Error, Equatable { public let message: String }

    /// LLMProvider's raw values in the app (OpenGlasses/Sources/Services/LLMService.swift).
    public static let knownProviders: Set<String> = ["anthropic", "openai", "chatgpt", "gemini", "geminiVertex", "groq", "deepseek",
                                                     "mistral", "zai", "qwen", "minimax", "xai", "openrouter", "custom", "local",
                                                     "appleOnDevice"]
    /// `SettingsCategoryID` raw values, in hub order. Must stay identical to the app's enum.
    public static let settingsCategoryIds = ["intelligence", "voice", "everyday", "devices", "accessibility", "field-assist", "assisting", "my-manuals", "look-and-feel",
                                             "tools", "connections", "capture", "display", "advanced", "diagnostics"]
    /// `ManagedLockdown.pinnedOpen` — never locked by an organisation.
    public static let pinnedOpenCategoryIds: Set<String> = ["accessibility", "look-and-feel", "diagnostics", "assisting"]
    /// The models `organizationManualSearchModel` may pin — `ManualSearchModel`'s raw values in the app.
    public static let knownManualSearchModels: Set<String> = ["standard", "smarter", "searchTrained"]
    /// The trades `fieldAssistDefaultTrades` may name — `FieldTrade`'s raw values.
    public static let knownTrades: Set<String> = ["refrigeration_hvac", "electrical"]
    /// `AdminSecrets.iterationRange` in the app: fewer is too cheap to brute-force, more stalls the phone.
    public static let passcodeIterationRange = 10_000...5_000_000

    /// SettingKey, by kind. "owned" ignores the disposition; "ceiling:<Bool>" may only be pinned that
    /// way; "default:<type>" is a starting value.
    public static let allowList: [String: String] = [
        "organizationDisplayName": "owned:string",
        "organizationJobSigningKey": "owned:string",
        "organizationJobReportChannel": "owned:string",
        "organizationReportRecipients": "owned:strings",
        "organizationAllowsUnsignedVaults": "ceiling:false",
        "organizationRequiresSignedJobFiles": "ceiling:true",
        "organizationRequiresCustomerSignOff": "ceiling:true",
        "privacyFilterEnabled": "ceiling:true",
        "remoteInvokeObserveEnabled": "ceiling:false",
        "remoteInvokeOutputEnabled": "ceiling:false",
        "remoteInvokeCaptureEnabled": "ceiling:false",
        "mcpServerEnabled": "ceiling:false",
        "agentModeEnabled": "ceiling:false",
        "fieldAssistEnabled": "default:bool",
        "workizEnabled": "owned:bool",
        "fieldAssistDefaultVaultId": "default:string",
        "fieldAssistDefaultMode": "default:string",
        "supportReportEmail": "default:string",
        "organizationAccentColor": "owned:string",
        "organizationToolDefinitionsMode": "owned:string",
        "organizationManualSearchModel": "owned:string",
        "accentColorName": "default:string",
        "refrigerationUnits": "default:string",
        "fieldAssistDefaultTrades": "default:strings",
    ]

    /// One setting against the allow-list and the direction it may move.
    public static func checkSetting(_ key: String, _ setting: Setting) throws {
        guard let kind = allowList[key] else { throw Invalid(message: "\(key) is not a setting a profile may set (see SettingKey)") }
        let parts = kind.split(separator: ":").map(String.init)
        switch parts[0] {
        case "owned":
            if setting.value.typeName != parts[1] { throw Invalid(message: "\(key) takes a \(parts[1])") }
        case "ceiling":
            guard setting.disposition == "ceiling" else { throw Invalid(message: "\(key) may only be a ceiling") }
            guard case .bool(let flag) = setting.value else { throw Invalid(message: "\(key) takes a bool") }
            if String(flag) != parts[1] { throw Invalid(message: "\(key) may only be pinned to \(parts[1])") }
        default:
            guard setting.disposition == "default" else { throw Invalid(message: "\(key) may only be a default") }
            if setting.value.typeName != parts[1] { throw Invalid(message: "\(key) takes a \(parts[1])") }
        }
        if key == "organizationManualSearchModel", case .string(let model) = setting.value,
           !knownManualSearchModels.contains(model) {
            throw Invalid(message: "organizationManualSearchModel is \(model), which is not one of \(knownManualSearchModels.sorted().joined(separator: ", "))")
        }
        if key == "fieldAssistDefaultTrades", case .strings(let trades) = setting.value {
            for trade in trades where !knownTrades.contains(trade) {
                throw Invalid(message: "fieldAssistDefaultTrades names \(trade), which is not a trade (\(knownTrades.sorted().joined(separator: ", ")))")
            }
        }
        if key == "organizationJobSigningKey", case .string(let text) = setting.value {
            guard let data = Data(base64Encoded: text), (try? Curve25519.Signing.PublicKey(rawRepresentation: data)) != nil else {
                throw Invalid(message: "organizationJobSigningKey is not a Curve25519 public key (use make-job-file.swift keygen)")
            }
        }
    }

    public static func checkAIModel(_ model: AIModel) throws {
        guard knownProviders.contains(model.provider) else {
            throw Invalid(message: "aiModel.provider \(model.provider) is not one of \(knownProviders.sorted().joined(separator: ", "))")
        }
        if model.model.trimmingCharacters(in: .whitespaces).isEmpty { throw Invalid(message: "aiModel.model is empty") }
        if let base = model.baseURL {
            guard ["custom", "openrouter"].contains(model.provider) else { throw Invalid(message: "aiModel.baseURL is only for custom and openrouter") }
            guard let url = URL(string: base), url.scheme?.lowercased() == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.fragment == nil else {
                throw Invalid(message: "aiModel.baseURL must be https with no credentials or fragment")
            }
        } else if model.provider == "custom" {
            throw Invalid(message: "a custom aiModel needs its baseURL")
        }
    }

    /// Refuses rather than letting the phone drop an entry: an organisation should find out here, not at enrolment.
    public static func check(_ input: Input, adminPasscode: Bool, now: Date) throws {
        if !(7...365).contains(input.leaseDays) { throw Invalid(message: "leaseDays must be 7–365 (got \(input.leaseDays))") }
        for (field, days) in [("eraseAfterLapseDays", input.eraseAfterLapseDays), ("undeliveredEraseDays", input.undeliveredEraseDays)] {
            if let days, !(1...365).contains(days) { throw Invalid(message: "\(field) must be 1–365 (got \(days))") }
        }
        if input.organizationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw Invalid(message: "organizationName is empty") }
        if let expiry = input.policyExpiry {
            guard let date = ISO8601DateFormatter().date(from: expiry) else {
                throw Invalid(message: "policyExpiry is not ISO 8601 (e.g. 2027-09-30T00:00:00Z)")
            }
            if date < now { throw Invalid(message: "policyExpiry is in the past") }
        }
        if let edition = input.edition, edition != "fieldAssist" {
            throw Invalid(message: "edition \(edition) is not one this app knows (fieldAssist)")
        }
        if let card = input.adminCard, card.count != 64 || !card.allSatisfy({ $0.isHexDigit }) {
            throw Invalid(message: "adminCard must be the 64-character digest `admin-card` printed")
        }
        if input.edition == nil && (input.adminCard != nil || adminPasscode) {
            throw Invalid(message: "an admin card or passcode only applies with an edition")
        }
        if let lockdown = input.lockdown {
            if input.edition == nil { throw Invalid(message: "a lockdown only applies with an edition") }
            for id in (lockdown.open ?? []) + (lockdown.lock ?? []) where !settingsCategoryIds.contains(id) {
                throw Invalid(message: "lockdown names \(id), which is not a settings category (\(settingsCategoryIds.joined(separator: ", ")))")
            }
            for id in lockdown.lock ?? [] where pinnedOpenCategoryIds.contains(id) {
                throw Invalid(message: "\(id) is never locked by an organisation")
            }
            for tool in lockdown.closedTools ?? [] {
                guard !tool.isEmpty, tool.count <= 64,
                      tool.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }) else {
                    throw Invalid(message: "lockdown.closedTools: \(tool) is not a tool name")
                }
            }
        }
        if let authority = input.officeAuthority {
            guard isSafeIdentifier(authority.organizationID),
                  ["privateLan", "automatic"].contains(authority.transportPolicy),
                  let key = Data(base64Encoded: authority.administratorPublicKey), key.count == 32,
                  key.base64EncodedString() == authority.administratorPublicKey,
                  (try? Curve25519.Signing.PublicKey(rawRepresentation: key)) != nil else {
                throw Invalid(message: "officeAuthority needs a safe organizationID, a 32-byte signing public key and privateLan/automatic policy")
            }
        }
        if let model = input.aiModel { try checkAIModel(model) }
        if let boxes = input.credentials { try Credential.checkBoxes(boxes) }
        if let vaults = input.companyVaults { try checkCompanyVaults(vaults) }
        for (key, setting) in input.settings ?? [:] { try checkSetting(key, setting) }
    }

    /// The company vault pointer: an HTTPS catalog address, a generation of 1 or more, and a
    /// positive `minAppBuild` when there is one.
    public static func checkCompanyVaults(_ vaults: CompanyVaults) throws {
        guard CompanyVaultContract.isDownloadURL(vaults.catalog) else {
            throw Invalid(message: "companyVaults.catalog must be an https address with no credentials or fragment")
        }
        guard vaults.generation >= 1 else { throw Invalid(message: "companyVaults.generation must be 1 or more") }
        if let build = vaults.minAppBuild, build < 1 { throw Invalid(message: "companyVaults.minAppBuild must be positive") }
    }

    /// The office's organisation identifier rule: 1–80 of `A-Z a-z 0-9 - _ .`, never `.` or `..`.
    public static func isSafeIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 80 && id != "." && id != ".."
            && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }
    }

    public static func document(_ input: Input, keyId: String, issued: Date, adminPasscode: PasscodeVerifier?) -> Document {
        Document(format: "openglasses.org-profile", schemaVersion: input.officeAuthority == nil ? 1 : 2, keyId: keyId,
                 profileId: input.profileId, organizationName: input.organizationName, issued: issued,
                 policyExpiry: input.policyExpiry.flatMap { ISO8601DateFormatter().date(from: $0) },
                 leaseDays: input.leaseDays, eraseAfterLapseDays: input.eraseAfterLapseDays,
                 undeliveredEraseDays: input.undeliveredEraseDays, licenceCode: input.licenceCode,
                 vaultPack: input.vaultPack, skillPacks: input.skillPacks, revokedEnrolmentIds: input.revokedEnrolmentIds,
                 aiModel: input.aiModel, edition: input.edition, adminPasscode: adminPasscode,
                 adminCard: input.adminCard?.lowercased(), lockdown: input.lockdown,
                 officeAuthority: input.officeAuthority, credentials: input.credentials,
                 companyVaults: input.companyVaults, settings: input.settings ?? [:])
    }
}
