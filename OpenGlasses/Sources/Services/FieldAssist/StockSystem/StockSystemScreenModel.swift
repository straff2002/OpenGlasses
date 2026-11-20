import Foundation

/// What the Stock screen shows while a business's own system holds the count (Plan MM P3). Pure.
///
/// The system's figures, read-only, as of the snapshot's time; a figure the phone cannot hold is
/// shown as unknown with the reason, never as 0; the snapshot's age said plainly once it is
/// stale; and the uses noted for the open job, or at premises for today's list, still to be
/// confirmed. Vendor-neutral: the system's name comes from the snapshot.
struct StockSystemScreenModel: Equatable {

    /// One of the system's lines at this place.
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        /// The part number, when the description is not already it.
        let detail: String?
        /// "3", "12.5 l"; nil when the system's figure is not known on the phone.
        let figure: String?
        /// Why the figure is not known; nil when it is.
        let unknownReason: String?
        /// At or below the system's reorder point, or at none when it has none.
        let isLow: Bool
    }

    /// One use noted and not yet sent.
    struct Noted: Identifiable, Equatable {
        let id: String
        let name: String
        let amount: String
        /// Written off as damaged rather than used.
        let writtenOff: Bool
    }

    let system: String
    /// Nil until the phone has figures from the system.
    let asOf: Date?
    /// "These figures are older than a day." Nil while they are not.
    let staleLine: String?
    let rows: [Row]
    /// What the noted list is: "Noted on job 1027", "Noted on this job", "Noted today".
    let notedTitle: String?
    let noted: [Noted]

    var hasFigures: Bool { asOf != nil }

    init(snapshot: StockSystemSnapshot?, system: String, here: [String], noted entries: [StagedStockUseEntry],
         scope: StagedStockUseEntry.Scope?, jobReference: String?, now: Date, query: String = "",
         locale: Locale = .current) {
        self.system = snapshot?.source.displayName ?? system
        asOf = snapshot?.asOf
        if let snapshot, now.timeIntervalSince(snapshot.asOf) > StockSystemPolicy.staleAfter {
            staleLine = String(localized: "These figures are older than a day. Pull down to read them again.")
        } else {
            staleLine = nil
        }
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let name = self.system
        rows = (snapshot?.lines ?? [])
            .filter { line in
                let haystack = [line.description, line.part ?? ""].joined(separator: " ").lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
            .map { line in Self.row(line, here: here, system: name, locale: locale) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        switch scope {
        case .job?:
            notedTitle = jobReference.map { String(localized: "Noted on job \($0)") } ?? String(localized: "Noted on this job")
        case .day?:
            notedTitle = String(localized: "Noted today")
        case nil:
            notedTitle = nil
        }
        noted = scope.map { scope in
            // Only what still waits for a person: lines on their way, sent or kept on the phone
            // are said by the job's states (Plan MM P4).
            entries.filter { $0.scope == scope && $0.isAwaitingConfirmation }.map { entry in
                Noted(id: entry.id, name: entry.use.name,
                      amount: VanStockRow.figure(entry.use.quantity, unit: entry.use.unit, locale: locale),
                      writtenOff: entry.reason != nil)
            }
        } ?? []
    }

    static func row(_ line: StockSystemSnapshot.Line, here: [String], system: String, locale: Locale) -> Row {
        let values = here.map { line.level(at: $0) ?? .unknown(.noCount) }
        let known = values.compactMap(\.quantity)
        let described = line.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = described.isEmpty ? (line.part ?? line.itemID) : described
        let detail = described.isEmpty ? nil : line.part
        guard !known.isEmpty, let unit = line.unit else {
            let reason = values.compactMap { value -> StockSystemUnknownReason? in
                if case .unknown(let reason) = value { return reason }
                return nil
            }.first { $0 != .noCount } ?? .noCount
            return Row(id: line.itemID, name: name, detail: detail, figure: nil,
                       unknownReason: Self.reason(reason, system: system), isLow: false)
        }
        let total = known.reduce(StockQuantity.zero, +)
        let isLow = line.reorderPoint.map { total <= $0 } ?? (total == .zero)
        return Row(id: line.itemID, name: name, detail: detail, figure: VanStockRow.figure(total, unit: unit, locale: locale),
                   unknownReason: nil, isLow: isLow)
    }

    /// Why a figure is not shown, in a few words.
    static func reason(_ reason: StockSystemUnknownReason, system: String) -> String {
        switch reason {
        case .noCount: return String(localized: "No count in \(system)")
        case .unmappedUnit(let raw):
            return raw.isEmpty ? String(localized: "Counted in a unit the phone doesn't keep")
                               : String(localized: "Counted in “\(raw)”, a unit the phone doesn't keep")
        case .tooManyDecimals: return String(localized: "Held to more decimal places than the phone keeps")
        case .notWhole: return String(localized: "Not a whole number in \(system)")
        case .negative: return String(localized: "Below zero in \(system)")
        case .tooLarge: return String(localized: "More than a million in \(system)")
        case .notANumber: return String(localized: "The figure couldn't be read")
        }
    }
}
