import Foundation

/// How many of one line are on the van, and how that is known (Plan IH §1).
///
/// Never stored: it is what the movements add up to. The words are Plan HF's on purpose —
/// `counted` when nothing has moved since somebody counted, `inferred` when the figure was worked
/// out from loads and uses — so the office can take a van over without reshaping anything.
struct VanStockLevel: Equatable, Sendable {

    enum Provenance: String, Equatable, Sendable {
        case counted
        case inferred
    }

    let itemID: String
    /// In thousandths of the line's unit, as every figure here is.
    var onHand: StockQuantity = .zero
    /// Asked for and not yet loaded.
    var onOrder: StockQuantity = .zero
    var oldestOrderAt: Date?
    var provenance: Provenance = .inferred
    /// When the level last changed. Nil for a line nothing has ever been recorded against.
    var asOf: Date?
    /// A use was recorded that the log could not cover. The figure is not to be trusted until a
    /// count clears it.
    var unreliable = false
    /// The level is the one a handover left, and nothing has moved since.
    var handedOver = false

    /// Whether anything has ever established a level for the line.
    var isRecorded: Bool { asOf != nil }
}

/// The van's stock: its lines, and every movement recorded against them (Plan IH §1).
///
/// A value, and pure: every change takes its time, its batch and its identifiers from the caller,
/// so the same calls always produce the same log. The store that keeps one on disk and the tool
/// that speaks for it come later; nothing here touches a file, a clock or the network.
struct VanStockLog: Codable, Equatable, Sendable {

    private(set) var items: [VanStockItem]
    private(set) var movements: [VanStockMovement]

    init(items: [VanStockItem] = [], movements: [VanStockMovement] = []) {
        self.items = items
        self.movements = movements
    }

    var isEmpty: Bool { items.isEmpty }

    func item(id: String) -> VanStockItem? { items.first { $0.id == id } }

    // MARK: - Levels

    /// Every line's level, keyed by item. A line with nothing recorded is present, at zero.
    var levels: [String: VanStockLevel] {
        Self.fold(movements, reversed: Self.reversedIDs(in: movements), items: items).levels
    }

    func level(of itemID: String) -> VanStockLevel {
        levels[itemID] ?? VanStockLevel(itemID: itemID)
    }

    /// Lines at or below their minimum, and recorded lines at zero that have no minimum set, in
    /// list order.
    var lowItems: [VanStockItem] {
        let levels = self.levels
        return items.filter { item in
            guard let level = levels[item.id] else { return false }
            if let minimum = item.minimum { return level.onHand <= minimum }
            return level.isRecorded && level.onHand == .zero
        }
    }

    // MARK: - Lines

    /// Add a line. Only a load, a count or an import may do this; a use that matches nothing
    /// changes nothing, which is what stops a misheard number becoming a new line.
    @discardableResult
    mutating func addItem(id: String = UUID().uuidString,
                          number: String? = nil,
                          description: String,
                          unit: VanStockUnit = .each,
                          minimum: StockQuantity? = nil,
                          standard: StockQuantity? = nil,
                          standardSetBy: VanStockItem.StandardOrigin? = nil,
                          bin: String? = nil,
                          codes: [String] = [],
                          verified: Bool = false,
                          verification: VanStockVerification? = nil,
                          batch: String) -> VanStockItem {
        let normalised = number.map(VaultPartsIndex.normalise).flatMap { $0.isEmpty ? nil : $0 }
        let item = VanStockItem(id: id, number: normalised,
                                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                                unit: unit, minimum: minimum, standard: standard,
                                standardSetBy: standard == nil ? nil : standardSetBy,
                                bin: bin, codes: codes, verified: verified, verification: verification,
                                createdBatch: batch)
        items.append(item)
        return item
    }

    // MARK: - Movements

    /// Record a load, a use, a removal, a count or an order. Nil — and nothing recorded — for a
    /// line the van does not have, a kind this does not take, or a quantity that makes no sense
    /// for the kind: a count may be zero, everything else is more than zero. A figure above a
    /// million units, or one that is not a step of the line's unit (part of a pack), is never
    /// recorded.
    @discardableResult
    mutating func record(_ kind: VanStockMovement.Kind,
                         itemID: String,
                         quantity: StockQuantity,
                         at: Date,
                         batch: String,
                         source: VanStockMovement.Source,
                         id: String = UUID().uuidString,
                         jobSessionID: String? = nil,
                         jobReference: String? = nil,
                         reason: VanStockMovement.RemovalReason? = nil,
                         requestID: String? = nil) -> VanStockMovement? {
        guard let item = item(id: itemID) else { return nil }
        switch kind {
        case .loaded, .used, .removed, .ordered: guard quantity > .zero else { return nil }
        case .counted: guard quantity >= .zero else { return nil }
        case .edited, .reversed, .opening: return nil
        }
        guard quantity.fits(item.unit) else { return nil }
        let movement = VanStockMovement(
            id: id, itemID: itemID, kind: kind, quantity: quantity, at: at, batch: batch, source: source,
            jobSessionID: kind == .used || kind == .loaded ? jobSessionID : nil,
            jobReference: kind == .used || kind == .loaded ? jobReference : nil,
            reason: kind == .removed ? (reason ?? .other) : nil,
            requestID: kind == .ordered ? requestID : nil)
        movements.append(movement)
        return movement
    }

    /// Carry a figure forward as an opening entry: what a folded history leaves, and how a
    /// handover brings across a line whose count cannot be trusted.
    mutating func appendOpening(itemID: String, quantity: StockQuantity, at: Date,
                                source: VanStockMovement.Source, counted: Bool, unreliable: Bool) {
        guard item(id: itemID) != nil, quantity.isInRange else { return }
        movements.append(VanStockMovement(id: "opening-\(itemID)", itemID: itemID, kind: .opening,
                                          quantity: quantity, at: at, batch: Self.openingBatch, source: source,
                                          openingCounted: counted, openingUnreliable: unreliable))
    }

    /// Note that a line was added with nothing recorded against it, so the batch that added it
    /// has an entry — and an undo of that batch has something to find.
    mutating func appendNote(itemID: String, at: Date, batch: String, source: VanStockMovement.Source,
                             id: String = UUID().uuidString) {
        guard let item = item(id: itemID) else { return }
        movements.append(VanStockMovement(id: id, itemID: itemID, kind: .edited, at: at, batch: batch,
                                          source: source, attribute: .unit, oldValue: item.unit.rawValue,
                                          newValue: item.unit.rawValue))
    }

    /// One change to a line's attributes.
    enum Change: Equatable, Sendable {
        case number(String?)
        case description(String)
        case unit(VanStockUnit)
        case minimum(StockQuantity?)
        case standard(StockQuantity?, setBy: VanStockItem.StandardOrigin?)
        case bin(String?)
        case addCode(String)
        /// Today's two-state change: `true` is found in no named book, `false` is not checked.
        case verified(Bool)
        /// What a lookup said, and which book answered (Plan MK §4). Recorded under the same
        /// `verified` attribute, so an older build still reads the log.
        case verification(VanStockVerification)
    }

    /// Change one attribute of a line and note that it changed. False, and nothing noted, when the
    /// line does not exist, the value is already what was asked for, or the change is refused: a
    /// unit counted whole while a figure on the line is not (`unitChangeRefusal`), or a minimum or
    /// standard that is no figure the line's unit can hold.
    @discardableResult
    mutating func edit(itemID: String, _ change: Change, at: Date, batch: String,
                       source: VanStockMovement.Source, id: String = UUID().uuidString) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return false }
        var item = items[index]
        let attribute: VanStockMovement.Attribute
        let old: String?
        let new: String?

        switch change {
        case .number(let raw):
            let value = raw.map(VaultPartsIndex.normalise).flatMap { $0.isEmpty ? nil : $0 }
            (attribute, old, new) = (.number, item.number, value)
            item.number = value
        case .description(let raw):
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            (attribute, old, new) = (.description, item.description, value)
            item.description = value
        case .unit(let value):
            guard unitChangeRefusal(itemID: itemID, to: value) == nil else { return false }
            (attribute, old, new) = (.unit, item.unit.rawValue, value.rawValue)
            item.unit = value
        case .minimum(let value):
            if let value, !value.fits(item.unit) { return false }
            (attribute, old, new) = (.minimum, item.minimum.map(Self.encodeQuantity), value.map(Self.encodeQuantity))
            item.minimum = value
        case .standard(let value, let setBy):
            if let value, !value.fits(item.unit) { return false }
            let origin = value == nil ? nil : setBy
            (attribute, old, new) = (.standard,
                                     Self.encodeStandard(item.standard, item.standardSetBy),
                                     Self.encodeStandard(value, origin))
            item.standard = value
            item.standardSetBy = origin
        case .bin(let raw):
            let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            (attribute, old, new) = (.bin, item.bin, value)
            item.bin = value
        case .addCode(let raw):
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !item.codes.contains(value) else { return false }
            (attribute, old, new) = (.code, nil, value)
            item.codes.append(value)
        case .verified(let value):
            (attribute, old, new) = (.verified, String(item.verified), String(value))
            item.verified = value
        case .verification(let value):
            (attribute, old, new) = (.verified, item.verification.storedValue, value.storedValue)
            item.verification = value
        }

        guard old != new else { return false }
        items[index] = item
        movements.append(VanStockMovement(id: id, itemID: itemID, kind: .edited, at: at, batch: batch,
                                          source: source, attribute: attribute, oldValue: old, newValue: new))
        return true
    }

    /// Why a line cannot be changed to `unit`, or nil when it can. A unit counted whole (`each`,
    /// `pack`) is refused while the line's on-hand, minimum or standard is part of one: "4.25 l on
    /// hand is not a whole number of packs; count it first." The stored figures never change with
    /// the unit, so 4 each becomes 4 l and back again. English, for the model.
    func unitChangeRefusal(itemID: String, to unit: VanStockUnit) -> String? {
        guard let item = item(id: itemID), unit != item.unit, !unit.allowsFraction else { return nil }
        let whole = unit == .pack ? "a whole number of packs" : "a whole number"
        func amount(_ quantity: StockQuantity) -> String { "\(quantity.decimalString) \(item.unit.rawValue)" }
        let onHand = level(of: itemID).onHand
        if !onHand.fits(unit) { return "\(amount(onHand)) on hand is not \(whole); count it first." }
        if let minimum = item.minimum, !minimum.fits(unit) {
            return "The minimum of \(amount(minimum)) is not \(whole); change it first."
        }
        if let standard = item.standard, !standard.fits(unit) {
            return "The standard of \(amount(standard)) is not \(whole); change it first."
        }
        return nil
    }

    // MARK: - Undo

    /// Whether there is a batch an undo would take back.
    var canUndo: Bool {
        guard let last = movements.last else { return false }
        return last.kind != .reversed && last.kind != .opening
    }

    /// What an undo took back.
    struct Undone: Equatable, Sendable {
        let batch: String
        /// The movements reversed, in the order they were first recorded.
        let movements: [VanStockMovement]
        /// Lines the batch had created, now gone again.
        let removedItems: [VanStockItem]
    }

    /// Take back the most recent batch — the whole spoken sentence, or the whole imported sheet.
    /// Once: with an undo as the last thing recorded there is nothing further to take back.
    @discardableResult
    mutating func undoLastBatch(at: Date, batch undoBatch: String,
                                source: VanStockMovement.Source,
                                makeID: () -> String = { UUID().uuidString }) -> Undone? {
        guard let last = movements.last, last.kind != .reversed, last.kind != .opening else { return nil }
        let already = Self.reversedIDs(in: movements)
        let target = movements.filter { $0.batch == last.batch && !already.contains($0.id) }
        guard !target.isEmpty else { return nil }

        for movement in target.reversed() {
            if movement.kind == .edited { restore(movement) }
            movements.append(VanStockMovement(id: makeID(), itemID: movement.itemID, kind: .reversed,
                                              at: at, batch: undoBatch, source: source,
                                              reverses: movement.id))
        }
        let removed = items.filter { $0.createdBatch == last.batch }
        items.removeAll { $0.createdBatch == last.batch }
        return Undone(batch: last.batch, movements: target, removedItems: removed)
    }

    /// Put an edited attribute back to what it was.
    private mutating func restore(_ movement: VanStockMovement) {
        guard let attribute = movement.attribute,
              let index = items.firstIndex(where: { $0.id == movement.itemID }) else { return }
        let old = movement.oldValue
        switch attribute {
        case .number: items[index].number = old
        case .description: items[index].description = old ?? ""
        case .unit: items[index].unit = old.flatMap(VanStockUnit.init(rawValue:)) ?? .each
        case .minimum: items[index].minimum = old.flatMap(Self.decodeQuantity)
        case .standard:
            let (value, origin) = Self.decodeStandard(old)
            items[index].standard = value
            items[index].standardSetBy = origin
        case .bin: items[index].bin = old
        case .code: items[index].codes.removeAll { $0 == movement.newValue }
        // "true" and "false" from an older log, or a stored verification from a newer one.
        case .verified: items[index].verification = VanStockVerification(storedValue: old)
        }
    }

    // MARK: - Folding an old history

    /// The same log with everything before `cutoff` folded into one opening figure per line.
    /// Every level, every open order and every unreliable mark is exactly what it was; only the
    /// history is shorter.
    func compacted(before cutoff: Date) -> VanStockLog {
        let old = movements.filter { $0.at < cutoff }
        guard !old.isEmpty else { return self }
        let recent = movements.filter { $0.at >= cutoff }
        let state = Self.fold(old, reversed: Self.reversedIDs(in: movements), items: items)

        var carried: [VanStockMovement] = []
        for item in items {
            guard let level = state.levels[item.id] else { continue }
            if let asOf = level.asOf {
                carried.append(VanStockMovement(
                    id: "opening-\(item.id)", itemID: item.id, kind: .opening, quantity: level.onHand,
                    at: asOf, batch: Self.openingBatch,
                    source: level.handedOver ? .handover : .typed,
                    openingCounted: level.provenance == .counted,
                    openingUnreliable: level.unreliable))
            }
            for order in state.openOrders[item.id] ?? [] {
                carried.append(VanStockMovement(
                    id: order.id, itemID: item.id, kind: .ordered, quantity: order.remaining,
                    at: order.at, batch: order.batch, source: order.source, requestID: order.requestID))
            }
        }
        carried.sort { $0.at < $1.at }
        return VanStockLog(items: items, movements: carried + recent)
    }

    static let openingBatch = "opening"

    // MARK: - The fold

    private struct OpenOrder {
        let id: String
        var remaining: StockQuantity
        let at: Date
        let batch: String
        let source: VanStockMovement.Source
        let requestID: String?
    }

    private struct Folded {
        var levels: [String: VanStockLevel]
        var openOrders: [String: [OpenOrder]]
    }

    private static func reversedIDs(in movements: [VanStockMovement]) -> Set<String> {
        Set(movements.compactMap { $0.kind == .reversed ? $0.reverses : nil })
    }

    private static func fold(_ movements: [VanStockMovement], reversed: Set<String>,
                             items: [VanStockItem]) -> Folded {
        var levels = Dictionary(uniqueKeysWithValues: items.map { ($0.id, VanStockLevel(itemID: $0.id)) })
        var orders: [String: [OpenOrder]] = [:]

        for movement in movements where !reversed.contains(movement.id) {
            // A movement for a line that has since been taken away is history, not stock.
            guard var level = levels[movement.itemID] else { continue }
            switch movement.kind {
            case .loaded:
                level.onHand += movement.quantity
                level.provenance = .inferred
                level.handedOver = false
                level.asOf = movement.at
                var left = movement.quantity
                var open = orders[movement.itemID] ?? []
                while left > .zero, !open.isEmpty {
                    let taken = min(left, open[0].remaining)
                    open[0].remaining -= taken
                    left -= taken
                    if open[0].remaining == .zero { open.removeFirst() }
                }
                orders[movement.itemID] = open
            case .used, .removed:
                if movement.quantity > level.onHand {
                    level.onHand = .zero
                    level.unreliable = true
                } else {
                    level.onHand -= movement.quantity
                }
                level.provenance = .inferred
                level.handedOver = false
                level.asOf = movement.at
            case .counted:
                level.onHand = movement.quantity
                level.provenance = .counted
                level.unreliable = false
                level.handedOver = movement.source == .handover
                level.asOf = movement.at
            case .opening:
                level.onHand = movement.quantity
                level.provenance = movement.openingCounted == true ? .counted : .inferred
                level.unreliable = movement.openingUnreliable == true
                level.handedOver = movement.openingCounted == true && movement.source == .handover
                level.asOf = movement.at
            case .ordered:
                orders[movement.itemID, default: []].append(OpenOrder(
                    id: movement.id, remaining: movement.quantity, at: movement.at,
                    batch: movement.batch, source: movement.source, requestID: movement.requestID))
            case .edited, .reversed:
                break
            }
            levels[movement.itemID] = level
        }

        for (itemID, open) in orders {
            levels[itemID]?.onOrder = open.reduce(.zero) { $0 + $1.remaining }
            levels[itemID]?.oldestOrderAt = open.first?.at
        }
        return Folded(levels: levels, openOrders: orders)
    }

    // MARK: - Minimum and standard, as stored text

    /// A minimum or standard in an `edited` movement: its thousandths, "4250". Format 2 of the
    /// store; format 1 held whole units, and `VanStockLogMigration` rescales those strings.
    static func encodeQuantity(_ value: StockQuantity) -> String { String(value.scaled) }

    /// The figure `encodeQuantity` wrote. Nil for anything else, or for a figure out of range.
    static func decodeQuantity(_ raw: String) -> StockQuantity? {
        guard let scaled = Int(raw) else { return nil }
        let value = StockQuantity(scaled: scaled)
        return value.isInRange ? value : nil
    }

    /// "5000:base", or "5000" with no origin.
    private static func encodeStandard(_ value: StockQuantity?, _ origin: VanStockItem.StandardOrigin?) -> String? {
        guard let value else { return nil }
        let figure = encodeQuantity(value)
        return origin.map { "\(figure):\($0.rawValue)" } ?? figure
    }

    private static func decodeStandard(_ raw: String?) -> (StockQuantity?, VanStockItem.StandardOrigin?) {
        guard let raw else { return (nil, nil) }
        let parts = raw.split(separator: ":", maxSplits: 1)
        guard let first = parts.first, let value = decodeQuantity(String(first)) else { return (nil, nil) }
        let origin = parts.count > 1 ? VanStockItem.StandardOrigin(rawValue: String(parts[1])) : nil
        return (value, origin)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
