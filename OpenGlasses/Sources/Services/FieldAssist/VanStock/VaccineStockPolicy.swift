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
}
