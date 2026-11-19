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
        _ = service.load([.init(part: "22B22", description: "Igniter", quantity: 4)])
        clock.addTimeInterval(60)
        return store.log.items[0].id
    }

    // MARK: The count

    func testATypedCountIsACountedMovementFromTheScreen() {
        let id = loadIgniter()
        XCTAssertTrue(service.setCount(itemID: id, to: 3))
        let level = store.log.level(of: id)
        XCTAssertEqual(level.onHand, 3)
        XCTAssertEqual(level.provenance, .counted)
        XCTAssertEqual(store.log.movements.last?.source, .typed)
        XCTAssertFalse(service.setCount(itemID: "nobody", to: 3))
        XCTAssertFalse(service.setCount(itemID: id, to: -1))
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
        XCTAssertTrue(service.edit(itemID: id, [.description("Hot surface igniter"), .minimum(2), .bin("left shelf 2")]))
        let edited = store.log.item(id: id)
        XCTAssertEqual(edited?.description, "Hot surface igniter")
        XCTAssertEqual(edited?.minimum, 2)
        XCTAssertEqual(edited?.bin, "left shelf 2")
        XCTAssertEqual(store.log.level(of: id).onHand, 4, "details never move stock")

        clock.addTimeInterval(60)
        _ = service.undo(source: .typed)
        let restored = store.log.item(id: id)
        XCTAssertEqual(restored?.description, "Igniter")
        XCTAssertNil(restored?.minimum)
        XCTAssertNil(restored?.bin)
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
