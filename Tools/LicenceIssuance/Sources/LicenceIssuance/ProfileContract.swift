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
    /// makes; a phone also reads the catalog on every foreground, and never uses one older than
    /// this; `minAppBuild` is the oldest build that can read it (older builds ignore the field).
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
        /// Plan ND: rises with every re-sign of this `profileId`; the signer sets it
        /// (`nextGeneration(after:)`), never the person editing. Absent on profiles from before ND.
        public var profileGeneration: Int?
        /// Plan ND: what a person may choose when `aiModel` names none (`knownAssistantChoices`).
        /// Absent means the phone's full provider list, as before ND.
        public var aiChoices: [String]?
        public init(profileId: String, organizationName: String, leaseDays: Int, policyExpiry: String? = nil,
                    eraseAfterLapseDays: Int? = nil, undeliveredEraseDays: Int? = nil, licenceCode: String? = nil,
                    vaultPack: VaultPack? = nil, skillPacks: [String]? = nil, revokedEnrolmentIds: [String]? = nil,
                    settings: [String: Setting]? = nil, aiModel: AIModel? = nil, edition: String? = nil,
                    adminCard: String? = nil, lockdown: Lockdown? = nil, officeAuthority: OfficeAuthority? = nil,
                    credentials: [String: String]? = nil, companyVaults: CompanyVaults? = nil,
                    profileGeneration: Int? = nil, aiChoices: [String]? = nil) {
            self.profileId = profileId; self.organizationName = organizationName; self.leaseDays = leaseDays
            self.policyExpiry = policyExpiry; self.eraseAfterLapseDays = eraseAfterLapseDays
            self.undeliveredEraseDays = undeliveredEraseDays; self.licenceCode = licenceCode; self.vaultPack = vaultPack
            self.skillPacks = skillPacks; self.revokedEnrolmentIds = revokedEnrolmentIds; self.settings = settings
            self.aiModel = aiModel; self.edition = edition; self.adminCard = adminCard; self.lockdown = lockdown
            self.officeAuthority = officeAuthority; self.credentials = credentials
            self.companyVaults = companyVaults
            self.profileGeneration = profileGeneration; self.aiChoices = aiChoices
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
        /// Plan ND. Optional and omitted when nil, like `companyVaults`.
        public let profileGeneration: Int?
        /// Plan ND. Optional and omitted when nil.
        public let aiChoices: [String]?
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

    /// SettingKey, by kind — every case, in SettingKey's order. "owned" ignores the disposition;
    /// "ceiling:<Bool>" may only be pinned that way; "stringCeiling:<String>" may only be pinned to that
    /// string; "default:<type>" is a starting value. `ProfileContractParityTests` (in the app's test bundle)
    /// fails on any key, kind or direction that differs from the app.
    public static let allowList: [String: String] = [
        // Organisation identity
        "organizationFieldServiceRoute": "stringCeiling:office",
        "workizEnabled": "owned:bool",
        "workizReportFieldName": "owned:string",
        "workizClientNotes": "owned:bool",
        "organizationDisplayName": "owned:string",
        "organizationJobSigningKey": "owned:string",
        "organizationJobReportChannel": "owned:string",
        "organizationReportRecipients": "owned:strings",
        "organizationReportTranscriptInternal": "owned:string",
        "capturedManualsPolicy": "owned:string",
        "organizationAccentColor": "owned:string",
        "technicianFullName": "owned:string",
        "technicianID": "owned:string",
        "technicianDisplayName": "owned:string",
        "organizationToolDefinitionsMode": "owned:string",
        "organizationManualSearchModel": "owned:string",
        "organizationExperts": "owned:string",
        "expertHandoverTranscript": "owned:string",
        "expertHandoverIncludesAddress": "owned:bool",
        "expertHandoverRetentionDays": "owned:string",
        "customerReportShowsExpertTime": "owned:bool",
        // Organisation policy — tighten only
        "organizationAllowsUnsignedVaults": "ceiling:false",
        "organizationRequiresSignedJobFiles": "ceiling:true",
        "organizationRequiresCustomerSignOff": "ceiling:true",
        "organizationForbidsCustomerTranscript": "ceiling:true",
        "organizationForbidsJobRecording": "ceiling:true",
        "organizationForbidsVanStock": "ceiling:true",
        "organizationStockPlace": "owned:string",
        "organizationStockClinical": "owned:bool",
        "stockSystemEnabled": "owned:bool",
        "stockSystemConnector": "owned:string",
        "stockSystemSendBack": "owned:bool",
        "stockSystemAdjustmentReason": "owned:string",
        "organizationForbidsAddOns": "ceiling:true",
        "organizationForbidsCommunityAddOns": "ceiling:true",
        "organizationAllowsOnlyOrganisationAddOns": "ceiling:true",
        "organizationForbidsSelfBuiltAddOns": "ceiling:true",
        "organizationRequiresBlurBeforeOfficeSync": "ceiling:true",
        "organizationForbidsRecordingSyncOnCellular": "ceiling:true",
        "organizationRequiresTableChecks": "ceiling:true",
        "organizationRunsProceduresWithoutAssistant": "ceiling:true",
        // Capability ceilings — tighten only
        "privacyFilterEnabled": "ceiling:true",
        "remoteInvokeObserveEnabled": "ceiling:false",
        "remoteInvokeOutputEnabled": "ceiling:false",
        "remoteInvokeCaptureEnabled": "ceiling:false",
        "mcpServerEnabled": "ceiling:false",
        "agentModeEnabled": "ceiling:false",
        "interpreterEnabled": "ceiling:false",
        "instantReplayEnabled": "ceiling:false",
        "aiConnectionCueEnabled": "ceiling:true",
        "teamLearningReviewerDevice": "ceiling:false",
        "cloudDictationEnabled": "ceiling:false",
        "preparedCardCustomerTexts": "ceiling:false",
        "conversationDigestsEnabled": "ceiling:false",
        "privateConversationsAllowed": "ceiling:false",
        // Starting values the person may change
        "fieldAssistEnabled": "default:bool",
        "fieldAssistDefaultVaultId": "default:string",
        "fieldAssistDefaultMode": "default:string",
        "pilotReportsEnabled": "default:bool",
        "pilotReportRecipients": "default:strings",
        "supportReportEmail": "default:string",
        "accentColorName": "default:string",
        "refrigerationUnits": "default:string",
        "fieldAssistDefaultTrades": "default:strings",
    ]

    // MARK: - Plan ND — what a company's administrator may edit

    /// The settings a company's administrator may set in the portal: every starting value and the company's
    /// own values. Never a ceiling (they only subtract, and some protect the wearer or a bystander), never a
    /// key (`organizationJobSigningKey` decides which job files a phone trusts), never an engineering setting
    /// (`organizationToolDefinitionsMode`), and never a per-person value (`technician*`), which on a
    /// company-wide profile would name every technician after one person. A preset may narrow this, never
    /// widen it.
    public static let administratorEditableSettings: Set<String> = [
        // starting values
        "fieldAssistEnabled", "fieldAssistDefaultVaultId", "fieldAssistDefaultMode", "pilotReportsEnabled",
        "pilotReportRecipients", "supportReportEmail", "accentColorName", "refrigerationUnits", "fieldAssistDefaultTrades",
        // the company's own values
        "organizationDisplayName", "organizationJobReportChannel", "organizationReportRecipients",
        "organizationReportTranscriptInternal", "organizationAccentColor", "organizationExperts",
        "expertHandoverTranscript", "expertHandoverIncludesAddress", "expertHandoverRetentionDays",
        "customerReportShowsExpertTime", "capturedManualsPolicy", "organizationManualSearchModel",
        "organizationStockPlace", "organizationStockClinical", "stockSystemEnabled", "stockSystemConnector",
        "stockSystemSendBack", "stockSystemAdjustmentReason", "workizEnabled", "workizReportFieldName",
        "workizClientNotes",
    ]

    /// The top-level profile fields an administrator's edit may change, besides `settings` (checked key by key
    /// against `administratorEditableSettings`). Everything else is the vendor's or the signer's.
    public static let administratorEditableFields: Set<String> = ["aiModel", "aiChoices", "lockdown.open", "lockdown.lock"]

    /// What a person may pick when the profile pins no model: their own ChatGPT sign-in, or a model that runs
    /// on the phone. `LLMProvider` raw values; never a provider that needs a key typed.
    public static let knownAssistantChoices: Set<String> = ["chatgpt", "local", "appleOnDevice"]

    /// The generation a re-sign of `previous` carries: one more, never reused. A profile from before ND
    /// (no generation) re-signs as 1.
    public static func nextGeneration(after previous: Int?) -> Int { (previous ?? 0) + 1 }

    /// Refuses an administrator's edit that changes anything outside `administratorEditableFields` and
    /// `administratorEditableSettings`. The signer runs this against the input in force, then `check`, then
    /// sets `profileGeneration` with `nextGeneration(after:)`. A preset's own narrower list is the service's.
    public static func checkAdministratorEdit(from before: Input, to after: Input) throws {
        func vendorOnly(_ field: String) -> Invalid {
            Invalid(message: "\(field) is set by the vendor, not the company's administrator")
        }
        if before.profileId != after.profileId { throw vendorOnly("profileId") }
        if before.organizationName != after.organizationName { throw vendorOnly("organizationName") }
        if before.leaseDays != after.leaseDays { throw vendorOnly("leaseDays") }
        if before.policyExpiry != after.policyExpiry { throw vendorOnly("policyExpiry") }
        if before.eraseAfterLapseDays != after.eraseAfterLapseDays { throw vendorOnly("eraseAfterLapseDays") }
        if before.undeliveredEraseDays != after.undeliveredEraseDays { throw vendorOnly("undeliveredEraseDays") }
        if before.licenceCode != after.licenceCode { throw vendorOnly("licenceCode") }
        if before.vaultPack != after.vaultPack { throw vendorOnly("vaultPack") }
        if before.skillPacks != after.skillPacks { throw vendorOnly("skillPacks") }
        if before.revokedEnrolmentIds != after.revokedEnrolmentIds { throw vendorOnly("revokedEnrolmentIds") }
        if before.edition != after.edition { throw vendorOnly("edition") }
        if before.adminCard != after.adminCard { throw vendorOnly("adminCard") }
        if before.officeAuthority != after.officeAuthority { throw vendorOnly("officeAuthority") }
        if before.credentials != after.credentials { throw vendorOnly("credentials") }
        if before.companyVaults != after.companyVaults { throw vendorOnly("companyVaults") }
        if before.profileGeneration != after.profileGeneration { throw vendorOnly("profileGeneration") }
        if (before.lockdown == nil) != (after.lockdown == nil) { throw vendorOnly("lockdown") }
        if before.lockdown?.closedTools != after.lockdown?.closedTools { throw vendorOnly("lockdown.closedTools") }
        let old = before.settings ?? [:], new = after.settings ?? [:]
        for key in Set(old.keys).union(new.keys).sorted() where old[key] != new[key] {
            guard administratorEditableSettings.contains(key) else {
                throw Invalid(message: "\(key) is set by the vendor's preset, not the company's administrator")
            }
        }
    }

    /// Keys whose value only the phone can judge: it depends on what is installed there (a vault id) or on
    /// rules the contract does not repeat (the expert list's codec, a technician's name and ID, address
    /// plausibility). The signer checks their type and direction; the phone names a value it cannot use.
    public static let phoneCheckedSettings: Set<String> = [
        "organizationExperts", "technicianFullName", "technicianDisplayName", "technicianID",
        "fieldAssistDefaultVaultId", "supportReportEmail", "pilotReportRecipients",
    ]

    /// The values the app's enumerations accept, mirrored. Each is checked against the app's own type in
    /// `ProfileContractParityTests`.
    public static let knownDeliveryChannels: Set<String> = ["email", "messages", "whatsapp", "telegram", "share_sheet", "endpoint"]
    public static let knownToolDefinitionsModes: Set<String> = ["automatic", "always", "never"]
    public static let knownExpertTranscriptRules: Set<String> = ["include", "ask", "never"]
    public static let knownInternalTranscriptRules: Set<String> = ["always", "never"]
    public static let knownStockPlaces: Set<String> = ["van", "truck", "store", "warehouse", "stock"]
    public static let knownStockConnectors: Set<String> = ["square"]
    public static let knownStockAdjustmentReasons: Set<String> = ["internal_use", "waste", "damage"]
    public static let knownCapturedManualsPolicies: Set<String> = ["off", "jobOnly", "reviewToPool"]
    public static let knownFieldAssistModes: Set<String> = ["ai_only", "human_assisted"]

    /// Why a value of the right type is refused, or nil. At least as strict as the app's
    /// `SettingKey.contentProblem` for every key outside `phoneCheckedSettings`, so the portal refuses
    /// what a phone would drop (CT: an organisation should find out here, not at enrolment).
    public static func contentProblem(_ key: String, _ value: Value) -> String? {
        func printable(_ text: String) -> Bool {
            !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        func oneOf(_ known: Set<String>, _ text: String) -> String? {
            known.contains(text) ? nil : "\(key) is \(text), which is not one of \(known.sorted().joined(separator: ", "))"
        }
        switch (key, value) {
        case ("workizReportFieldName", .string(let name)):
            return name.isEmpty || name.count > 120 || !printable(name) ? "\(key) must be 1–120 printable characters" : nil
        case ("organizationDisplayName", .string(let name)):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.count > 120 ? "\(key) must be 1–120 characters" : nil
        case ("organizationJobReportChannel", .string(let raw)): return oneOf(knownDeliveryChannels, raw)
        case ("organizationToolDefinitionsMode", .string(let raw)): return oneOf(knownToolDefinitionsModes, raw)
        case ("organizationManualSearchModel", .string(let raw)): return oneOf(knownManualSearchModels, raw)
        case ("expertHandoverTranscript", .string(let raw)): return oneOf(knownExpertTranscriptRules, raw)
        case ("organizationReportTranscriptInternal", .string(let raw)): return oneOf(knownInternalTranscriptRules, raw)
        case ("organizationStockPlace", .string(let raw)): return oneOf(knownStockPlaces, raw)
        case ("stockSystemConnector", .string(let raw)): return oneOf(knownStockConnectors, raw)
        case ("stockSystemAdjustmentReason", .string(let raw)): return oneOf(knownStockAdjustmentReasons, raw)
        case ("capturedManualsPolicy", .string(let raw)): return oneOf(knownCapturedManualsPolicies, raw)
        case ("fieldAssistDefaultMode", .string(let raw)): return oneOf(knownFieldAssistModes, raw)
        case ("expertHandoverRetentionDays", .string(let raw)):
            guard !raw.isEmpty, raw.count <= 2, raw.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
                  let days = Int(raw), (1...30).contains(days) else { return "\(key) must be a whole number of days from 1 to 30" }
            return nil
        case ("organizationReportRecipients", .strings(let recipients)):
            if recipients.isEmpty || recipients.count > 20 { return "\(key) needs 1–20 recipients" }
            let bad = recipients.contains { $0.isEmpty || $0.count > 254 || $0.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || !printable($0) }
            return bad ? "\(key): a recipient is empty, too long, or contains whitespace" : nil
        case ("organizationAccentColor", .string(let colour)), ("accentColorName", .string(let colour)):
            let digits = colour.dropFirst()
            return colour.first == "#" && digits.count == 6 && digits.allSatisfy(\.isHexDigit) ? nil : "\(key) must be a colour written as #RRGGBB"
        case ("refrigerationUnits", .string(let raw)):
            let parts = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, ["kPa", "bar", "psi"].contains(parts[0]), ["C", "F"].contains(parts[1]),
                  ["kg", "lb"].contains(parts[2]) else { return "\(key) must be pressure,temperature,mass (for example kPa,C,kg)" }
            return nil
        default:
            return nil
        }
    }

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
        case "stringCeiling":
            guard setting.disposition == "ceiling" else { throw Invalid(message: "\(key) may only be a ceiling") }
            guard case .string(let text) = setting.value else { throw Invalid(message: "\(key) takes a string") }
            if text != parts[1] { throw Invalid(message: "\(key) may only be pinned to \(parts[1])") }
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
        if let problem = contentProblem(key, setting.value) { throw Invalid(message: problem) }
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

    /// The providers whose model works without a key: on the phone, or through the person's own sign-in.
    public static let keylessProviders: Set<String> = ["local", "appleOnDevice", "chatgpt", "geminiVertex"]

    /// Plan ND decision 9: a sealed `aiModel` credential is the key for the provider `aiModel` pins, so
    /// it means nothing without a pinned provider that takes a key.
    public static func checkSealedModelKey(pinned model: AIModel?) throws {
        guard let model else { throw Invalid(message: "credentials.aiModel needs aiModel to name the provider it is the key for") }
        if keylessProviders.contains(model.provider) {
            throw Invalid(message: "credentials.aiModel is a key, and aiModel.provider \(model.provider) takes none")
        }
    }

    /// Plan ND: the assistants a person may pick when the profile pins none.
    public static func checkAIChoices(_ choices: [String], pinnedModel: Bool) throws {
        if pinnedModel { throw Invalid(message: "aiChoices only applies when aiModel names no model") }
        if choices.isEmpty { throw Invalid(message: "aiChoices is empty; leave it out to offer the full list") }
        if Set(choices).count != choices.count { throw Invalid(message: "aiChoices names a choice twice") }
        for choice in choices where !knownAssistantChoices.contains(choice) {
            throw Invalid(message: "aiChoices names \(choice), which is not one of \(knownAssistantChoices.sorted().joined(separator: ", "))")
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
        if let generation = input.profileGeneration, generation < 1 {
            throw Invalid(message: "profileGeneration must be 1 or more (got \(generation))")
        }
        if let choices = input.aiChoices { try checkAIChoices(choices, pinnedModel: input.aiModel != nil) }
        if let boxes = input.credentials {
            try Credential.checkBoxes(boxes)
            if boxes["aiModel"] != nil { try checkSealedModelKey(pinned: input.aiModel) }
        }
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
                 companyVaults: input.companyVaults, profileGeneration: input.profileGeneration,
                 aiChoices: input.aiChoices, settings: input.settings ?? [:])
    }
}
