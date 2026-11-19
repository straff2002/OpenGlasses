import Foundation

/// Which vehicle a list of stock belongs to (Plan IH §8).
///
/// The log belongs to the van, not to the technician: it has a name and an identifier, set once
/// and carried in every workbook, so one truck's list is never taken for another's.
struct VanIdentity: Codable, Equatable, Sendable {
    let id: String
    var name: String
    /// Where the list is kept (Plan MK §2). Nil when nobody has chosen, which is van. Carried in
    /// the workbook, so a takeover keeps the words; a kind from a newer build reads as van.
    var place: StockPlace.Kind? = nil
    /// The installed vault this list checks part numbers against when no job is open (Plan MK
    /// §4). This phone's own choice: never written into the workbook, because a vault's id means
    /// nothing on a phone that lacks it, and kept by a takeover.
    var checkVaultID: String? = nil

    /// The list's place, kind and name together; van when nobody chose.
    var stockPlace: StockPlace {
        StockPlace(kind: place ?? .default, name: name.isEmpty ? nil : name)
    }

    /// The identity a takeover leaves on the receiving phone (Plan MK §4): the workbook's van, its
    /// name and its place, with this phone's own choice of vault to check numbers against. A
    /// takeover that names no van leaves no identity, so there is nothing to keep the choice on.
    static func takenOver(_ incoming: VanIdentity?, keeping current: VanIdentity?) -> VanIdentity? {
        guard var incoming else { return nil }
        incoming.checkVaultID = current?.checkVaultID
        return incoming
    }
}

/// The end of a shift and the start of the next (Plan IH §8). Pure.
///
/// Out: what it takes to bring the van back to its standard load, the extras loaded for the day's
/// jobs that are still on board, and the short text that goes to base with the workbook. In: a
/// workbook taken over as the whole truth about a van, and base's baseline applied to standards
/// and nothing else.
enum VanStockHandover {

    // MARK: - Top-up

    struct Shortfall: Equatable, Identifiable {
        let item: VanStockItem
        let onHand: Int
        /// How many it takes to reach the standard load. Nil when the line has no standard and is
        /// listed only because it has run out or is below its minimum.
        let short: Int?
        var id: String { item.id }
    }

    /// Whether any line on the van has a standard load to measure against.
    static func hasStandards(_ log: VanStockLog) -> Bool {
        log.items.contains { $0.standard != nil }
    }

    /// Each line below its standard load and by how much. With no standard set anywhere, the
    /// lines that have run out or are below their minimum — a list that can only say what is gone.
    static func topUp(_ log: VanStockLog) -> [Shortfall] {
        let levels = log.levels
        guard hasStandards(log) else {
            return log.lowItems.map { Shortfall(item: $0, onHand: levels[$0.id]?.onHand ?? 0, short: nil) }
        }
        return log.items.compactMap { item in
            guard let standard = item.standard else { return nil }
            let onHand = levels[item.id]?.onHand ?? 0
            return onHand < standard ? Shortfall(item: item, onHand: onHand, short: standard - onHand) : nil
        }
    }

    // MARK: - The day's extras

    struct Surplus: Equatable, Identifiable {
        let item: VanStockItem
        let onHand: Int
        /// How many are on board beyond the standard load, and no more than were loaded this shift.
        let extra: Int
        var id: String { item.id }
    }

    /// When the shift began: the takeover, or failing one, the start of today.
    static func shiftStart(_ log: VanStockLog, now: Date, calendar: Calendar) -> Date {
        log.movements.last { $0.source == .handover }?.at ?? calendar.startOfDay(for: now)
    }

    /// Lines loaded since the shift began that now stand above their standard load, or have none.
    /// Stock that was already above standard before the shift is not asked about again.
    static func surplus(_ log: VanStockLog, since start: Date) -> [Surplus] {
        let reversed = Set(log.movements.compactMap { $0.kind == .reversed ? $0.reverses : nil })
        var loaded: [String: Int] = [:]
        for movement in log.movements
        where movement.kind == .loaded && movement.at >= start && !reversed.contains(movement.id) {
            loaded[movement.itemID, default: 0] += movement.quantity
        }
        let levels = log.levels
        return log.items.compactMap { item in
            guard let loadedNow = loaded[item.id], let level = levels[item.id], !level.unreliable else { return nil }
            let extra = min(level.onHand - (item.standard ?? 0), loadedNow)
            return extra > 0 ? Surplus(item: item, onHand: level.onHand, extra: extra) : nil
        }
    }

    /// What was sent back to the shelves this shift, for base to see.
    static func returned(_ log: VanStockLog, since start: Date) -> [(item: VanStockItem, quantity: Int)] {
        let reversed = Set(log.movements.compactMap { $0.kind == .reversed ? $0.reverses : nil })
        var totals: [String: Int] = [:]
        for movement in log.movements
        where movement.kind == .removed && movement.reason == .returned && movement.at >= start
            && !reversed.contains(movement.id) {
            totals[movement.itemID, default: 0] += movement.quantity
        }
        return log.items.compactMap { item in totals[item.id].map { (item, $0) } }
    }

    // MARK: - The message

    /// The short text that goes to base with the workbook: what to top up, what is on order, what
    /// needs counting, and what came back. No technician's name is taken from the log, because the
    /// log never holds one; whoever sends the message signs it. Worded for the place (Plan MK
    /// §3): with no `kind`, the place in force for `van`.
    static func message(_ log: VanStockLog, van: VanIdentity?, now: Date, calendar: Calendar,
                        kind: StockPlace.Kind? = nil) -> String {
        let w = StockPlaceWording(kind ?? VanStockSheet.kind(for: van))
        let levels = log.levels
        // A list given a place before a name has an identity with no name yet (Plan MK §2), and
        // is headed by its place's title: "Van stock", "Store stock".
        let heading = van.flatMap { $0.name.isEmpty ? nil : "\($0.name) stock" } ?? w.title
        var lines = ["\(heading), \(stamp(now, calendar))."]

        let shortfalls = topUp(log)
        if shortfalls.isEmpty {
            lines.append(hasStandards(log) ? "Nothing to top up: every line is at its \(w.usualFigure)."
                                           : "Nothing has run out. No \(w.usualFigure) is set for \(w.this), so this list can only show what is gone.")
        } else {
            lines.append(hasStandards(log) ? "To top up (\(shortfalls.count)):"
                                           : "Run out or below minimum (\(shortfalls.count)). No \(w.usualFigure) is set for \(w.this):")
            lines.append(contentsOf: shortfalls.map { shortfall in
                shortfall.short.map { "  \(shortfall.item.phrase($0)) — \(shortfall.onHand) \(w.aboard)" }
                    ?? "  \(shortfall.item.name) — \(shortfall.onHand) \(w.aboard)"
            })
        }

        let ordered = log.items.filter { (levels[$0.id]?.onOrder ?? 0) > 0 }
        if !ordered.isEmpty {
            lines.append("Asked for, not yet \(w.putVerb):")
            lines.append(contentsOf: ordered.map { "  \($0.phrase(levels[$0.id]?.onOrder ?? 0))" })
        }
        let uncounted = log.items.filter { levels[$0.id]?.unreliable == true }
        if !uncounted.isEmpty {
            lines.append("Needs counting:")
            lines.append(contentsOf: uncounted.map { "  \($0.name)" })
        }
        let back = returned(log, since: shiftStart(log, now: now, calendar: calendar))
        if !back.isEmpty {
            lines.append("Returned this shift:")
            lines.append(contentsOf: back.map { "  \($0.item.phrase($0.quantity))" })
        }
        lines.append("The full list is in the attached spreadsheet.")
        return lines.joined(separator: "\n")
    }

    private static func stamp(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0)
    }

    // MARK: - Taking a van over

    /// A van as a workbook describes it, ready to become the phone's list.
    struct Takeover: Equatable {
        let van: VanIdentity?
        let log: VanStockLog
        /// When the workbook was written.
        let exportedAt: Date?
        let lineCount: Int
        let shortfalls: Int
        let needCounting: Int
        let refusals: [VanStockSheet.Proposal.Refusal]
    }

    /// Read a workbook as the whole truth about a van. Unlike a correction, nothing of the phone's
    /// own list is kept: a line that is not in the sheet is not on the van. Every figure becomes a
    /// count marked as handed over; what was on order comes across with no request attached; a
    /// line marked as needing a count stays unreliable.
    static func takeover(from sheets: [XLSXReader.Sheet], at: Date, batch: String,
                         makeID: () -> String = { UUID().uuidString }) -> Result<Takeover, VanStockSheet.Failure> {
        // An empty log, so every row of the sheet reads as a new line.
        switch VanStockSheet.rows(from: sheets) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let read):
            var log = VanStockLog()
            var refusals = read.refusals
            var seen = Set<String>()
            for row in read.rows {
                let id = row.itemID.flatMap { $0.isEmpty ? nil : $0 } ?? makeID()
                guard seen.insert(id).inserted else {
                    refusals.append(.init(row: row.number, reason: .repeatsRow(row.number)))
                    continue
                }
                let item = log.addItem(id: id, number: row.partNumber, description: row.description ?? "",
                                       unit: row.unit ?? .each, minimum: row.minimum, standard: row.standard,
                                       standardSetBy: row.standard == nil ? nil : (row.standardSetByBase ? .base : .van),
                                       bin: row.bin, batch: batch)
                if row.needsCount {
                    log.appendOpening(itemID: item.id, quantity: row.onHand ?? 0, at: at, source: .handover,
                                      counted: false, unreliable: true)
                } else if let onHand = row.onHand {
                    log.record(.counted, itemID: item.id, quantity: onHand, at: at, batch: batch,
                               source: .handover, id: makeID())
                }
                if let onOrder = row.onOrder, onOrder > 0 {
                    log.record(.ordered, itemID: item.id, quantity: onOrder, at: at, batch: batch,
                               source: .handover, id: makeID())
                }
            }
            let levels = log.levels
            return .success(Takeover(van: read.van, log: log, exportedAt: read.exportedAt,
                                     lineCount: log.items.count, shortfalls: topUp(log).count,
                                     needCounting: levels.values.filter(\.unreliable).count,
                                     refusals: refusals))
        }
    }

    // MARK: - Base's baseline

    /// One line of base's baseline against this van.
    struct BaselineChange: Equatable, Identifiable {
        enum Kind: Equatable {
            /// The line takes base's figure.
            case set
            /// The van has never carried it: a new line, at nothing recorded.
            case newLine
            /// This truck set its own standard. Kept unless the technician chooses base's.
            case keptOwn(current: Int)
        }

        let row: Int
        let itemID: String?
        let name: String
        let number: String?
        let description: String
        let unit: VanStockUnit
        let standard: Int
        let kind: Kind
        var id: Int { row }
    }

    /// What base's baseline would do to this van's standards. It never touches a level, and a line
    /// the baseline does not name is left alone — so base can reissue it as often as it likes and a
    /// truck keeps what it has grown.
    static func baseline(from sheets: [XLSXReader.Sheet], log: VanStockLog) -> Result<[BaselineChange], VanStockSheet.Failure> {
        switch VanStockSheet.rows(from: sheets) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let read):
            var changes: [BaselineChange] = []
            var seen = Set<String>()
            for row in read.rows {
                // A baseline gives a standard. Only a sheet with no Standard column at all, which is
                // not one of our own, has its quantities read as the standard: otherwise every
                // export of a van's stock would look like a baseline of what happened to be on board.
                let hasStandardColumn = row.standardCell != nil
                guard let standard = hasStandardColumn ? row.standard : (read.isOwn ? nil : row.onHand) else { continue }
                let existing = VanStockSheet.match(id: row.itemID, number: row.partNumber,
                                                   description: row.description, in: log)
                if let item = existing {
                    // The same figure is no change, whoever set it.
                    guard seen.insert(item.id).inserted, item.standard != standard else { continue }
                    let kind: BaselineChange.Kind
                    if let current = item.standard, item.standardSetBy == .van, current != standard {
                        kind = .keptOwn(current: current)
                    } else {
                        kind = .set
                    }
                    changes.append(.init(row: row.number, itemID: item.id, name: item.name, number: item.number,
                                         description: item.description, unit: item.unit, standard: standard, kind: kind))
                } else if row.partNumber != nil || row.description != nil {
                    let described = row.description ?? ""
                    changes.append(.init(row: row.number, itemID: nil,
                                         name: described.isEmpty ? (row.partNumber ?? "") : described,
                                         number: row.partNumber, description: described, unit: row.unit ?? .each,
                                         standard: standard, kind: .newLine))
                }
            }
            return .success(changes)
        }
    }

    /// Apply a baseline as one batch. `takingBaseFigure` names the lines, among those this truck
    /// set itself, where the technician chose base's figure.
    static func apply(_ changes: [BaselineChange], to log: inout VanStockLog, takingBaseFigure: Set<String> = [],
                      at: Date, batch: String, makeID: () -> String = { UUID().uuidString }) {
        for change in changes {
            switch change.kind {
            case .newLine:
                // Added bare and then given its standard, so the batch has an entry an undo can find.
                let item = log.addItem(id: makeID(), number: change.number, description: change.description,
                                       unit: change.unit, batch: batch)
                log.edit(itemID: item.id, .standard(change.standard, setBy: .base), at: at, batch: batch,
                         source: .sheet, id: makeID())
            case .set:
                guard let id = change.itemID else { continue }
                log.edit(itemID: id, .standard(change.standard, setBy: .base), at: at, batch: batch,
                         source: .sheet, id: makeID())
            case .keptOwn:
                guard let id = change.itemID, takingBaseFigure.contains(id) else { continue }
                log.edit(itemID: id, .standard(change.standard, setBy: .base), at: at, batch: batch,
                         source: .sheet, id: makeID())
            }
        }
    }
}
