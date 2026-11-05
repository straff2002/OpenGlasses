import XCTest
@testable import OpenGlasses

/// Settings › Field Assist's trade rows: one per trade, the technician's own first and open, the
/// rest collapsed, and a trade's own settings shown exactly when the gate offers them. Pure.
@MainActor
final class FieldTradeAccordionTests: XCTestCase {

    private func trades(_ rows: [FieldTradeAccordion.Row]) -> [FieldTrade] { rows.map(\.trade) }

    // MARK: - One row per trade

    func testEveryTradeHasExactlyOneRow() {
        let cases: [([FieldTrade], [FieldTrade])] = [
            ([], []), ([.electrical], []), ([], [.refrigerationHVAC]),
            ([.refrigerationHVAC, .electrical], [.electrical]),
        ]
        for (active, owned) in cases {
            let rows = FieldTradeAccordion.rows(activeTrades: active, ownedTrades: owned)
            XCTAssertEqual(Set(trades(rows)), Set(FieldTrade.allCases))
            XCTAssertEqual(rows.count, FieldTrade.allCases.count)
        }
    }

    // MARK: - Order and what opens

    func testWithNothingTheirsTheRowsKeepTradeOrderAndAllStartCollapsed() {
        let rows = FieldTradeAccordion.rows(activeTrades: [], ownedTrades: [])
        XCTAssertEqual(trades(rows), FieldTrade.allCases)
        XCTAssertTrue(FieldTradeAccordion.initiallyExpanded(rows).isEmpty)
    }

    func testAnActiveTradeComesFirstAndOpens() {
        let rows = FieldTradeAccordion.rows(activeTrades: [.electrical], ownedTrades: [])
        XCTAssertEqual(trades(rows), [.electrical, .refrigerationHVAC])
        XCTAssertEqual(FieldTradeAccordion.initiallyExpanded(rows), [.electrical])
        XCTAssertTrue(rows[0].isOn)
        XCTAssertFalse(rows[1].isOn)
    }

    func testATradeWithAnUnlockedVaultComesFirstAndOpensEvenWhileOff() {
        let rows = FieldTradeAccordion.rows(activeTrades: [], ownedTrades: [.electrical])
        XCTAssertEqual(trades(rows), [.electrical, .refrigerationHVAC])
        XCTAssertEqual(FieldTradeAccordion.initiallyExpanded(rows), [.electrical])
        XCTAssertTrue(rows[0].hasVault)
        XCTAssertFalse(rows[0].isOn)
    }

    func testSeveralOfTheirsKeepTradeOrderAmongThemselves() {
        let rows = FieldTradeAccordion.rows(activeTrades: [.electrical], ownedTrades: [.refrigerationHVAC])
        XCTAssertEqual(trades(rows), FieldTrade.allCases)
        XCTAssertEqual(FieldTradeAccordion.initiallyExpanded(rows), Set(FieldTrade.allCases))
    }

    // MARK: - A trade's own settings follow the gate

    func testSettingsAreShownExactlyWhenTheGateOffersTheTrade() {
        let selections: [[FieldTrade]] = [[], [.refrigerationHVAC], [.electrical], [.refrigerationHVAC, .electrical]]
        for active in selections {
            for row in FieldTradeAccordion.rows(activeTrades: active, ownedTrades: []) {
                XCTAssertEqual(row.showsSettings, FieldTradeGate.isAvailable(row.trade, activeTrades: active),
                               "\(row.trade) under \(active)")
            }
        }
        // The case the separate section was hidden in: another trade on, this one off.
        let electricalOnly = FieldTradeAccordion.rows(activeTrades: [.electrical], ownedTrades: [.refrigerationHVAC])
        let refrigeration = electricalOnly.first { $0.trade == .refrigerationHVAC }
        XCTAssertEqual(refrigeration?.showsSettings, false)
        XCTAssertEqual(refrigeration?.isTheirs, true, "a vault they own still opens the row")
    }

    // MARK: - Which trades the vaults bring

    func testDeclaredTradesCountUnknownOnesAreIgnoredAndEachTradeOnce() {
        let owned = FieldTradeAccordion.ownedTrades(unlockedVaults: [
            (id: "electrical_starter", trades: ["electrical"]),
            (id: "imported", trades: ["Electrical ", "plumbing"]),
        ])
        XCTAssertEqual(owned, [.electrical])
    }

    func testTheBundledRefrigerationVaultImpliesItsTradeWithoutDeclaringOne() {
        XCTAssertEqual(FieldTradeAccordion.ownedTrades(unlockedVaults: [(id: "refrigeration", trades: nil)]),
                       [.refrigerationHVAC])
        XCTAssertEqual(FieldTradeAccordion.ownedTrades(unlockedVaults: [(id: "refrigeration", trades: [])]),
                       [.refrigerationHVAC])
        // A declared list wins over the implied trade.
        XCTAssertEqual(FieldTradeAccordion.ownedTrades(unlockedVaults: [(id: "refrigeration", trades: ["electrical"])]),
                       [.electrical])
    }

    func testVaultsWithNoTradeBringNone() {
        let owned = FieldTradeAccordion.ownedTrades(unlockedVaults: [
            (id: "it_network", trades: nil), (id: "notes", trades: nil), (id: "health", trades: []),
        ])
        XCTAssertTrue(owned.isEmpty)
        XCTAssertTrue(FieldTradeAccordion.ownedTrades(unlockedVaults: []).isEmpty)
    }

    func testTheImpliedTradeIsLayoutOnlyAndNeverJoinsTheSelection() {
        // The bundled refrigeration vault still declares no trades, so it is never the vault layer
        // of the selection in force: owning it must not switch Electrical's tools off.
        XCTAssertNil(VaultRegistry.builtInManifest(id: "refrigeration")?.trades)
        XCTAssertEqual(FieldTradeResolver.resolve(explicit: nil, organization: nil,
                                                  vault: VaultRegistry.builtInManifest(id: "refrigeration")?.trades),
                       .none)
    }
}
