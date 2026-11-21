import Foundation

/// A calendar day with no time and no time zone: an expiry date as a label prints it (Plan MY §4).
///
/// An expiry is a day, not an instant, so it is kept as year, month and day and compared as such;
/// "today" is worked out from the clock in the caller's calendar. Stored as "2027-11-30". Pure.
struct StockDay: Codable, Comparable, Hashable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    /// Nil for a day that does not exist: a 13th month, 30 February, day 0.
    init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), year >= 1, day >= 1,
              day <= Self.daysIn(month: month, year: year) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// The last day of a month (Plan MY §4: a GS1 day of `00` means this). Nil for a 13th month.
    static func lastDay(ofMonth month: Int, year: Int) -> StockDay? {
        guard (1...12).contains(month), year >= 1 else { return nil }
        return StockDay(year: year, month: month, day: daysIn(month: month, year: year))
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// The day `date` falls on in `calendar`.
    init(_ date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        // A calendar always yields a real day for a real date.
        self.year = parts.year ?? 1
        self.month = parts.month ?? 1
        self.day = parts.day ?? 1
    }

    /// The day `days` after this one (negative for before), counted in `calendar`.
    func adding(days: Int, calendar: Calendar) -> StockDay {
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        guard let start = utc.date(from: DateComponents(year: year, month: month, day: day)),
              let moved = utc.date(byAdding: .day, value: days, to: start) else { return self }
        return StockDay(moved, calendar: utc)
    }

    static func < (lhs: StockDay, rhs: StockDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// "2027-11-30".
    var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// "30 November 2027", for the model. English, as every van stock sentence is.
    var spoken: String {
        let months = ["January", "February", "March", "April", "May", "June", "July", "August",
                      "September", "October", "November", "December"]
        return "\(day) \(months[(month - 1) % 12]) \(year)"
    }

    /// The day "2027-11-30" names. Nil for anything else.
    init?(iso raw: String) {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let day = StockDay(iso: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a day"))
        }
        self = day
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// One lot (batch) of a line (Plan MY §1, Decision 2: a lot belongs to a line).
///
/// The code is kept exactly as it was read: case and leading zeros are part of it. A lot comes in
/// on a delivery or a count, from a scanned carton or the screen, and never from a spoken word
/// alone: a spoken lot is only ever matched against the lots a line already holds
/// (`StockLotMatch`). A lot holds no figure of its own; what is in it is folded from the movements
/// that name it (`VanStockLevel.lots`).
struct StockLot: Codable, Equatable, Identifiable, Sendable {
    let id: String
    /// The line this lot is of.
    let itemID: String
    /// The lot code as printed or scanned, verbatim.
    let code: String
    /// The expiry printed on the carton, when it has one.
    var expiry: StockDay?
    /// When this lot first came onto the list.
    let firstReceived: Date
    /// The batch that added the lot, so undoing that batch takes it away again.
    let createdBatch: String

    enum CodingKeys: String, CodingKey {
        case id, code, expiry
        case itemID = "item_id"
        case firstReceived = "first_received"
        case createdBatch = "created_batch"
    }
}

/// What is in one lot, and how that is known. Folded, never stored, like `VanStockLevel`.
struct StockLotLevel: Equatable, Sendable {
    let lotID: String
    var onHand: StockQuantity = .zero
    var provenance: VanStockLevel.Provenance = .inferred
    /// More was taken from this lot than the log showed in it; a count of the lot clears it.
    var unreliable = false
    /// When the lot's figure last changed. Nil for a lot nothing has been recorded against.
    var asOf: Date?

    var isRecorded: Bool { asOf != nil }
}

/// The expiry rules (Plan MY §4). Pure, with today handed in.
enum StockExpiry {

    /// A lot is used up to and including its expiry day, and expired from the day after.
    static func isExpired(_ lot: StockLot, today: StockDay) -> Bool {
        guard let expiry = lot.expiry else { return false }
        return expiry < today
    }

    /// Not yet expired, and expiring on or before `days` from today.
    static func expiresSoon(_ lot: StockLot, today: StockDay, within days: Int = VaccineStockPolicy.expiringSoonDays,
                            calendar: Calendar) -> Bool {
        guard let expiry = lot.expiry, !isExpired(lot, today: today) else { return false }
        return expiry <= today.adding(days: days, calendar: calendar)
    }

    /// Oldest expiry first (Plan MY §4: the fridge is used oldest first). A lot with no expiry
    /// goes last; ties go to the lot received first, then by code, so the order never wobbles.
    static func oldestFirst(_ lots: [StockLot]) -> [StockLot] {
        lots.sorted { lhs, rhs in
            switch (lhs.expiry, rhs.expiry) {
            case let (l?, r?) where l != r: return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                if lhs.firstReceived != rhs.firstReceived { return lhs.firstReceived < rhs.firstReceived }
                return lhs.code < rhs.code
            }
        }
    }

    /// The lots with something in them, oldest expiry first.
    static func inStock(_ lots: [StockLot], levels: [String: StockLotLevel]) -> [StockLot] {
        oldestFirst(lots.filter { (levels[$0.id]?.onHand ?? .zero) > .zero })
    }

    /// The lots in stock that expire within `days` and have not expired, oldest first: the list
    /// the Stock screen and every report show (Plan MY §4).
    static func expiringSoon(_ lots: [StockLot], levels: [String: StockLotLevel], today: StockDay,
                             within days: Int = VaccineStockPolicy.expiringSoonDays,
                             calendar: Calendar) -> [StockLot] {
        inStock(lots, levels: levels).filter { expiresSoon($0, today: today, within: days, calendar: calendar) }
    }

    /// The lots in stock that have already expired, oldest first.
    static func expiredInStock(_ lots: [StockLot], levels: [String: StockLotLevel], today: StockDay) -> [StockLot] {
        inStock(lots, levels: levels).filter { isExpired($0, today: today) }
    }

    /// A lot in stock that expires before `lot` does, the oldest of them, for the "use the older
    /// one first" line. Nil when `lot` is the oldest in stock, or has no expiry to compare.
    static func older(than lot: StockLot, among lots: [StockLot], levels: [String: StockLotLevel]) -> StockLot? {
        inStock(lots, levels: levels).first { other in
            guard other.id != lot.id, let theirs = other.expiry else { return false }
            guard let ours = lot.expiry else { return true }
            return theirs < ours
        }
    }
}

/// Which of a line's own lots a spoken or typed lot code means (Plan MY §1). Pure.
///
/// Exactly as printed first; then with case, spaces and dashes forgiven, because a spoken
/// "zed zed one zero zero one" reaches the tool as "zz1001" or "ZZ-1001". It never makes a lot:
/// a code the line does not hold is `.none`, and the caller refuses.
enum StockLotMatch: Equatable {
    case one(StockLot)
    case several([StockLot])
    case none

    static func match(_ said: String, in lots: [StockLot]) -> StockLotMatch {
        let trimmed = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        let exact = lots.filter { $0.code == trimmed }
        if exact.count == 1 { return .one(exact[0]) }
        if exact.count > 1 { return .several(StockExpiry.oldestFirst(exact)) }
        let wanted = normalised(trimmed)
        guard !wanted.isEmpty else { return .none }
        let loose = lots.filter { normalised($0.code) == wanted }
        switch loose.count {
        case 0: return .none
        case 1: return .one(loose[0])
        default: return .several(StockExpiry.oldestFirst(loose))
        }
    }

    /// Letters and digits only, upper case.
    static func normalised(_ code: String) -> String {
        String(code.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
