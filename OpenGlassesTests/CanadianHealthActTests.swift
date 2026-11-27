import XCTest
@testable import OpenGlasses

/// Plan NJ §8, Decision 6 — Canada's health acts by name: every province and territory has an
/// act, a supplier's name, an agreement, a breach rule and a PIA flag; Ontario, Nova Scotia, New
/// Brunswick and Newfoundland and Labrador never report to the federal commissioner; and every
/// duty an inventory-only stock list does not trigger says so.
final class CanadianHealthActTests: XCTestCase {

    func testEveryProvinceAndTerritoryHasAnActAndItsDuties() {
        XCTAssertEqual(CanadianJurisdiction.allCases.count, 13)
        for act in CanadianHealthAct.all {
            let place = act.jurisdiction.rawValue
            XCTAssertFalse(act.act.isEmpty, place)
            XCTAssertFalse(act.shortName.isEmpty, place)
            XCTAssertFalse(act.vendorTerm.isEmpty, place)
            XCTAssertFalse(act.agreement.isEmpty, place)
            XCTAssertFalse(act.breachNotice.isEmpty, place)
            XCTAssertFalse(act.jurisdiction.name.isEmpty, place)
            XCTAssertGreaterThanOrEqual(act.duties.count, 2, place)
        }
    }

    func testTheTableReadsAsThePlanSetsItOut() {
        XCTAssertEqual(CanadianHealthAct.act(for: .britishColumbia).shortName, "PIPA")
        XCTAssertEqual(CanadianHealthAct.act(for: .alberta).shortName, "HIA")
        XCTAssertEqual(CanadianHealthAct.act(for: .saskatchewan).shortName, "HIPA")
        XCTAssertEqual(CanadianHealthAct.act(for: .manitoba).shortName, "PHIA")
        XCTAssertEqual(CanadianHealthAct.act(for: .ontario).shortName, "PHIPA")
        XCTAssertEqual(CanadianHealthAct.act(for: .quebec).shortName, "R-22.1")
        XCTAssertEqual(CanadianHealthAct.act(for: .newBrunswick).shortName, "PHIPAA")
        XCTAssertEqual(CanadianHealthAct.act(for: .yukon).shortName, "HIPMA")
        XCTAssertEqual(CanadianHealthAct.act(for: .nunavut).shortName, "PIPEDA")
        XCTAssertEqual(CanadianHealthAct.act(for: .alberta).breachRecipients, [.commissioner, .minister, .individual])
        XCTAssertEqual(CanadianHealthAct.act(for: .manitoba).breachRecipients, [.ombudsman, .individual])
        XCTAssertEqual(CanadianHealthAct.act(for: .quebec).breachRecipients, [.accessCommission, .minister])
        XCTAssertEqual(CanadianHealthAct.act(for: .newBrunswick).breachRecipients, [.ombud])
        XCTAssertTrue(CanadianHealthAct.act(for: .britishColumbia).breachRecipients.isEmpty, "no mandatory notice")
        XCTAssertTrue(CanadianHealthAct.act(for: .saskatchewan).breachRecipients.isEmpty, "no statutory notice")
    }

    func testOntarioNovaScotiaNewBrunswickAndNewfoundlandNeverReportToTheOPC() {
        for place in [CanadianJurisdiction.ontario, .novaScotia, .newBrunswick, .newfoundlandAndLabrador] {
            let act = CanadianHealthAct.act(for: place)
            XCTAssertFalse(act.breachRecipients.contains(.federalCommissioner), place.rawValue)
            XCTAssertFalse(act.breachRecipients.isEmpty, place.rawValue)
            XCTAssertFalse(act.breachNotice.contains("Office of the Privacy Commissioner of Canada"), place.rawValue)
        }
        XCTAssertTrue(CanadianHealthAct.act(for: .nunavut).breachRecipients.contains(.federalCommissioner),
                      "Nunavut falls under PIPEDA")
    }

    func testThePIAAndUserActivityDutiesAreWhereTheActsPutThem() {
        XCTAssertEqual(CanadianHealthAct.act(for: .alberta).pia, .submitToCommissioner)
        XCTAssertEqual(CanadianHealthAct.act(for: .quebec).pia, .beforeLeavingProvince)
        XCTAssertEqual(CanadianHealthAct.all.filter { $0.pia != .none }.map(\.jurisdiction), [.alberta, .quebec])
        XCTAssertEqual(CanadianHealthAct.all.filter(\.userActivityLog).map(\.jurisdiction), [.manitoba, .novaScotia])
        XCTAssertEqual(CanadianHealthAct.all.filter(\.pipedaAlsoApplies).map(\.jurisdiction), [.princeEdwardIsland, .nunavut])
    }

    func testEveryDutyAnInventoryOnlyListDoesNotTriggerSaysSo() {
        let phrase = CanadianHealthAct.notNeededWhileInventoryOnly
        XCTAssertEqual(phrase, "not needed while the stock list is inventory-only")
        for act in CanadianHealthAct.all {
            let agreement = act.duties[0]
            XCTAssertTrue(agreement.contains(phrase), "\(act.jurisdiction.rawValue): \(agreement)")
            XCTAssertTrue(agreement.contains(act.vendorTerm), agreement)
            for duty in act.duties where duty.contains("privacy impact assessment") || duty.contains("user activity") {
                XCTAssertTrue(duty.contains(phrase), duty)
            }
        }
        XCTAssertTrue(CanadianHealthAct.act(for: .princeEdwardIsland).duties.contains { $0.contains("24 months") })
    }

    func testTheCanadaEntryFollowsTheProvincePicked() {
        XCTAssertTrue(MedicalFramework.allCases.contains(.pipeda), "the federal act keeps its own entry")
        let framework = MedicalFramework.canadianHealthActs
        XCTAssertEqual(framework.organisationalRequirements(in: .alberta), CanadianHealthAct.act(for: .alberta).duties)
        XCTAssertEqual(framework.organisationalRequirements(in: .quebec), CanadianHealthAct.act(for: .quebec).duties)
        XCTAssertEqual(MedicalFramework.hipaa.organisationalRequirements(in: .alberta), MedicalFramework.hipaa.organisationalRequirements,
                       "only the Canada entry reads the province")
        XCTAssertEqual(framework.flag, "🇨🇦")
        XCTAssertFalse(framework.coveredSafeguards.isEmpty)
    }

    func testPIPEDAsBreachLineNamesTheProvincialCommissioners() {
        let line = MedicalFramework.pipeda.organisationalRequirements.first { $0.contains("breach") } ?? ""
        XCTAssertNotEqual(line, "Privacy breach reporting to OPC")
        for place in ["Ontario", "Nova Scotia", "New Brunswick", "Newfoundland and Labrador"] {
            XCTAssertTrue(line.contains(place), place)
        }
        XCTAssertTrue(line.contains("provincial commissioner"))
    }
}
