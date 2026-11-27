import Foundation

/// The twelve decisions of the vaccine stock plan (Plan MY), each in one place so it can be
/// changed later. Every one is the plan's recommendation (owner, 2026-11-22: "build it").
///
/// Some are a value read by the code; the rest are the shape of the code itself, named here so a
/// reader knows where each lives.
enum VaccineStockPolicy {

    // 1. Patient identity: none in the app. `van_stock` takes no patient argument and movements
    //    carry no free text; `VaccineStockPrivacyGuardTests` fails on either.

    // 2. Lots: a lot belongs to a line (`StockLot.itemID`), never a line per lot.

    // 3. Waste: its own movement kind (`VanStockMovement.Kind.wasted`) with clinical reasons
    //    (`WasteReason`), never a removal reason, so a report cannot mix returns with waste.

    /// 4. A dose given from an expired lot is not recorded as given; the answer offers to record
    ///    it as wasted · expired instead.
    static let refusesExpiredGiven = true

    /// 5. A dose is one `each`; a line remembers doses per carton the first time it is received.
    static let doseUnit = VanStockUnit.each

    /// 6. Funded and private stock: two lines that share a product code. A scan asks which line
    ///    when more than one of them could be meant (both hold the lot, or neither does).
    static let asksWhichLineForASharedProductCode = true

    /// 7. The place: the neutral `stock` kind, with the clinic's own name for the list.
    static let suggestedPlace = StockPlace.Kind.stock

    // 8. The check against the clinic's records (P3): only while medical mode is on.

    // 9. Where the clinic's own system already counts the stock: Plan MM's pattern, a later plan.

    /// 10. The phone (or a shared iPad at the fridge), not the glasses, for the pilot. The scan
    ///     sheet uses the phone's camera; nothing here reads the glasses camera.
    static let scansWithThePhoneOnly = true

    // 11. The weekly count reminder (P2): a local notification, off until the clinic chooses.

    /// 12. Clinical wording: a flag on the list, set and locked by the organisation profile key
    ///     `organizationStockClinical` when a profile sets it.
    static let clinicalProfileKey = SettingKey.organizationStockClinical

    // MARK: - Values the plan gives

    /// "Expiring soon" is within this many days (Plan MY §4; open question 9 for the clinic).
    static let expiringSoonDays = 30

    /// The same code scanned again within this many seconds asks "Another one?" (Plan MY §5).
    static let repeatScanWindow: TimeInterval = 10

    /// The older lot in the fridge is pointed out at most once a day per line (Plan MY §4).
    static let oldestFirstOncePerDay = true

    // MARK: - Inventory only (Plan NJ, owner 2026-11-27: every decision as recommended)

    /// NJ Decision 4: a clinical list keeps four years of movements (1,461 days) until the
    /// clinic's province sets its own figure; Quebec's is four years, the longest found. A van
    /// keeps 400 days, as it always has. Levels are exact either way; only history folds.
    nonisolated static let clinicalHistoryDays = 1_461
    nonisolated static let vanHistoryDays = 400

    /// How many days of movements a list keeps before they fold into its opening figure.
    nonisolated static func historyDays(clinical: Bool) -> Int {
        clinical ? clinicalHistoryDays : vanHistoryDays
    }

    /// NJ Decision 5: in a clinical list's reports and exports, a figure from 1 to 4 prints as
    /// "fewer than 5", and a line marked sensitive is shown by the week, not the day. The phone's
    /// own Stock screen shows the exact count to the person holding it.
    nonisolated static let smallCellThreshold = 5

    // NJ Decision 1: what a clinical list shares is one row per day, line, lot, kind and reason
    // (`ClinicalStockShareRow`), never a movement with its time.
    // NJ Decision 2: the phone keeps its own minute timestamps; the daily check and the count's
    // order need them.
    // NJ Decision 3: no staff on a dose given; a clinic's own code on a waste, a removal or a count
    // that disagreed (`VanStockMovement.staffCode`), kept on the phone and never shared.
    // NJ Decision 6: Canada is one framework with a province picker (`CanadianHealthAct`).
    // NJ Decision 7: the vaccine records of NJ §9 (funding and supply source, returns, recall
    // lookup, order form) are deferred.
}

/// The support report's lines for a clinic's stock and the medical mode's pins (Plan NJ P1): the
/// history window in force, what a clinical list shares, and which Medical Compliance settings an
/// organisation pinned. Case names and numbers only; never a line, a lot or a figure. Pure.
enum ClinicalStockReportLines {

    static func lines(clinical: Bool, clinicalSetByOrganisation: Bool, pinnedMode: Bool, pinnedLocalOnly: Bool,
                      retentionCeilingDays: Int?) -> [String] {
        var stock = "Stock list: " + (clinical ? "clinical" : "not clinical")
        if clinicalSetByOrganisation { stock += " (set by the organisation)" }
        stock += ", history kept \(VaccineStockPolicy.historyDays(clinical: clinical)) days"
        if clinical {
            stock += ", shared inventory-only (by day; sensitive lines by week; figures under "
                + "\(VaccineStockPolicy.smallCellThreshold) as fewer than \(VaccineStockPolicy.smallCellThreshold))"
        }
        var pins: [String] = []
        if pinnedMode { pins.append("hipaaMode on") }
        if pinnedLocalOnly { pins.append("hipaaLocalOnly on") }
        if let retentionCeilingDays { pins.append("hipaaRetentionDays at most \(retentionCeilingDays)") }
        return [stock, "Medical Compliance pinned by the organisation: " + (pins.isEmpty ? "none" : pins.joined(separator: ", "))]
    }

    /// The lines for this phone now.
    @MainActor static var current: [String] {
        let clinical = VanStockStore.shared.resolvedClinical
        return lines(clinical: clinical.clinical, clinicalSetByOrganisation: clinical.isLocked,
                     pinnedMode: PolicyEnvelope.isLocked(.hipaaMode),
                     pinnedLocalOnly: PolicyEnvelope.isLocked(.hipaaLocalOnly),
                     retentionCeilingDays: Config.hipaaRetentionCeilingDays)
    }
}
