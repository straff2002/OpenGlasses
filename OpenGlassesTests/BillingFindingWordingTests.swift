import XCTest
@testable import OpenGlasses

/// Plan NJ §4 — the billing-export check as the Stock screen shows it: a dose given here and not
/// billed reads as a likely missed claim, a claim with no dose here as a stock figure that may be
/// high, and a tariff several lines carry as "billed under a shared code", left for staff. Every
/// name, tariff and lot here is invented.
final class BillingFindingWordingTests: XCTestCase {

    private let day22 = StockDay(year: 2026, month: 11, day: 22)!
    private let day23 = StockDay(year: 2026, month: 11, day: 23)!

    private lazy var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var items: [VanStockItem] {
        var log = VanStockLog()
        _ = log.addItem(id: "flu", number: "9001", description: "Examplevax", batch: "b")
        _ = log.addItem(id: "mmr", number: "9002", description: "Samplemune", batch: "b")
        _ = log.addItem(id: "zos", number: "9050", description: "Testazos", batch: "b")
        _ = log.addItem(id: "rsv", number: "9050", description: "Mockarsv", batch: "b")
        return log.items
    }

    private var wording: BillingFindingWording { BillingFindingWording(items: items) }

    private func compare(doses: [ImmunisationReconciliation.Dose], records: [BillingRecord],
                         hasLot: Bool = false) -> BillingReconciliation {
        BillingReconciliation.compare(doses: doses, records: records, hasLot: hasLot, items: items,
                                      first: day22, last: day23, calendar: calendar)
    }

    // MARK: - Findings

    func testADoseNotBilledReadsAsAMissedClaim() {
        let finding = ImmunisationReconciliation.Finding.givenNotInEMR(itemID: "mmr", day: day22, lot: "", count: 1)
        let text = wording.sentence(finding)
        XCTAssertTrue(text.hasPrefix("1 dose of Samplemune (9002) on "), text)
        XCTAssertTrue(text.hasSuffix("was given here but not billed that day."), text)
        XCTAssertFalse(text.contains("EMR"), "a bill is not the EMR's record: \(text)")
        XCTAssertFalse(text.contains("lot"), "with no lot column no lot is mentioned")
    }

    func testAClaimWithNoDoseHereMayMeanTheStockIsHigh() {
        let text = wording.sentence(.inEMRNotGiven(itemID: "flu", day: day22, lot: "ZZ3001", count: 2))
        XCTAssertTrue(text.contains("2 doses of Examplevax"), text)
        XCTAssertTrue(text.contains("lot ZZ3001"), text)
        XCTAssertTrue(text.hasSuffix("were billed but not recorded as given here, so the stock figure may be high."), text)
    }

    func testADifferentLotAndANearbyDayAreSaidPlainly() {
        XCTAssertTrue(wording.sentence(.differentLot(itemID: "flu", day: day22, here: "ZZ3001", emr: "ZZ3009", count: 1))
            .contains("recorded here from lot ZZ3001 and billed under lot ZZ3009"))
        XCTAssertTrue(wording.sentence(.nearby(itemID: "flu", here: day22, emr: day23, lot: "", count: 1))
            .hasSuffix("nearby, not missing."))
    }

    // MARK: - A shared code

    func testASharedCodeIsBilledUnderASharedCodeAndLeftForStaff() {
        let result = compare(doses: [.init(itemID: "zos", day: day22, lot: "", count: 1)],
                             records: [BillingRecord(day: day22, tariff: "9050", lot: ""),
                                       BillingRecord(day: day22, tariff: "9050", lot: "")])
        XCTAssertEqual(result.sharedCodes.count, 1)
        let text = wording.sentence(result.sharedCodes[0])
        XCTAssertEqual(text, "2 claims were billed under a shared code, 9050, which 2 lines carry: Testazos and Mockarsv. "
                       + "They are left for staff to assign, and those lines are left out of the check.")
        XCTAssertTrue(wording.summary(result).hasSuffix(" 2 claims were billed under a shared code."), wording.summary(result))
    }

    // MARK: - The summary

    func testTheSummarySaysEveryDoseWasBilledOrWhatDiffers() {
        let matched = compare(doses: [.init(itemID: "flu", day: day22, lot: "", count: 2)],
                              records: [BillingRecord(day: day22, tariff: "9001", lot: ""),
                                        BillingRecord(day: day22, tariff: "9001", lot: "")])
        XCTAssertTrue(wording.summary(matched).hasSuffix("every dose given here was billed (2 doses)."), wording.summary(matched))

        let missed = compare(doses: [.init(itemID: "flu", day: day22, lot: "", count: 1),
                                     .init(itemID: "mmr", day: day22, lot: "", count: 1)],
                             records: [BillingRecord(day: day22, tariff: "9001", lot: "")])
        XCTAssertTrue(wording.summary(missed).hasSuffix(": 1 dose given here not billed that day."), wording.summary(missed))
        XCTAssertTrue(wording.summary(missed).hasPrefix("From "), "the check spans the export's days")
    }

    // MARK: - The columns

    func testTheCheckRunsOnlyWithADifferentColumnForEach() {
        XCTAssertTrue(BillingColumnMapping(date: "Service date", tariff: "Fee code", lot: nil).isChoosable)
        XCTAssertTrue(BillingColumnMapping(date: "Service date", tariff: "Fee code", lot: "Lot").isChoosable)
        XCTAssertFalse(BillingColumnMapping(date: "Fee code", tariff: "Fee code", lot: nil).isChoosable)
        XCTAssertFalse(BillingColumnMapping(date: "Service date", tariff: "Fee code", lot: "Fee code").isChoosable)
        XCTAssertFalse(BillingColumnMapping(date: "", tariff: "Fee code", lot: nil).isChoosable)
    }
}
