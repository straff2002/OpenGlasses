import Foundation

/// The billing-export check's findings in words (Plan NJ §4, MY Decision 13): which doses given
/// here were not billed, which claims have no dose recorded here, and which claims were billed
/// under a code several lines share. The EMR check's wording (`ImmunisationFindingWording`) says
/// "in the EMR"; a bill says "billed", so a likely missed claim reads as one. Never a patient, a
/// claim number or a fee: the reader never read them. Pure.
struct BillingFindingWording {
    let items: [VanStockItem]

    private func name(_ itemID: String) -> String {
        items.first { $0.id == itemID }?.name ?? "A line no longer on the list"
    }

    private func doses(_ count: Int) -> String { count == 1 ? "1 dose" : "\(count) doses" }

    private func claims(_ count: Int) -> String { count == 1 ? "1 claim" : "\(count) claims" }

    /// With no lot column the comparison is by day and line, so a lot is not mentioned at all.
    private func lotText(_ lot: String) -> String { lot.isEmpty ? "" : ", lot \(lot)," }

    func sentence(_ finding: ImmunisationReconciliation.Finding) -> String {
        switch finding {
        case .givenNotInEMR(let itemID, let day, let lot, let count):
            return "\(doses(count)) of \(name(itemID)) on \(day.spoken)\(lotText(lot)) "
                + "\(count == 1 ? "was" : "were") given here but not billed that day."
        case .inEMRNotGiven(let itemID, let day, let lot, let count):
            return "\(doses(count)) of \(name(itemID)) on \(day.spoken)\(lotText(lot)) "
                + "\(count == 1 ? "was" : "were") billed but not recorded as given here, so the stock figure may be high."
        case .differentLot(let itemID, let day, let here, let billed, let count):
            return "On \(day.spoken), \(doses(count)) of \(name(itemID)) "
                + "\(count == 1 ? "was" : "were") recorded here from lot \(here.isEmpty ? "(none)" : here) "
                + "and billed under lot \(billed.isEmpty ? "(none)" : billed). One of the two records likely has a typo."
        case .nearby(let itemID, let here, let billed, let lot, let count):
            return "\(doses(count)) of \(name(itemID))\(lotText(lot)) given here on \(here.spoken) "
                + "\(count == 1 ? "was" : "were") billed on \(billed.spoken): nearby, not missing."
        }
    }

    /// "3 claims were billed under a shared code, G538, which 2 lines carry: A and B. They are left
    /// for staff to assign, and those lines are left out of the check."
    func sentence(_ shared: BillingReconciliation.SharedCode) -> String {
        // The sentence already names the shared code, which every one of these lines carries as its
        // number, so each line is named by its description alone ("Testazos", not "Testazos (9050)").
        let names = shared.itemIDs.map { id in
            let described = items.first { $0.id == id }?.description.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return described.isEmpty ? name(id) : described
        }
        let list: String
        switch names.count {
        case 0: list = ""
        case 1: list = names[0]
        default: list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        return "\(claims(shared.rows)) \(shared.rows == 1 ? "was" : "were") billed under a shared code, \(shared.tariff), "
            + "which \(shared.itemIDs.count) lines carry: \(list). "
            + "They are left for staff to assign, and those lines are left out of the check."
    }

    /// One sentence for the whole check.
    func summary(_ result: BillingReconciliation) -> String {
        let reconciliation = result.reconciliation
        let s = reconciliation.summary(ranAt: Date(timeIntervalSince1970: 0))
        let span = reconciliation.first == reconciliation.last
            ? "On \(reconciliation.first.spoken)"
            : "From \(reconciliation.first.spoken) to \(reconciliation.last.spoken)"
        var text: String
        if s.differences == 0, s.nearby == 0 {
            text = "\(span), every dose given here was billed (\(doses(reconciliation.matched)))."
        } else {
            var parts: [String] = []
            if s.givenNotInEMR > 0 { parts.append("\(doses(s.givenNotInEMR)) given here not billed that day") }
            if s.inEMRNotGiven > 0 { parts.append("\(doses(s.inEMRNotGiven)) billed not recorded as given here") }
            if s.differentLot > 0 { parts.append("\(doses(s.differentLot)) billed under a different lot") }
            if s.nearby > 0 { parts.append("\(doses(s.nearby)) billed on a nearby day") }
            text = "\(span): " + parts.joined(separator: ", ") + "."
        }
        let sharedRows = result.sharedCodes.reduce(0) { $0 + $1.rows }
        if sharedRows > 0 {
            text += " \(claims(sharedRows)) \(sharedRows == 1 ? "was" : "were") billed under a shared code."
        }
        return text
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
