import Foundation

/// The billing-export check's findings in words (Plan NJ §4, MY Decision 13): which doses given
/// here were not billed, which claims have no dose recorded here, and which claims were billed
/// under a code several lines share. The EMR check's wording (`ImmunisationFindingWording`) says
/// "in the EMR"; a bill says "billed", so a likely missed claim reads as one. Never a patient, a
/// claim number or a fee: the reader never read them. Screen text, localised, with each sentence
/// opening with its count as the EMR check's do: the model never reads a check.
struct BillingFindingWording {
    let items: [VanStockItem]

    /// With no lot column the comparison is by day and line, so a lot is not mentioned at all.
    private func line(_ itemID: String, lot: String) -> String {
        let name = StockCheckText.line(itemID, in: items)
        return lot.isEmpty ? name : StockCheckText.withLot(name, lot)
    }

    func sentence(_ finding: ImmunisationReconciliation.Finding) -> String {
        switch finding {
        case .givenNotInEMR(let itemID, let day, let lot, let count):
            let (line, on) = (line(itemID, lot: lot), StockScanText.day(day))
            return count == 1
                ? String(localized: "1 dose of \(line) given here on \(on) was not billed that day.")
                : String(localized: "\(count) doses of \(line) given here on \(on) were not billed that day.")
        case .inEMRNotGiven(let itemID, let day, let lot, let count):
            let (line, on) = (line(itemID, lot: lot), StockScanText.day(day))
            return count == 1
                ? String(localized: "1 dose of \(line) billed on \(on) was not recorded as given here, so the stock figure may be high.")
                : String(localized: "\(count) doses of \(line) billed on \(on) were not recorded as given here, so the stock figure may be high.")
        case .differentLot(let itemID, let day, let here, let billed, let count):
            let (line, on) = (StockCheckText.line(itemID, in: items), StockScanText.day(day))
            let (hereLot, billedLot) = (StockCheckText.lot(here), StockCheckText.lot(billed))
            return count == 1
                ? String(localized: "1 dose of \(line) on \(on) was recorded here from lot \(hereLot) and billed under lot \(billedLot). One of the two records likely has a typo.")
                : String(localized: "\(count) doses of \(line) on \(on) were recorded here from lot \(hereLot) and billed under lot \(billedLot). One of the two records likely has a typo.")
        case .nearby(let itemID, let here, let billed, let lot, let count):
            let line = line(itemID, lot: lot)
            let (given, billedOn) = (StockScanText.day(here), StockScanText.day(billed))
            return count == 1
                ? String(localized: "1 dose of \(line) given here on \(given) was billed on \(billedOn): nearby, not missing.")
                : String(localized: "\(count) doses of \(line) given here on \(given) were billed on \(billedOn): nearby, not missing.")
        }
    }

    /// "3 claims were billed under a shared code, G538, carried by these lines: A and B. They are
    /// left for staff to assign, and those lines are left out of the check."
    func sentence(_ shared: BillingReconciliation.SharedCode) -> String {
        // The sentence already names the shared code, which every one of these lines carries as its
        // number, so each line is named by its description alone ("Testazos", not "Testazos (9050)").
        let names = shared.itemIDs.map { id in
            let described = items.first { $0.id == id }?.description.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return described.isEmpty ? StockCheckText.line(id, in: items) : described
        }
        let (code, lines, count) = (shared.tariff, names.formatted(.list(type: .and)), shared.rows)
        return count == 1
            ? String(localized: "1 claim was billed under a shared code, \(code), carried by these lines: \(lines). It is left for staff to assign, and those lines are left out of the check.")
            : String(localized: "\(count) claims were billed under a shared code, \(code), carried by these lines: \(lines). They are left for staff to assign, and those lines are left out of the check.")
    }

    /// The whole check: one sentence on the doses, and one on its own line for any shared code.
    func summary(_ result: BillingReconciliation) -> String {
        let doses = dosesSummary(result.reconciliation)
        let count = result.sharedCodes.reduce(0) { $0 + $1.rows }
        guard count > 0 else { return doses }
        let shared = count == 1 ? String(localized: "1 claim was billed under a shared code.")
                                : String(localized: "\(count) claims were billed under a shared code.")
        return doses + "\n" + shared
    }

    private func dosesSummary(_ result: ImmunisationReconciliation) -> String {
        let s = result.summary(ranAt: Date(timeIntervalSince1970: 0))
        if s.differences == 0, s.nearby == 0 {
            let matched = StockCheckText.doses(result.matched)
            let first = StockScanText.day(result.first)
            guard result.first != result.last else {
                return String(localized: "On \(first), every dose given here was billed (\(matched)).")
            }
            let last = StockScanText.day(result.last)
            return String(localized: "From \(first) to \(last), every dose given here was billed (\(matched)).")
        }
        var parts: [String] = []
        if s.givenNotInEMR > 0 {
            let count = s.givenNotInEMR
            parts.append(count == 1 ? String(localized: "1 dose given here but not billed that day")
                                    : String(localized: "\(count) doses given here but not billed that day"))
        }
        if s.inEMRNotGiven > 0 {
            let count = s.inEMRNotGiven
            parts.append(count == 1 ? String(localized: "1 dose billed but not recorded as given here")
                                    : String(localized: "\(count) doses billed but not recorded as given here"))
        }
        if s.differentLot > 0 {
            let count = s.differentLot
            parts.append(count == 1 ? String(localized: "1 dose billed under a different lot")
                                    : String(localized: "\(count) doses billed under a different lot"))
        }
        if s.nearby > 0 {
            let count = s.nearby
            parts.append(count == 1 ? String(localized: "1 dose billed on a nearby day")
                                    : String(localized: "\(count) doses billed on a nearby day"))
        }
        return StockCheckText.differences(parts, from: result.first, to: result.last)
    }
}

extension BillingColumnMapping {
    /// Whether the sheet's Check can run: a different column each for the date and the tariff, and
    /// for the lot when the export has one.
    var isChoosable: Bool {
        let chosen = [date, tariff] + (lot.map { [$0] } ?? [])
        return !chosen.contains(where: \.isEmpty) && Set(chosen).count == chosen.count
    }
}
