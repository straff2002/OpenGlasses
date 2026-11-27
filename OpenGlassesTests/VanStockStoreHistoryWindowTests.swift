import XCTest
@testable import OpenGlasses

/// Plan NJ §5, Decision 4 — the history window comes from the list: a clinic's keeps four years
/// (1,461 days), a van's 400. Nothing inside the window is folded or deleted, and levels are exact
/// either way.
@MainActor
final class VanStockStoreHistoryWindowTests: XCTestCase {

    private var directory: URL!
    // 2026-11-22 10:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_795_341_600)
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-window-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// A list written long ago with movements at the given ages, then opened again today.
    private func reopened(clinicalList: Bool?, profile: Bool?, ages: [Double]) -> VanStockStore {
        let first = VanStockStore(directory: directory, now: daysAgo(2_000), profileClinical: .some(nil))
        first.update { log in
            _ = log.addItem(id: "flu", description: "Flu vaccine", batch: "b0")
            for (index, age) in ages.enumerated() {
                log.record(.loaded, itemID: "flu", quantity: StockQuantity(whole: 1), at: daysAgo(age), batch: "b\(index)",
                           source: .typed, id: "m\(index)")
            }
        }
        first.setClinical(clinicalList)
        return VanStockStore(directory: directory, now: now, profileClinical: .some(profile))
    }

    func testThePolicyGivesFourYearsToAClinicAnd400DaysToAVan() {
        XCTAssertEqual(VaccineStockPolicy.clinicalHistoryDays, 1_461)
        XCTAssertEqual(VaccineStockPolicy.historyDays(clinical: true), 1_461)
        XCTAssertEqual(VaccineStockPolicy.historyDays(clinical: false), 400)
        XCTAssertEqual(VanStockStore.historyDays, 400, "a van's window is what it always was")
    }

    func testTheWindowFollowsTheProfileOverTheListsOwnFlag() {
        let clinic = VanIdentity(id: "v", name: "Fridge", clinical: true)
        let van = VanIdentity(id: "v", name: "Truck")
        XCTAssertEqual(VanStockStore.historyWindow(for: clinic, profileClinical: nil), 1_461)
        XCTAssertEqual(VanStockStore.historyWindow(for: van, profileClinical: nil), 400)
        XCTAssertEqual(VanStockStore.historyWindow(for: nil, profileClinical: nil), 400)
        XCTAssertEqual(VanStockStore.historyWindow(for: van, profileClinical: true), 1_461)
        XCTAssertEqual(VanStockStore.historyWindow(for: clinic, profileClinical: false), 400)
    }

    func testAClinicalListKeepsAThousandDayOldMovementAndAVanFoldsIt() {
        let clinic = reopened(clinicalList: true, profile: nil, ages: [1_000, 10])
        XCTAssertNotNil(clinic.log.movements.first { $0.id == "m0" }, "inside a clinic's four years")
        XCTAssertEqual(clinic.log.level(of: "flu").onHand, StockQuantity(whole: 2))

        try? FileManager.default.removeItem(at: directory)
        let van = reopened(clinicalList: nil, profile: nil, ages: [1_000, 10])
        XCTAssertNil(van.log.movements.first { $0.id == "m0" }, "past a van's 400 days")
        XCTAssertNotNil(van.log.movements.first { $0.kind == .opening }, "folded into the opening figure")
        XCTAssertEqual(van.log.level(of: "flu").onHand, StockQuantity(whole: 2), "the level is exact either way")
    }

    func testTheProfileMakesAListClinicalForItsWindow() {
        let store = reopened(clinicalList: nil, profile: true, ages: [1_000])
        XCTAssertNotNil(store.log.movements.first { $0.id == "m0" })
    }

    func testNoMovementInsideTheWindowIsDeleted() {
        let store = reopened(clinicalList: true, profile: nil, ages: [1_500, 1_460, 700, 1])
        let kept = Set(store.log.movements.map(\.id))
        XCTAssertFalse(kept.contains("m0"), "past four years, folded")
        XCTAssertTrue(kept.isSuperset(of: ["m1", "m2", "m3"]), "everything within four years is still there")
        XCTAssertEqual(store.log.level(of: "flu").onHand, StockQuantity(whole: 4))
    }

    func testTheSupportReportPrintsTheClinicalWindow() {
        let clinic = ClinicalStockReportLines.lines(clinical: true, clinicalSetByOrganisation: true, pinnedMode: true,
                                                    pinnedLocalOnly: false, retentionCeilingDays: 90)
        XCTAssertTrue(clinic[0].contains("clinical (set by the organisation)"))
        XCTAssertTrue(clinic[0].contains("history kept 1461 days"))
        XCTAssertTrue(clinic[0].contains("inventory-only"))
        XCTAssertEqual(clinic[1], "Medical Compliance pinned by the organisation: hipaaMode on, hipaaRetentionDays at most 90")
        let van = ClinicalStockReportLines.lines(clinical: false, clinicalSetByOrganisation: false, pinnedMode: false,
                                                 pinnedLocalOnly: false, retentionCeilingDays: nil)
        XCTAssertEqual(van, ["Stock list: not clinical, history kept 400 days",
                             "Medical Compliance pinned by the organisation: none"])
    }
}
