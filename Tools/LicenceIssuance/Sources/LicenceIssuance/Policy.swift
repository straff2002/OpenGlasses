import Foundation

public struct PriceTable: Codable, Equatable {
    public var currency: String
    public var taxTreatment: String
    /// Final invoice amounts in minor currency units, per seat; no floating point or implicit tax calculation.
    public var perSeatByTermDays: [Int: Int64]
    public init(currency: String, taxTreatment: String, perSeatByTermDays: [Int: Int64]) {
        self.currency = currency; self.taxTreatment = taxTreatment; self.perSeatByTermDays = perSeatByTermDays
    }
}
public struct PartnerGrant: Codable, Equatable {
    public var partnerId: String
    public var version: Int
    public var tiers: Set<String> = ["team"]
    public var packs: Set<String>
    public var maxTermDays: Int
    public var maxSeatsPerCode: Int
    public var seatQuota: Int
    public var pilotsAllowed: Bool
    public var maxPilotDays: Int
    public var validFrom: Date
    public var validUntil: Date
    public var prices: PriceTable
    public var maxUnpaidSeats: Int
    public init(partnerId: String, version: Int = 1, packs: Set<String>, maxTermDays: Int,
                maxSeatsPerCode: Int, seatQuota: Int, pilotsAllowed: Bool, maxPilotDays: Int,
                validFrom: Date, validUntil: Date, prices: PriceTable, maxUnpaidSeats: Int) {
        self.partnerId = partnerId; self.version = version; self.packs = packs; self.maxTermDays = maxTermDays
        self.maxSeatsPerCode = maxSeatsPerCode; self.seatQuota = seatQuota; self.pilotsAllowed = pilotsAllowed
        self.maxPilotDays = maxPilotDays; self.validFrom = validFrom; self.validUntil = validUntil
        self.prices = prices; self.maxUnpaidSeats = maxUnpaidSeats
    }
}
extension PartnerGrant {
    // Set iteration is process-randomized. Hash-chain bytes must survive decoding in another process.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(partnerId, forKey: .partnerId); try c.encode(version, forKey: .version)
        try c.encode(tiers.sorted(), forKey: .tiers); try c.encode(packs.sorted(), forKey: .packs)
        try c.encode(maxTermDays, forKey: .maxTermDays); try c.encode(maxSeatsPerCode, forKey: .maxSeatsPerCode)
        try c.encode(seatQuota, forKey: .seatQuota); try c.encode(pilotsAllowed, forKey: .pilotsAllowed)
        try c.encode(maxPilotDays, forKey: .maxPilotDays); try c.encode(validFrom, forKey: .validFrom)
        try c.encode(validUntil, forKey: .validUntil); try c.encode(prices, forKey: .prices)
        try c.encode(maxUnpaidSeats, forKey: .maxUnpaidSeats)
    }
}

public struct IssuanceRequest: Codable, Equatable {
    public var licensee: String
    public var tier: String
    public var plan: String
    public var seats: Int
    public var termDays: Int?
    public var expiry: Date?
    public var packs: [String]
    public var reference: String
    public var replaces: String?
    public var profile: String?
    /// Plan JS P2: count this code's phones. Needs `profile` (the seat service is its origin).
    public var seatCheck: Bool?
    public init(licensee: String, tier: String = "team", plan: String = "team", seats: Int,
                termDays: Int? = nil, expiry: Date? = nil, packs: [String] = [], reference: String,
                replaces: String? = nil, profile: String? = nil, seatCheck: Bool? = nil) {
        self.licensee = licensee; self.tier = tier; self.plan = plan; self.seats = seats
        self.termDays = termDays; self.expiry = expiry; self.packs = packs; self.reference = reference
        self.replaces = replaces; self.profile = profile; self.seatCheck = seatCheck
    }
}
public enum IssuanceRefusal: Error, Equatable {
    case tierNotDelegated, packNotResellable(String), unknownPack(String), termTooLong(Int)
    case seatsPerCodeExceeded(Int), quotaExceeded(Int), pilotNotAllowed, pilotWithoutExpiry
    case grantExpired, replacesUnknown, replacementMismatch, invalidRequest, invalidGrant
    case overdueInvoice(String), unpaidSeatLimit(Int), missingPrice, invalidLedger
}

public enum IssuancePolicy {
    public static let day: TimeInterval = 86_400
    public static func validate(_ request: IssuanceRequest, grant: PartnerGrant, ledger: Ledger,
                                catalog: VerifiedPackCatalog, now: Date) -> Result<IssuedLicensePayload, IssuanceRefusal> {
        do { return .success(try validated(request, grant: grant, ledger: ledger, catalog: catalog, now: now)) }
        catch let refusal as IssuanceRefusal { return .failure(refusal) }
        catch { return .failure(.invalidLedger) }
    }
    private static func validated(_ r: IssuanceRequest, grant g: PartnerGrant, ledger: Ledger,
                                  catalog: VerifiedPackCatalog, now: Date) throws -> IssuedLicensePayload {
        try ledger.verify()
        guard !g.partnerId.isEmpty, g.version > 0, g.maxTermDays > 0, g.maxSeatsPerCode > 0,
              g.seatQuota >= 0, g.maxUnpaidSeats >= 0, g.maxPilotDays > 0, g.validFrom < g.validUntil else {
            throw IssuanceRefusal.invalidGrant
        }
        guard now >= g.validFrom, now < g.validUntil else { throw IssuanceRefusal.grantExpired }
        guard r.tier == "team", g.tiers.contains(r.tier), ["team", "pilot"].contains(r.plan) else {
            throw IssuanceRefusal.tierNotDelegated
        }
        guard !r.licensee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !r.reference.isEmpty, r.seats > 0, Set(r.packs).count == r.packs.count,
              r.seatCheck != true || r.profile != nil else {
            throw IssuanceRefusal.invalidRequest
        }
        if let p = r.profile {
            guard let u = URL(string: p), u.scheme == "https", u.host != nil,
                  u.user == nil, u.password == nil, u.fragment == nil else { throw IssuanceRefusal.invalidRequest }
        }
        for p in r.packs.sorted() {
            guard catalog.keys.contains(p) else { throw IssuanceRefusal.unknownPack(p) }
            guard g.packs.contains(p) else { throw IssuanceRefusal.packNotResellable(p) }
        }
        if r.plan == "pilot" {
            guard g.pilotsAllowed else { throw IssuanceRefusal.pilotNotAllowed }
            guard r.termDays != nil || r.expiry != nil else { throw IssuanceRefusal.pilotWithoutExpiry }
        }
        guard (r.termDays != nil) != (r.expiry != nil) else { throw IssuanceRefusal.invalidRequest }
        if let days = r.termDays, days <= 0 || days > g.maxTermDays { throw IssuanceRefusal.termTooLong(g.maxTermDays) }
        let expiry = r.expiry ?? now.addingTimeInterval(Double(r.termDays!) * day)
        let duration = expiry.timeIntervalSince(now)
        let limit = r.plan == "pilot" ? min(g.maxPilotDays, g.maxTermDays) : g.maxTermDays
        guard duration > 0 else { throw IssuanceRefusal.invalidRequest }
        guard duration <= Double(limit) * day else { throw IssuanceRefusal.termTooLong(limit) }
        guard r.seats <= g.maxSeatsPerCode else { throw IssuanceRefusal.seatsPerCodeExceeded(g.maxSeatsPerCode) }
        if let replaces = r.replaces {
            guard let previous = ledger.issuances.first(where: { $0.issuanceId == replaces && $0.partnerId == g.partnerId }),
                  !ledger.issuances.contains(where: { $0.replaces == replaces }) else { throw IssuanceRefusal.replacesUnknown }
            guard previous.licensee == r.licensee, previous.tier == r.tier, previous.plan == r.plan,
                  previous.seats == r.seats, previous.packs == r.packs.sorted(), previous.expires == expiry,
                  previous.profile == r.profile, previous.reference == r.reference else { throw IssuanceRefusal.replacementMismatch }
        } else {
            // Bill on issuance: seats are lifetime issued seats, including expired codes and renewals.
            let reserved = ledger.orders.filter { o in o.partnerId == g.partnerId && !ledger.issuances.contains { $0.orderId == o.id }
                && ledger.invoices.first(where: { $0.orderId == o.id }).map({ ledger.balance($0) > 0 }) == true }.reduce(0) { $0 + $1.request.seats }
            // A paid seat increase's code replaces the live one and carries the total, so its added seats count here.
            let increased = ledger.orders.filter { o in o.partnerId == g.partnerId && o.increaseOf != nil && ledger.issuances.contains { $0.orderId == o.id } }
                .reduce(0) { $0 + $1.request.seats }
            let used = reserved + increased + ledger.issuances.filter { $0.partnerId == g.partnerId && $0.replaces == nil }.reduce(0) { $0 + $1.seats }
            let remaining = max(0, g.seatQuota - used)
            guard r.seats <= remaining else { throw IssuanceRefusal.quotaExceeded(remaining) }
        }
        if r.replaces == nil {
            if let overdue = ledger.invoices.first(where: { $0.partnerId == g.partnerId && ledger.balance($0) > 0 && now >= $0.dueAt }) {
                throw IssuanceRefusal.overdueInvoice(overdue.number)
            }
            if r.plan != "pilot" {
                let unpaid = ledger.invoices.filter { $0.partnerId == g.partnerId && ledger.balance($0) > 0 }.reduce(0) { $0 + $1.seats }
                let remaining = max(0, g.maxUnpaidSeats - unpaid)
                guard r.seats <= remaining else { throw IssuanceRefusal.unpaidSeatLimit(remaining) }
            }
        }
        return IssuedLicensePayload(licensee: r.licensee, issued: now, expires: expiry, tier: r.tier,
                                   plan: r.plan, seats: r.seats, reference: r.reference,
                                   packs: r.packs.isEmpty ? nil : r.packs.sorted(), profile: r.profile,
                                   seatCheck: r.seatCheck == true ? true : nil)
    }
}
