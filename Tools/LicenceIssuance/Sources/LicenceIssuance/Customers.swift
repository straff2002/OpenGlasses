import Foundation

/// JS P0b — a vendor-authored, versioned template of everything a customer's profile carries apart from the licence.
/// A partner only picks among `choices`; it never writes a rule (Plan CT decision 1: profiles are issued by the vendor).
public struct ProfilePreset: Codable, Equatable {
    public let id: String
    public let version: Int
    public var edition: String?
    public var leaseDays: Int
    public var eraseAfterLapseDays: Int?
    public var lockdown: ProfileContract.Lockdown?
    /// Settings every customer on this preset carries, as the vendor wrote them.
    public var settings: [String: ProfileContract.Setting]
    public var choices: Choices
    public struct Choices: Codable, Equatable {
        public var vaultPacks: [PackOption]
        public var aiModels: [ProfileContract.AIModel]
        public var settings: [String: SettingOption]
        public init(vaultPacks: [PackOption] = [], aiModels: [ProfileContract.AIModel] = [], settings: [String: SettingOption] = [:]) {
            self.vaultPacks = vaultPacks; self.aiModels = aiModels; self.settings = settings
        }
    }
    /// A vault pack the profile may install. `licensePack` is its resale key, which must be in the partner's grant.
    public struct PackOption: Codable, Equatable {
        public let packId: String; public let documentsSource: String?; public let licensePack: String
        public init(packId: String, documentsSource: String? = nil, licensePack: String) {
            self.packId = packId; self.documentsSource = documentsSource; self.licensePack = licensePack
        }
    }
    public struct SettingOption: Codable, Equatable {
        public let disposition: String; public let values: [ProfileContract.Value]
        public init(disposition: String, values: [ProfileContract.Value]) { self.disposition = disposition; self.values = values }
    }
    public init(id: String, version: Int, edition: String? = nil, leaseDays: Int, eraseAfterLapseDays: Int? = nil,
                lockdown: ProfileContract.Lockdown? = nil, settings: [String: ProfileContract.Setting] = [:], choices: Choices = Choices()) {
        self.id = id; self.version = version; self.edition = edition; self.leaseDays = leaseDays
        self.eraseAfterLapseDays = eraseAfterLapseDays; self.lockdown = lockdown; self.settings = settings; self.choices = choices
    }
    /// Recorded on the customer, so an edited preset kept under the same version is refused rather than applied silently.
    public func digest() throws -> String { IssuanceWire.digest(try IssuanceWire.encoder(profile: true).encode(self)) }

    public func validate() throws {
        func invalid(_ message: String) -> PresetRefusal { .invalidPreset(message) }
        guard ProfileContract.isSafeIdentifier(id), version > 0 else { throw invalid("a preset needs a safe id and a positive version") }
        // A profile lease shorter than 60 days could lapse before an unpaid licence does, and a lease lapse erases.
        guard (60...365).contains(leaseDays) else { throw invalid("leaseDays must be 60–365 (got \(leaseDays))") }
        do {
            for (key, setting) in settings { try ProfileContract.checkSetting(key, setting) }
            for (key, option) in choices.settings {
                guard settings[key] == nil else { throw invalid("\(key) is both fixed and a choice") }
                guard !option.values.isEmpty, option.values.indices.allSatisfy({ i in !option.values[..<i].contains(option.values[i]) }) else {
                    throw invalid("\(key) needs one or more distinct values")
                }
                for value in option.values { try ProfileContract.checkSetting(key, .init(value: value, disposition: option.disposition)) }
            }
            for (i, model) in choices.aiModels.enumerated() {
                try ProfileContract.checkAIModel(model)
                guard !Self.carriesKey(model) else { throw PresetRefusal.aiModelCarriesKey }
                guard !choices.aiModels[..<i].contains(model) else { throw invalid("an AI model is listed twice") }
            }
            for (i, pack) in choices.vaultPacks.enumerated() {
                guard !pack.packId.isEmpty, !pack.licensePack.isEmpty, !choices.vaultPacks[..<i].contains(where: { $0.packId == pack.packId }) else {
                    throw invalid("each vault pack needs a distinct packId and its licensePack")
                }
            }
            try ProfileContract.check(.init(profileId: id, organizationName: id, leaseDays: leaseDays, eraseAfterLapseDays: eraseAfterLapseDays,
                                            settings: settings, edition: edition, lockdown: lockdown), adminPasscode: false, now: .distantPast)
        } catch let invalid as ProfileContract.Invalid { throw PresetRefusal.invalidPreset(invalid.message) }
    }

    /// The profile input for one customer: the preset plus the partner's choices, refusing any value the preset does not list.
    public func input(profileId: String, organizationName: String, selection: PresetSelection, grant: PartnerGrant,
                      licenceCode: String?, adminPasscode: Bool) throws -> ProfileContract.Input {
        try validate()
        var chosen = settings
        for (key, value) in selection.settings {
            guard let option = choices.settings[key] else { throw PresetRefusal.settingNotOffered(key) }
            guard option.values.contains(value) else { throw PresetRefusal.valueNotOffered(key) }
            chosen[key] = .init(value: value, disposition: option.disposition)
        }
        var vaultPack: ProfileContract.VaultPack?
        if let packId = selection.vaultPack {
            guard let pack = choices.vaultPacks.first(where: { $0.packId == packId }) else { throw PresetRefusal.packNotOffered(packId) }
            guard grant.packs.contains(pack.licensePack) else { throw PresetRefusal.packNotInGrant(pack.licensePack) }
            vaultPack = .init(packId: pack.packId, documentsSource: pack.documentsSource)
        }
        if let model = selection.aiModel {
            guard !Self.carriesKey(model) else { throw PresetRefusal.aiModelCarriesKey }
            guard choices.aiModels.contains(model) else { throw PresetRefusal.aiModelNotOffered }
        }
        let input = ProfileContract.Input(profileId: profileId, organizationName: organizationName, leaseDays: leaseDays,
                                          eraseAfterLapseDays: eraseAfterLapseDays, licenceCode: licenceCode, vaultPack: vaultPack,
                                          settings: chosen, aiModel: selection.aiModel, edition: edition, lockdown: lockdown)
        do { try ProfileContract.check(input, adminPasscode: adminPasscode, now: .distantPast) }
        catch let invalid as ProfileContract.Invalid { throw PresetRefusal.invalidPreset(invalid.message) }
        return input
    }

    /// A model names a provider and a model, never a key: no query string, and nothing shaped like a secret.
    static func carriesKey(_ model: ProfileContract.AIModel) -> Bool {
        if let base = model.baseURL, URLComponents(string: base)?.query != nil { return true }
        let prefixes = ["sk-", "sk_", "xai-", "gsk_", "AIza", "ghp_"]
        return [model.model, model.name ?? "", model.baseURL ?? ""].contains { text in
            text.split(whereSeparator: { !($0.isLetter || $0.isNumber || "_-+=".contains($0)) }).contains { token in
                prefixes.contains { token.hasPrefix($0) }
                    || (token.count >= 32 && token.contains(where: \.isNumber) && token.contains(where: \.isLetter))
            }
        }
    }
}

/// What the partner picked within a preset. Nothing here is a rule.
public struct PresetSelection: Codable, Equatable {
    public var vaultPack: String?
    public var aiModel: ProfileContract.AIModel?
    public var settings: [String: ProfileContract.Value]
    public init(vaultPack: String? = nil, aiModel: ProfileContract.AIModel? = nil, settings: [String: ProfileContract.Value] = [:]) {
        self.vaultPack = vaultPack; self.aiModel = aiModel; self.settings = settings
    }
}

public enum PresetRefusal: Error, Equatable {
    case invalidPreset(String), unknownPreset, presetChanged
    case settingNotOffered(String), valueNotOffered(String), packNotOffered(String), packNotInGrant(String)
    case aiModelNotOffered, aiModelCarriesKey, invalidVerifier
}

extension ProfileContract {
    /// The app's `AdminSecrets.resolve`: a salt of 16 bytes or more, a 32-byte hash, iterations in range.
    public static func isAcceptable(_ verifier: PasscodeVerifier) -> Bool {
        guard let salt = Data(base64Encoded: verifier.salt), salt.count >= 16, salt.base64EncodedString() == verifier.salt,
              let hash = Data(base64Encoded: verifier.hash), hash.count == 32, hash.base64EncodedString() == verifier.hash else { return false }
        return passcodeIterationRange.contains(verifier.iterations)
    }
}

/// JS P0b — one company a partner signed up: one profile and one activation key for its whole life.
/// `licensee`, `organizationID`, `profileId` and `profileAddress` never change (the ledger refuses a row that does).
public struct Customer: Codable, Equatable {
    public let customerId: String
    /// Changes only when the vendor moves the customer to another partner.
    public var partnerId: String
    /// The exact name the phones show, and every code's `licensee`.
    public let licensee: String
    public let organizationID: String
    public let profileId: String
    /// Inside every code as its signed `profile` claim.
    public let profileAddress: String
    /// The sealed activation file's name. The key itself is never stored; only a rotation changes this.
    public var activationFile: String
    public var presetId: String
    public var presetVersion: Int
    public var presetDigest: String
    public var selection: PresetSelection
    /// Set by the company's own administrator through the setup link; nil until then (no administrator view).
    public var adminPasscode: ProfileContract.PasscodeVerifier?
}

public struct CustomerChange: Codable, Equatable {
    /// The record after the change.
    public let customer: Customer
    public let at: Date
    public let operatorId: String
    public let kind: Kind
    public enum Kind: Codable, Equatable {
        case preset, adminPasscode, partner
        /// The old file must be deleted from the public site; phones already enrolled renew from the profile.
        case keyRotated(retiredFile: String)
    }
}

/// What a partner enters to sign a company up.
public struct NewCustomer: Codable, Equatable {
    public var customerId: String
    public var licensee: String
    public var organizationID: String
    public var profileId: String
    public var selection: PresetSelection
    public init(customerId: String, licensee: String, organizationID: String, profileId: String, selection: PresetSelection = .init()) {
        self.customerId = customerId; self.licensee = licensee; self.organizationID = organizationID
        self.profileId = profileId; self.selection = selection
    }
}

/// An order for a customer. The licensee and profile come from the customer, never from the partner.
public struct CustomerOrder: Codable, Equatable {
    public var seats: Int
    public var termDays: Int
    public var packs: [String]
    public var plan: String
    public var reference: String
    /// Plan JS P2: mint the code with the signed `seatCheck` claim, so its phones are counted.
    public var seatCheck: Bool?
    public init(seats: Int, termDays: Int, packs: [String] = [], plan: String = "team", reference: String, seatCheck: Bool? = nil) {
        self.seats = seats; self.termDays = termDays; self.packs = packs; self.plan = plan; self.reference = reference
        self.seatCheck = seatCheck
    }
}

public enum CustomerRefusal: Error, Equatable {
    case invalidCustomer, customerExists, unknownCustomer, wrongPartner
    /// One live code per customer: a new code arrives as a renewal or a seat increase.
    case liveCodeExists
    /// An unpaid order is still open for this customer.
    case openOrder
    /// A seat increase co-terms with a paid code that has not expired.
    case noPaidLiveCode
    /// The code offered is not this customer's current one.
    case notCurrentCode
}

extension Ledger {
    /// Each customer as its latest row leaves it.
    public var customers: [String: Customer] {
        var all: [String: Customer] = [:]
        for row in entries {
            switch row.event {
            case .signUp(let c, _, _, _): all[c.customerId] = c
            case .customerChange(let change): all[change.customer.customerId] = change.customer
            default: break
            }
        }
        return all
    }
    public var customerChanges: [CustomerChange] { entries.compactMap { if case .customerChange(let c) = $0.event { return c }; return nil } }
    /// The code the customer's profile carries: its latest issuance, lapsed or not, so phones can say why they stopped.
    public func currentIssuance(for customerId: String) -> IssuanceRecord? {
        let ids = Set(orders.filter { $0.customerId == customerId }.map(\.id))
        return issuances.last { $0.orderId.map(ids.contains) == true }
    }
    public func retiredActivationFiles(for customerId: String) -> [String] {
        customerChanges.compactMap { change in
            guard change.customer.customerId == customerId, case .keyRotated(let file) = change.kind else { return nil }
            return file
        }
    }
    func hasOpenOrder(_ customerId: String) -> Bool {
        let ids = Set(orders.filter { $0.customerId == customerId }.map(\.id))
        return invoices.contains { ids.contains($0.orderId) && balance($0) > 0 }
    }
}

public struct SignUp {
    public let customer: Customer
    public let code: IssuedCode
    /// Shown once, with its QR. Never stored.
    public let activationKey: String
    /// For the public activation directory under `customer.activationFile`.
    public let sealedFile: String
}

public struct KeyRotation {
    public let customer: Customer
    public let activationKey: String
    public let sealedFile: String
    /// To delete from the public site.
    public let retiredFile: String
}

extension SalesBook {
    /// `<base>/p/<profileId>`, the address every one of the customer's codes names.
    public static func profileAddress(base: String, profileId: String) throws -> String {
        guard ProfileContract.isSafeIdentifier(profileId), let url = URL(string: base), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw CustomerRefusal.invalidCustomer }
        return (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/p/" + profileId
    }

    private func customer(_ id: String, partner: PartnerGrant) throws -> Customer {
        guard let c = ledger.customers[id] else { throw CustomerRefusal.unknownCustomer }
        guard c.partnerId == partner.partnerId else { throw CustomerRefusal.wrongPartner }
        return c
    }

    private func checkPreset(_ preset: ProfilePreset, for c: Customer) throws {
        guard preset.id == c.presetId, preset.version == c.presetVersion else { throw PresetRefusal.unknownPreset }
        guard try preset.digest() == c.presetDigest else { throw PresetRefusal.presetChanged }
    }

    private mutating func record(_ customer: Customer, _ kind: CustomerChange.Kind, operatorId: String, now: Date) throws {
        guard !operatorId.isEmpty else { throw SalesError.invalidOrder }
        try ledger.append(.customerChange(CustomerChange(customer: customer, at: now, operatorId: operatorId, kind: kind)))
    }

    /// The customer record and its first order in one row. The first code is sealed under a new activation key,
    /// which every technician at the company uses for as long as it is a customer.
    public mutating func signUp(_ new: NewCustomer, orderId: String, order: CustomerOrder, preset: ProfilePreset, profileBase: String,
                                grant: PartnerGrant, catalog: VerifiedPackCatalog, bankDetails: String, operatorId: String,
                                now: Date, signer: ByteSigner) throws -> SignUp {
        guard ProfileContract.isSafeIdentifier(new.customerId), ProfileContract.isSafeIdentifier(new.organizationID),
              !new.licensee.isEmpty, new.licensee == new.licensee.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw CustomerRefusal.invalidCustomer
        }
        let address = try Self.profileAddress(base: profileBase, profileId: new.profileId)
        guard !ledger.customers.values.contains(where: { $0.customerId == new.customerId || $0.organizationID == new.organizationID }),
              !ledger.orders.contains(where: { $0.profileId == new.profileId || $0.request.profile == address }) else {
            throw CustomerRefusal.customerExists
        }
        _ = try preset.input(profileId: new.profileId, organizationName: new.licensee, selection: new.selection, grant: grant,
                             licenceCode: nil, adminPasscode: false)
        let request = IssuanceRequest(licensee: new.licensee, plan: order.plan, seats: order.seats, termDays: order.termDays,
                                      packs: order.packs, reference: order.reference, profile: address, seatCheck: order.seatCheck)
        let (sale, invoice, first) = try prepareOrder(id: orderId, request: request, grant: grant, catalog: catalog, profileId: new.profileId,
                                                      bankDetails: bankDetails, renewalOf: nil, customerId: new.customerId,
                                                      operatorId: operatorId, now: now, signer: signer)
        guard let first else { throw SalesError.invalidOrder }
        let key = ActivationKeyMint.generate()
        let sealed = try ActivationKeyMint.seal(first.code, canonical: key)
        let customer = Customer(customerId: new.customerId, partnerId: grant.partnerId, licensee: new.licensee,
                                organizationID: new.organizationID, profileId: new.profileId, profileAddress: address,
                                activationFile: ActivationKeyMint.fileName(key), presetId: preset.id, presetVersion: preset.version,
                                presetDigest: try preset.digest(), selection: new.selection, adminPasscode: nil)
        try ledger.append(.signUp(customer, sale, invoice, first.record))
        return SignUp(customer: customer, code: first, activationKey: ActivationKeyMint.display(key), sealedFile: sealed)
    }

    /// A later order for a customer: a renewal of its current code, or a fresh order once that code has lapsed.
    @discardableResult public mutating func order(id: String, customerId: String, order: CustomerOrder, renewalOf: String? = nil,
                                                  grant: PartnerGrant, catalog: VerifiedPackCatalog, bankDetails: String,
                                                  operatorId: String, now: Date, signer: ByteSigner) throws -> IssuedCode? {
        let c = try customer(customerId, partner: grant)
        guard !ledger.hasOpenOrder(customerId) else { throw CustomerRefusal.openOrder }
        let current = ledger.currentIssuance(for: customerId)
        if let renewalOf {
            // Renewing anything but the current code would branch the customer into two codes.
            guard current?.orderId == renewalOf else { throw SalesError.invalidRenewal }
        } else if let current, current.expires > now {
            throw CustomerRefusal.liveCodeExists
        }
        let request = IssuanceRequest(licensee: c.licensee, plan: order.plan, seats: order.seats, termDays: order.termDays,
                                      packs: order.packs, reference: order.reference, profile: c.profileAddress,
                                      seatCheck: order.seatCheck)
        let (sale, invoice, issued) = try prepareOrder(id: id, request: request, grant: grant, catalog: catalog, profileId: c.profileId,
                                                       bankDetails: bankDetails, renewalOf: renewalOf, customerId: customerId,
                                                       operatorId: operatorId, now: now, signer: signer)
        try ledger.append(.sale(sale, invoice, issued?.record)); return issued
    }

    /// Co-termed: on payment the customer's code is replaced by one with the total seats and the same expiry.
    /// Invoiced by day for the whole days left on the live code (a part day counts), rounded half up to the minor unit.
    public mutating func increaseSeats(id: String, customerId: String, additionalSeats: Int, grant: PartnerGrant,
                                       catalog: VerifiedPackCatalog, bankDetails: String, operatorId: String, now: Date) throws {
        let c = try customer(customerId, partner: grant)
        guard !id.isEmpty, !operatorId.isEmpty, !bankDetails.isEmpty, additionalSeats > 0,
              !ledger.orders.contains(where: { $0.id == id }) else { throw SalesError.invalidOrder }
        guard !ledger.hasOpenOrder(customerId) else { throw CustomerRefusal.openOrder }
        guard let live = ledger.currentIssuance(for: customerId), live.phase == .full, live.expires > now,
              let liveOrder = ledger.orders.first(where: { $0.id == live.orderId }), let term = liveOrder.request.termDays else {
            throw CustomerRefusal.noPaidLiveCode
        }
        let (total, overflow) = live.seats.addingReportingOverflow(additionalSeats)
        guard !overflow, total <= grant.maxSeatsPerCode else { throw IssuanceRefusal.seatsPerCodeExceeded(grant.maxSeatsPerCode) }
        // A seat increase keeps the live code's seat check: more seats, counted the same way.
        let request = IssuanceRequest(licensee: c.licensee, seats: additionalSeats, termDays: term, packs: live.packs,
                                      reference: id, profile: c.profileAddress, seatCheck: liveOrder.request.seatCheck)
        _ = try IssuancePolicy.validate(request, grant: grant, ledger: ledger, catalog: catalog, now: now).get()
        guard !grant.prices.currency.isEmpty, !grant.prices.taxTreatment.isEmpty,
              let unit = grant.prices.perSeatByTermDays[term], unit > 0 else { throw IssuanceRefusal.missingPrice }
        let days = Int((live.expires.timeIntervalSince(now) / IssuancePolicy.day).rounded(.up))
        let (perSeat, o1) = unit.multipliedReportingOverflow(by: Int64(days))
        let (full, o2) = perSeat.multipliedReportingOverflow(by: Int64(additionalSeats))
        let (doubled, o3) = full.multipliedReportingOverflow(by: 2)
        guard !o1, !o2, !o3 else { throw IssuanceRefusal.invalidRequest }
        let amount = (doubled + Int64(term)) / (2 * Int64(term))
        guard amount > 0 else { throw IssuanceRefusal.invalidRequest }
        let order = Order(id: id, partnerId: grant.partnerId, grantVersion: grant.version, issuedAt: now, grant: grant, request: request,
                          profileId: c.profileId, fullExpiry: live.expires, renewalOf: nil, customerId: customerId, increaseOf: live.issuanceId)
        let invoice = Invoice(number: Ledger.invoiceNumber(ledger.invoices.count + 1), orderId: id, partnerId: grant.partnerId,
                              issuedAt: now, dueAt: now.addingTimeInterval(30 * IssuancePolicy.day), seats: additionalSeats,
                              termDays: term, unitMinor: unit, totalMinor: amount, currency: grant.prices.currency,
                              taxTreatment: grant.prices.taxTreatment, bankDetails: bankDetails, coTermedDays: days)
        try ledger.append(.sale(order, invoice, nil))
    }

    /// A new preset version, or new choices, reach a customer only through this.
    public mutating func changePreset(customerId: String, to preset: ProfilePreset, selection: PresetSelection, grant: PartnerGrant,
                                      operatorId: String, now: Date) throws {
        var c = try customer(customerId, partner: grant)
        _ = try preset.input(profileId: c.profileId, organizationName: c.licensee, selection: selection, grant: grant,
                             licenceCode: nil, adminPasscode: c.adminPasscode != nil)
        c.presetId = preset.id; c.presetVersion = preset.version; c.presetDigest = try preset.digest(); c.selection = selection
        try record(c, .preset, operatorId: operatorId, now: now)
    }

    /// The verifier the administrator's browser derived. The passcode itself never reaches the service.
    public mutating func setAdminPasscode(customerId: String, verifier: ProfileContract.PasscodeVerifier, preset: ProfilePreset,
                                          grant: PartnerGrant, operatorId: String, now: Date) throws {
        var c = try customer(customerId, partner: grant)
        try checkPreset(preset, for: c)
        guard ProfileContract.isAcceptable(verifier) else { throw PresetRefusal.invalidVerifier }
        _ = try preset.input(profileId: c.profileId, organizationName: c.licensee, selection: c.selection, grant: grant,
                             licenceCode: nil, adminPasscode: true)
        c.adminPasscode = verifier
        try record(c, .adminPasscode, operatorId: operatorId, now: now)
    }

    /// Vendor console only: the partner a customer belongs to.
    public mutating func moveCustomer(customerId: String, toPartner partnerId: String, operatorId: String, now: Date) throws {
        guard var c = ledger.customers[customerId] else { throw CustomerRefusal.unknownCustomer }
        guard !partnerId.isEmpty, partnerId != c.partnerId else { throw CustomerRefusal.invalidCustomer }
        c.partnerId = partnerId
        try record(c, .partner, operatorId: operatorId, now: now)
    }

    /// A lost or leaked key: a new key sealing the current code, and the old file listed for deletion.
    public mutating func rotateActivationKey(customerId: String, currentCode: String, operatorId: String, now: Date) throws -> KeyRotation {
        guard var c = ledger.customers[customerId] else { throw CustomerRefusal.unknownCustomer }
        guard ledger.currentIssuance(for: customerId)?.licenseDigest == IssuanceWire.digest(Data(currentCode.utf8)) else {
            throw CustomerRefusal.notCurrentCode
        }
        let key = ActivationKeyMint.generate()
        let sealed = try ActivationKeyMint.seal(currentCode, canonical: key)
        let retired = c.activationFile
        c.activationFile = ActivationKeyMint.fileName(key)
        try record(c, .keyRotated(retiredFile: retired), operatorId: operatorId, now: now)
        return KeyRotation(customer: c, activationKey: ActivationKeyMint.display(key), sealedFile: sealed, retiredFile: retired)
    }

    /// The customer's profile input with its current code — the same input `make-org-profile make` takes.
    public func profileInput(customerId: String, code: String, preset: ProfilePreset, grant: PartnerGrant) throws -> ProfileContract.Input {
        guard let c = ledger.customers[customerId] else { throw CustomerRefusal.unknownCustomer }
        try checkPreset(preset, for: c)
        guard ledger.currentIssuance(for: customerId)?.licenseDigest == IssuanceWire.digest(Data(code.utf8)) else {
            throw CustomerRefusal.notCurrentCode
        }
        return try preset.input(profileId: c.profileId, organizationName: c.licensee, selection: c.selection, grant: grant,
                                licenceCode: code, adminPasscode: c.adminPasscode != nil)
    }

    /// The signed profile to publish at the customer's address. Pass a whole-second `issued`, as the manual tool does.
    public func profileDocument(customerId: String, code: String, preset: ProfilePreset, grant: PartnerGrant,
                                keyID: String, issued: Date, signer: ByteSigner) throws -> String {
        let input = try profileInput(customerId: customerId, code: code, preset: preset, grant: grant)
        guard !keyID.isEmpty else { throw IssuanceWire.WireError.invalidProfile }
        let document = ProfileContract.document(input, keyId: keyID, issued: issued, adminPasscode: ledger.customers[customerId]?.adminPasscode)
        return try IssuanceWire.profile(document, signer: signer)
    }
}
