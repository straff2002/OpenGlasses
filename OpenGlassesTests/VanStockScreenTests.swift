import XCTest
@testable import OpenGlasses

/// Plan IH P2 — what the Van Stock screen does to the log, and the organisation's switch.
@MainActor
final class VanStockScreenTests: XCTestCase {

    private var directory: URL!
    private var store: VanStockStore!
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)
    private var verified: Set<String> = []
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("van-stock-screen-tests-\(UUID().uuidString)", isDirectory: true)
        store = VanStockStore(directory: directory, now: clock)
        verified = []
        PolicyEnvelope.clear()
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        PolicyEnvelope.clear()
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private lazy var service = VanStockService(
        store: store,
        verify: { [unowned self] number in
            let cleaned = VaultPartsIndex.normalise(number)
            return TaskPart(number: cleaned, verified: self.verified.contains(cleaned))
        },
        partsIndex: { VaultPartsIndex(files: []) },
        activeJob: { nil },
        now: { [unowned self] in self.clock })

    private func loadIgniter() -> String {
        _ = service.load([.init(part: "22B22", description: "Igniter", quantity: .whole(4))])
        clock.addTimeInterval(60)
        return store.log.items[0].id
    }

    // MARK: The count

    func testATypedCountIsACountedMovementFromTheScreen() {
        let id = loadIgniter()
        XCTAssertTrue(service.setCount(itemID: id, to: .whole(3)))
        let level = store.log.level(of: id)
        XCTAssertEqual(level.onHand, .whole(3))
        XCTAssertEqual(level.provenance, .counted)
        XCTAssertEqual(store.log.movements.last?.source, .typed)
        XCTAssertFalse(service.setCount(itemID: "nobody", to: .whole(3)))
        XCTAssertFalse(service.setCount(itemID: id, to: .whole(-1)))
    }

    func testUndoFromTheScreenTakesBackWhatWasSaid() {
        let id = loadIgniter()
        XCTAssertTrue(service.canUndo)
        _ = service.undo(source: .typed)
        XCTAssertNil(store.log.item(id: id), "the load created the line, so undoing it removes the line")
        XCTAssertFalse(service.canUndo)
    }

    func testAnEmptyVanHasNothingToUndo() {
        XCTAssertFalse(service.canUndo)
    }

    // MARK: Details

    func testEditsAreOneBatchAndOneUndo() {
        let id = loadIgniter()
        XCTAssertTrue(service.edit(itemID: id, [.description("Hot surface igniter"), .minimum(.whole(2)), .bin("left shelf 2")]))
        let edited = store.log.item(id: id)
        XCTAssertEqual(edited?.description, "Hot surface igniter")
        XCTAssertEqual(edited?.minimum, .whole(2))
        XCTAssertEqual(edited?.bin, "left shelf 2")
        XCTAssertEqual(store.log.level(of: id).onHand, .whole(4), "details never move stock")

        clock.addTimeInterval(60)
        _ = service.undo(source: .typed)
        let restored = store.log.item(id: id)
        XCTAssertEqual(restored?.description, "Igniter")
        XCTAssertNil(restored?.minimum)
        XCTAssertNil(restored?.bin)
    }

    // MARK: Plan ML P1 — a unit counted whole is refused while a figure is part of one

    func testAUnitCountedWholeIsRefusedWhileAFigureIsNot() {
        store.update { log in
            log.addItem(id: "oil", description: "Engine oil", unit: .l, batch: "b0")
            log.record(.counted, itemID: "oil", quantity: StockQuantity(scaled: 4250), at: self.clock,
                       batch: "b0", source: .typed)
        }
        clock.addTimeInterval(60)

        XCTAssertEqual(service.unitChangeRefusal(itemID: "oil", to: .pack),
                       "4.25 l on hand is not a whole number of packs; count it first.")
        XCTAssertEqual(service.unitChangeRefusal(itemID: "oil", to: .each),
                       "4.25 l on hand is not a whole number; count it first.")
        XCTAssertNil(service.unitChangeRefusal(itemID: "oil", to: .kg), "a measured unit keeps the figure as it is")

        // The refused change is left out; the rest of the batch still applies.
        XCTAssertTrue(service.edit(itemID: "oil", [.unit(.pack), .bin("drum shelf")]))
        XCTAssertEqual(store.log.item(id: "oil")?.unit, .l)
        XCTAssertEqual(store.log.item(id: "oil")?.bin, "drum shelf")
        XCTAssertFalse(service.edit(itemID: "oil", [.unit(.each)]), "nothing changed, nothing noted")
        XCTAssertEqual(store.log.level(of: "oil").onHand, StockQuantity(scaled: 4250), "a refusal never moves stock")

        // Counted whole, it can be counted in packs; the stored figure does not change with the unit.
        XCTAssertTrue(service.setCount(itemID: "oil", to: .whole(4)))
        XCTAssertNil(service.unitChangeRefusal(itemID: "oil", to: .pack))
        XCTAssertTrue(service.edit(itemID: "oil", [.unit(.pack)]))
        XCTAssertEqual(store.log.item(id: "oil")?.unit, .pack)
        XCTAssertEqual(store.log.level(of: "oil").onHand, .whole(4))
    }

    func testAMinimumOrStandardThatIsPartOfOneAlsoHoldsTheUnit() {
        store.update { log in
            log.addItem(id: "cable", description: "Thermostat cable", unit: .m,
                        minimum: StockQuantity(scaled: 2500), batch: "b0")
            log.record(.counted, itemID: "cable", quantity: .whole(30), at: self.clock, batch: "b0", source: .typed)
        }
        XCTAssertEqual(service.unitChangeRefusal(itemID: "cable", to: .each),
                       "The minimum of 2.5 m is not a whole number; change it first.")
        XCTAssertFalse(service.edit(itemID: "cable", [.unit(.each)]))

        XCTAssertTrue(service.edit(itemID: "cable", [.minimum(.whole(2)), .standard(StockQuantity(scaled: 40_500), setBy: .van)]))
        XCTAssertEqual(service.unitChangeRefusal(itemID: "cable", to: .pack),
                       "The standard of 40.5 m is not a whole number of packs; change it first.")
        XCTAssertEqual(store.log.item(id: "cable")?.unit, .m)
    }

    // MARK: Plan ML P2 — a measured figure typed on the line's page

    private let german = Locale(identifier: "de_DE")
    private let english = Locale(identifier: "en_NZ")

    func testATypedMeasuredFigureIsReadInThePhonesLocaleExactly() {
        XCTAssertEqual(try VanStockEntry.read("4,25", unit: .l, locale: german).get(), StockQuantity(scaled: 4250))
        XCTAssertEqual(try VanStockEntry.read("4.25", unit: .l, locale: german).get(), StockQuantity(scaled: 4250))
        XCTAssertEqual(try VanStockEntry.read("4.25", unit: .l, locale: english).get(), StockQuantity(scaled: 4250))
        XCTAssertEqual(VanStockEntry.read("4,2513", unit: .l, locale: german), .failure(.tooManyDecimals))
        XCTAssertEqual(VanStockEntry.read("2,5", unit: .pack, locale: german), .failure(.notWhole))
        XCTAssertEqual(VanStockEntry.read("1,000", unit: .m, locale: english), .failure(.notANumber), "grouping is refused, not guessed")
        XCTAssertEqual(VanStockEntry.read("", unit: .l, locale: english), .failure(.notANumber))
        XCTAssertEqual(try VanStockEntry.minimum(" ", unit: .l, locale: english).get(), nil, "an empty minimum is none")
        XCTAssertEqual(try VanStockEntry.minimum("0,5", unit: .kg, locale: german).get(), StockQuantity(scaled: 500))
        XCTAssertEqual(VanStockEntry.minimum("2.5", unit: .each, locale: english), .failure(.notWhole))
    }

    func testAFieldShowsTheFigureSoItReadsBackTheSame() {
        XCTAssertEqual(VanStockEntry.text(StockQuantity(scaled: 4250), locale: german), "4,25")
        XCTAssertEqual(VanStockEntry.text(StockQuantity(scaled: 1_000_500), locale: english), "1000.5", "no grouping")
        XCTAssertEqual(VanStockEntry.text(.whole(4), locale: german), "4")
        for scaled in [1, 4250, 1_000_500, 999_999_999] {
            let quantity = StockQuantity(scaled: scaled)
            XCTAssertEqual(try VanStockEntry.read(VanStockEntry.text(quantity, locale: german), unit: .l, locale: german).get(), quantity)
        }
    }

    func testTheStepperMovesOneWholeUnitAndStopsAtZero() {
        XCTAssertEqual(VanStockEntry.stepped("4,25", by: 1, unit: .l, locale: german, fallback: .zero), "5,25")
        XCTAssertEqual(VanStockEntry.stepped("4,25", by: -1, unit: .l, locale: german, fallback: .zero), "3,25")
        XCTAssertEqual(VanStockEntry.stepped("0.5", by: -1, unit: .l, locale: english, fallback: .zero), "0")
        XCTAssertEqual(VanStockEntry.stepped("oops", by: 1, unit: .l, locale: english, fallback: StockQuantity(scaled: 2500)), "3.5",
                       "a field that holds no figure steps from the line's own")
        XCTAssertEqual(VanStockEntry.wholeCount(.whole(7)), 7)
        XCTAssertNil(VanStockEntry.wholeCount(StockQuantity(scaled: 4250)), "never cut for a stepper")
    }

    func testTheListShowsTheLocalesFormAndTheUnitsSymbol() {
        store.update { log in
            log.addItem(id: "oil", description: "Engine oil", unit: .l, batch: "b0")
            log.record(.counted, itemID: "oil", quantity: StockQuantity(scaled: 4250), at: self.clock, batch: "b0", source: .typed)
        }
        let row = VanStockRows.rows(store.log).first
        XCTAssertEqual(row?.quantity(locale: german), "4,25 l")
        XCTAssertEqual(row?.quantity(locale: english), "4.25 l")
        XCTAssertEqual(VanStockRow.figure(.whole(3), unit: .each, locale: german), "3")
        XCTAssertEqual(VanStockRow.figure(.whole(3), unit: .pack, locale: german), "3 pack")
    }

    func testATypedDecimalCountIsRecordedExactly() {
        store.update { log in log.addItem(id: "oil", description: "Engine oil", unit: .l, batch: "b0") }
        let typed = try? VanStockEntry.read("4,25", unit: .l, locale: german).get()
        XCTAssertTrue(service.setCount(itemID: "oil", to: typed ?? .zero))
        XCTAssertEqual(store.log.level(of: "oil").onHand, StockQuantity(scaled: 4250))
        XCTAssertEqual(store.log.level(of: "oil").provenance, .counted)
    }

    func testANewNumberIsLookedUpAgain() {
        verified = ["22B22"]
        let id = loadIgniter()
        XCTAssertEqual(store.log.item(id: id)?.verified, true)

        XCTAssertTrue(service.edit(itemID: id, [.number("22B23")]))
        XCTAssertEqual(store.log.item(id: id)?.number, "22B23")
        XCTAssertEqual(store.log.item(id: id)?.verified, false, "the old number's verification does not carry over")

        clock.addTimeInterval(60)
        XCTAssertTrue(service.edit(itemID: id, [.number("22B22")]))
        XCTAssertEqual(store.log.item(id: id)?.verified, true)
    }

    func testNoChangeIsNoEntry() {
        let id = loadIgniter()
        let before = store.log
        XCTAssertFalse(service.edit(itemID: id, [.description("Igniter")]))
        XCTAssertFalse(service.edit(itemID: id, []))
        XCTAssertEqual(store.log, before)
    }

    // MARK: The organisation's switch

    private func apply(_ settings: [String: RawSetting]) -> ProfileApplier.Result {
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Northbridge Mechanical",
                                    issued: Date(), leaseDays: 30, settings: settings)
        return ProfileApplier.apply(profile: profile, resolvableVaultIds: [])
    }

    func testTheSwitchIsACeilingThatCanOnlyTurnVanStockOff() {
        let key = SettingKey.organizationForbidsVanStock
        XCTAssertEqual(key.kind, .ceiling(pinnedTo: true))
        XCTAssertEqual(apply([key.rawValue: RawSetting(.bool(true), .ceiling)]).ceilings[key], .bool(true))
        let widened = apply([key.rawValue: RawSetting(.bool(false), .ceiling)])
        XCTAssertNil(widened.ceilings[key])
        XCTAssertEqual(widened.drops, [.init(key: key.rawValue, reason: .wrongDirection)])
        XCTAssertFalse(key.ceilingDescription.isEmpty)
    }

    func testWithTheSwitchOnTheToolRefusesAndChangesNothing() async throws {
        let tool = VanStockTool(service: service)
        XCTAssertFalse(Config.organizationForbidsVanStock)
        let allowed = try await tool.execute(args: ["action": "load", "description": "Fuse", "quantity": 2])
        XCTAssertTrue(allowed.hasPrefix("Loaded 2 × Fuse."), allowed)

        PolicyEnvelope.install(apply(["organizationForbidsVanStock": RawSetting(.bool(true), .ceiling)]),
                               organizationName: "Northbridge Mechanical")
        XCTAssertTrue(Config.organizationForbidsVanStock)
        let before = store.log
        clock.addTimeInterval(60)
        let refused = try await tool.execute(args: ["action": "load", "description": "Fuse", "quantity": 2])
        XCTAssertTrue(refused.contains("switched van stock off"), refused)
        let check = try await tool.execute(args: ["action": "check", "description": "fuse"])
        XCTAssertTrue(check.contains("switched van stock off"), check)
        XCTAssertEqual(store.log, before)

        PolicyEnvelope.clear()
        XCTAssertFalse(Config.organizationForbidsVanStock, "removing the profile lifts it")
    }

    // MARK: Name and place (Plan MK P2)

    func testTheProfilesPlaceLocksTheResolvedPlaceAndIsNeverWrittenIntoTheList() {
        store.setPlace(.truck)
        XCTAssertEqual(store.resolvedPlace, .init(kind: .truck, isLocked: false))
        XCTAssertEqual(store.screenTitle, "Truck stock")

        let key = SettingKey.organizationStockPlace
        PolicyEnvelope.install(apply([key.rawValue: RawSetting(.string("store"), .default)]),
                               organizationName: "Northbridge Mechanical")
        XCTAssertEqual(Config.organizationStockPlace, "store")
        XCTAssertEqual(store.resolvedPlace, .init(kind: .store, isLocked: true))
        XCTAssertEqual(store.screenTitle, "Store stock")
        XCTAssertEqual(store.van?.place, .truck, "the profile's place is resolved over the list's, not written in")

        PolicyEnvelope.clear()
        XCTAssertNil(Config.organizationStockPlace)
        XCTAssertEqual(store.resolvedPlace, .init(kind: .truck, isLocked: false), "removing the profile gives it back")
    }

    func testAnUnknownProfilePlaceIsNoSetting() {
        // A value the content check would drop never reaches the envelope; read strictly anyway.
        XCTAssertEqual(StockPlaceSetting.resolve(profile: "boat", list: .store), .init(kind: .store, isLocked: false))
        XCTAssertEqual(store.resolvedPlace, .init(kind: .van, isLocked: false), "a list nobody placed is a van")
        XCTAssertEqual(store.screenTitle, "Van stock")
    }

    func testTheListsNameIsTheTitleWhateverThePlace() {
        store.nameVan("Main street")
        store.setPlace(.store)
        XCTAssertEqual(store.screenTitle, "Main street")
        store.setPlace(.stock)
        XCTAssertEqual(store.screenTitle, "Main street")
    }

    func testNamingAndPlacingAndNamingABookKeepEachOther() {
        store.nameVan("Workshop")
        store.setPlace(.stock)
        store.checkNumbers(against: "supplier")
        XCTAssertEqual(store.van?.name, "Workshop")
        XCTAssertEqual(store.van?.place, .stock)
        XCTAssertEqual(store.van?.checkVaultID, "supplier")

        let reopened = VanStockStore(directory: directory, now: clock)
        XCTAssertEqual(reopened.van?.place, .stock)
        XCTAssertEqual(reopened.van?.checkVaultID, "supplier")
        XCTAssertEqual(reopened.screenTitle, "Workshop")
    }
}
