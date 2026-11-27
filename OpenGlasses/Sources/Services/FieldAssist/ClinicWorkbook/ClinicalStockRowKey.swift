import Foundation
import CryptoKit

/// The key every row this phone adds to the clinic's workbook carries (Plan NK §2). Pure.
///
/// A key is `<seat>.<base>.<sequence>`:
/// - **seat:** eight hex digits of a hash of this phone's install id (`ClinicWorkbookConnectionStore
///   .seat`), so two phones' rows never share a key, and the id itself is not in the workbook;
/// - **base:** twelve hex digits of a hash of the seat, the day, the span, the line, the lot, the
///   kind and the reason: what the row is about, the same every time that is sent;
/// - **sequence:** 1 for the first row about it, then 2, 3… for each top-up or correction.
///
/// Nothing in a key says which line, lot or day it is about, so it reads as a random reference.
enum ClinicalStockRowKey {

    /// The seat's tag: eight hex digits.
    static func seatTag(_ seat: String) -> String {
        hex("seat|" + seat, digits: 8)
    }

    /// What a row is about, from this phone: `<seat>.<base>`.
    static func base(_ row: ClinicalStockShareRow, seat: String) -> String {
        let about = [seat, row.day.description, row.span.rawValue, row.lineID, row.lotCode ?? "",
                     row.kind.rawValue, row.wasteReason?.rawValue ?? ""].joined(separator: "|")
        return seatTag(seat) + "." + hex(about, digits: 12)
    }

    /// The key of the `sequence`th row about `base`.
    static func key(base: String, sequence: Int) -> String { base + ".\(sequence)" }

    /// A key's base and sequence. Nil for a key this app did not make.
    static func parse(_ key: String) -> (base: String, sequence: Int)? {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 8, parts[1].count == 12,
              parts[0].allSatisfy(\.isHexDigit), parts[1].allSatisfy(\.isHexDigit),
              let sequence = Int(parts[2]), sequence >= 1 else { return nil }
        return (parts[0] + "." + parts[1], sequence)
    }

    private static func hex(_ text: String, digits: Int) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(digits).description
    }
}

/// What this phone has sent to one workbook, by row base (Plan NK §2): each sequence's quantity,
/// so a day sent again adds nothing, a top-up adds only the difference and a correction is a new
/// row with the opposite quantity. Kept on the phone (`ClinicWorkbookConnectionStore`), never in
/// the workbook. Pure.
struct ClinicalStockSendLedger: Codable, Equatable, Sendable {

    struct Entry: Codable, Equatable, Sendable {
        /// The row as first sent, for a correction to repeat its line, lot and day.
        var row: ClinicalStockShareRow
        /// Each sequence's quantity in signed thousandths, by sequence.
        var parts: [String: Int]
        /// The highest sequence ever used, so a sequence is never reused after a rollback.
        var highest: Int

        /// What the workbook holds from this phone about the row: the sum of the parts, or for a
        /// count, the last one.
        var sent: StockQuantity? {
            guard !parts.isEmpty else { return nil }
            if row.kind == .counted {
                let last = parts.keys.compactMap { Int($0) }.max().map { String($0) }
                return last.flatMap { parts[$0] }.map(StockQuantity.init(scaled:))
            }
            return StockQuantity(scaled: parts.values.reduce(0, +))
        }
    }

    var entries: [String: Entry] = [:]
    /// Whether everything the phone's list held has been sent once. Until then a send covers the
    /// whole history; after it, a window of recent days.
    var historySent = false

    /// Record a row as queued for the workbook.
    mutating func record(_ keyed: KeyedShareRow) {
        guard let parsed = ClinicalStockRowKey.parse(keyed.key) else { return }
        var entry = entries[parsed.base] ?? Entry(row: keyed.row, parts: [:], highest: 0)
        entry.parts[String(parsed.sequence)] = keyed.row.quantity.scaled
        entry.highest = max(entry.highest, parsed.sequence)
        entries[parsed.base] = entry
    }

    /// Take rows back that never reached the workbook, so a later send makes them again.
    mutating func rollBack(_ keys: [String]) {
        for key in keys {
            guard let parsed = ClinicalStockRowKey.parse(key) else { continue }
            entries[parsed.base]?.parts[String(parsed.sequence)] = nil
        }
    }

    /// Forget rows about days before `day`: they are outside the window a send looks at.
    mutating func prune(before day: StockDay) {
        entries = entries.filter { $0.value.row.day >= day }
    }

    /// The ledger the workbook itself implies for this phone's seat: for a phone whose own ledger
    /// was lost (a new install). Only rows whose key is this seat's are read.
    static func rebuilt(from entries: [ClinicalStockWorkbookEntry], rowsByKey: [String: ClinicalStockShareRow],
                        seat: String) -> ClinicalStockSendLedger {
        var ledger = ClinicalStockSendLedger()
        let tag = ClinicalStockRowKey.seatTag(seat)
        for entry in entries.sorted(by: { $0.position < $1.position }) {
            guard let key = entry.key, key.hasPrefix(tag + "."), ClinicalStockRowKey.parse(key) != nil,
                  let row = rowsByKey[key] ?? Self.row(entry) else { continue }
            ledger.record(KeyedShareRow(row: row.with(quantity: entry.quantity), key: key))
        }
        ledger.historySent = !ledger.entries.isEmpty
        return ledger
    }

    /// A workbook row as a share row, for a rebuilt ledger. The line's own id is not in the
    /// workbook; the line number or name stands for it.
    private static func row(_ entry: ClinicalStockWorkbookEntry) -> ClinicalStockShareRow? {
        ClinicalStockShareRow(day: entry.day, span: entry.span, lineID: entry.line.value, lineNumber: entry.lineNumber,
                              lineName: entry.lineName, lotCode: entry.lotCode, lotExpiry: nil, kind: entry.kind,
                              quantity: entry.quantity, wasteReason: entry.wasteReason)
    }
}

/// The rows a send adds to the workbook (Plan NK §2, Decision 3). Pure.
///
/// For every row the phone's list gives now (`ClinicalStockShare.rows`):
/// - nothing, when the workbook already holds it from this phone (the same day sent twice);
/// - the difference, as a new row with its own key, when it has changed (a day sent "so far" and
///   topped up later, or lowered by a reversal);
/// - a count only when the day's last count is not the one sent: a new `Counts` row with the figure.
///
/// A row the phone sent and no longer gives (every movement on it reversed) is taken back with a
/// row of the opposite quantity. A count is a level, so it is never taken back: the next count
/// replaces it.
enum ClinicalStockSendPlan {

    /// Days a send looks back over once the history has been sent.
    static let windowDays = 62

    struct Plan: Equatable, Sendable {
        let rows: [KeyedShareRow]
        let ledger: ClinicalStockSendLedger
    }

    /// The days a send covers: everything until the history has gone once, then the window, from
    /// the start of its first week, so a sensitive line's weekly row is never cut in two.
    static func range(ledger: ClinicalStockSendLedger, now: Date, calendar: Calendar) -> StockReportRange? {
        guard ledger.historySent else { return nil }
        let back = calendar.date(byAdding: .day, value: -(windowDays - 1), to: now) ?? now
        let first = min(ClinicalStockShare.weekStart(of: back, calendar: calendar), StockDay(back, calendar: calendar))
        return StockReportRange(first: first, last: StockDay(now, calendar: calendar))
    }

    /// `current` is what the phone's list gives over `range` (all of it when nil).
    static func plan(current: [ClinicalStockShareRow], ledger: ClinicalStockSendLedger, seat: String,
                     range: StockReportRange?) -> Plan {
        var ledger = ledger
        var rows: [KeyedShareRow] = []
        var given = Set<String>()

        func add(_ row: ClinicalStockShareRow, base: String) {
            let sequence = (ledger.entries[base]?.highest ?? 0) + 1
            let keyed = KeyedShareRow(row: row, key: ClinicalStockRowKey.key(base: base, sequence: sequence))
            ledger.record(keyed)
            rows.append(keyed)
        }

        for row in current {
            let base = ClinicalStockRowKey.base(row, seat: seat)
            given.insert(base)
            let sent = ledger.entries[base]?.sent
            if row.kind == .counted {
                if sent != row.quantity { add(row, base: base) }
            } else {
                let difference = row.quantity - (sent ?? .zero)
                if difference != .zero { add(row.with(quantity: difference), base: base) }
            }
        }

        // Taken back: sent, inside the range, and no longer given.
        let gone = ledger.entries
            .filter { base, entry in
                !given.contains(base) && entry.row.kind != .counted
                    && range.map { $0.first <= entry.row.day && entry.row.day <= $0.last } ?? true
            }
            .sorted { $0.key < $1.key }
        for (base, entry) in gone {
            guard let sent = entry.sent, sent != .zero else { continue }
            add(entry.row.with(quantity: StockQuantity(scaled: -sent.scaled)), base: base)
        }

        if range == nil { ledger.historySent = true }
        return Plan(rows: rows, ledger: ledger)
    }
}
