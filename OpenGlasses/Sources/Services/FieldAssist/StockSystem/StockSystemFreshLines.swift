import Foundation

/// The system's current figures for a few asked-about items, read for a `check` while the snapshot
/// is older than `StockSystemPolicy.checkNowAfter` (Plan MM §2, Decision 10). Still the system's own
/// strings: the merge converts them with each line's unit, as a pull does.
struct StockSystemFreshLines: Equatable, Sendable {
    /// The items asked for. An asked item with no figure at an asked location has no count there.
    let itemIDs: [String]
    /// The locations asked at.
    let locationIDs: [String]
    /// Each figure the system gave, by item id and then location id, as its decimal text.
    let counts: [String: [String: String]]

    init(itemIDs: [String], locationIDs: [String], counts: [String: [String: String]]) {
        self.itemIDs = itemIDs
        self.locationIDs = locationIDs
        self.counts = counts
    }
}

extension StockSystemSnapshot {

    /// This snapshot with `fresh` merged in, read at `readAt` (Plan MM §2). Only the asked lines
    /// change, and only their levels at the asked locations: each figure goes through
    /// `StockSystemQuantityConversion` in the line's own unit, so one the phone cannot hold exactly
    /// is unknown with its reason, and an asked location with no figure has no count (or keeps the
    /// reason it already had for having none). The changed
    /// lines are dated `readAt` (`lineAsOf`); the snapshot's own `asOf` stays the pull's.
    ///
    /// A line whose unit the phone could not map keeps its figures, which are already unknown. A
    /// line already dated at or after `readAt` (a newer pull, or a newer check) is left as it is,
    /// so a late reply never puts older figures over newer ones. An item the snapshot does not hold
    /// is not added: it comes with the next pull. Nil when nothing changed.
    func merging(_ fresh: StockSystemFreshLines, readAt: Date) -> StockSystemSnapshot? {
        let asked = Set(fresh.itemIDs)
        let places = Set(fresh.locationIDs)
        guard !asked.isEmpty, !places.isEmpty else { return nil }
        var changed = false
        let merged = lines.map { line -> Line in
            guard asked.contains(line.itemID), let unit = line.unit,
                  readAt > (line.lineAsOf ?? asOf) else { return line }
            let levels = line.levels.map { level -> Level in
                guard places.contains(level.locationID) else { return level }
                let text = fresh.counts[line.itemID]?[level.locationID]
                // No figure where none was known keeps the reason already given.
                if text == nil, case .unknown = level.value { return level }
                return Level(locationID: level.locationID,
                             value: StockSystemQuantityConversion.incoming(text, unit: unit))
            }
            changed = true
            return Line(itemID: line.itemID, part: line.part, description: line.description, unit: line.unit,
                        systemUnit: line.systemUnit, levels: levels, provenance: line.provenance, lineAsOf: readAt,
                        price: line.price, reorderPoint: line.reorderPoint, decimalPlaces: line.decimalPlaces)
        }
        guard changed else { return nil }
        return StockSystemSnapshot(source: source, asOf: asOf, locations: locations, lines: merged)
    }

    /// Whether the figures for `itemIDs` are older than `age` at `now`: the newest date any of them
    /// carries, or the snapshot's. An item it does not hold counts as old.
    func isOlder(than age: TimeInterval, for itemIDs: [String], now: Date) -> Bool {
        let held = itemIDs.compactMap { id in lines.first { $0.itemID == id } }
        guard held.count == itemIDs.count, !held.isEmpty else { return true }
        return held.contains { now.timeIntervalSince($0.lineAsOf ?? asOf) > age }
    }
}

/// How a `check`'s live read of its lines went (Plan MM Decision 10).
enum StockSystemCheckNow: Equatable, Sendable {
    /// The lines came back within the budget and are in the store.
    case fresh
    /// The budget ran out first. The answer is the snapshot's, with its age; a reply that comes
    /// later only refreshes the store.
    case late
    /// Not asked: there was no need, or no way.
    case skipped(Skip)
    /// The read failed in time. The answer is the snapshot's, with its age.
    case failed

    enum Skip: Equatable, Sendable {
        /// No running connection, or no location chosen.
        case notConnected
        /// The figures are younger than `StockSystemPolicy.checkNowAfter`.
        case recent
        /// No signal.
        case offline
        /// Medical Local Only holds the system's route.
        case localOnly
        /// Nothing the snapshot holds was asked about.
        case nothingAsked
    }
}
