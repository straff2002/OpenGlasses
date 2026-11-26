import XCTest
@testable import OpenGlasses

/// Plan MM P3 — a phone whose place's count is held by the business's own system: the phone's
/// list, the system's connection and snapshot, and van stock speaking for whichever holds it.
@MainActor
final class StockSystemVanStockHarness {

    typealias C = StockSystemConnectionSamples

    nonisolated static let calendar: Calendar = StockSystemSamples.calendar
    /// Friday 20 November 2026, 09:10 UTC.
    nonisolated static let asOf = StockSystemSamples.pulledAt
    nonisolated static let unitMap = StockSystemUnitMap(["ea": .each, "litre": .l, "kg": .kg])

    /// The system's figures at the main location, and a few at the van location.
    nonisolated static func snapshot(asOf: Date = asOf) -> StockSystemSnapshot {
        let builder = StockSystemSnapshotBuilder(source: StockSystemSource(connectorID: "square", displayName: "Square"),
                                                 unitMap: unitMap)
        let rows = [
            StockSystemRawRow(itemID: "ITEM-CAP", part: "ZX-455", description: "Run capacitor 45/5", unit: "ea",
                              levels: [.init(location: C.main.id, quantity: "3")], reorderPoint: "2", decimalPlaces: 0),
            StockSystemRawRow(itemID: "ITEM-COOL", part: "CL-50", description: "Coolant", unit: "litre",
                              levels: [.init(location: C.main.id, quantity: "12.5")], decimalPlaces: 2),
            StockSystemRawRow(itemID: "ITEM-WELD", part: "WW-09", description: "Welding wire", unit: "kg",
                              levels: [.init(location: C.main.id, quantity: "1.23456")]),
            StockSystemRawRow(itemID: "ITEM-FUSE", part: "FU-10", description: "Fuse 10A", unit: "ea",
                              levels: [.init(location: C.main.id, quantity: "0"), .init(location: C.van.id, quantity: "2")]),
            StockSystemRawRow(itemID: "ITEM-GREASE", part: "GR-1", description: "Grease", unit: "tin",
                              levels: [.init(location: C.main.id, quantity: "4")]),
        ]
        return builder.build(locations: [StockSystemRawLocation(id: C.main.id, name: C.main.name, locationClass: "base"),
                                         StockSystemRawLocation(id: C.van.id, name: C.van.name, locationClass: "van")],
                             rows: rows, pulledAt: asOf).snapshot
    }

    let directory: URL
    let memory = MemoryStockSystemStorage()
    let vanStore: VanStockStore
    var clock = asOf
    var job: VanStockService.Job?
    var kind: StockPlace.Kind = .van
    var online = false
    var medicalBlocked = false
    var counter = 0
    var recordedUses: [VanStockUse] = []
    var connector = ScriptedStockSystemConnector(snapshot: .success(snapshot()), probe: .success(C.probe()))
    var makeConnector: StockSystemService.ConnectorFactory?
    var checkBudget: TimeInterval = StockSystemPolicy.checkNowBudget
    private(set) var system: StockSystemService?

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("van-stock-authority-\(UUID().uuidString)", isDirectory: true)
        vanStore = VanStockStore(directory: directory.appendingPathComponent("van", isDirectory: true), now: Self.asOf)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Connect the system with `locations` chosen and `snapshot` as its last good figures.
    @discardableResult
    func connect(locations: [StockSystemLocation] = [C.main], snapshot: StockSystemSnapshot? = snapshot()) throws
        -> StockSystemService {
        let connection = StockSystemConnectionStore(storage: memory.storage, connectorIDs: ["square"], licensed: { true })
        if connection.record == nil {
            try connection.pasteKey(C.key(), environment: .production, administrator: false, hasSandbox: true)
        }
        if !locations.isEmpty { try connection.chooseLocations(locations) }
        let snapshots = StockSystemSnapshotStore(directory: directory, connectorIDs: ["square"])
        if let snapshot { XCTAssertTrue(snapshots.replace(snapshot)) }
        let service = StockSystemService(
            connection: connection, store: snapshots,
            registry: { StockSystemAdapterRegistry.registration(for: $0) },
            now: { [unowned self] in self.clock },
            medicalBlocks: { [unowned self] _ in self.medicalBlocked },
            placeName: { nil },
            isOnline: { [unowned self] in self.online },
            checkBudget: checkBudget,
            makeConnector: makeConnector ?? { [unowned self] _, _, _ in self.connector })
        system = service
        return service
    }

    func disconnect() {
        system?.remove()
    }

    lazy var vanStock = VanStockService(
        store: vanStore,
        place: { [unowned self] in self.kind },
        partsIndex: { VaultPartsIndex(files: []) },
        activeJob: { [unowned self] in self.job },
        now: { [unowned self] in self.clock },
        calendar: Self.calendar,
        makeID: { [unowned self] in
            self.counter += 1
            return "id-\(self.counter)"
        },
        jobUses: .init(record: { [unowned self] in self.recordedUses.append($0) }, remove: { _ in },
                       notFromVan: { _ in false }, unrecorded: { [] }),
        stockSystem: .init(service: { [unowned self] in self.system }, book: { _ in nil }))

    lazy var tool = VanStockTool(service: vanStock)

    var staged: [StagedStockUseEntry] { system?.staged.entries ?? [] }

    func run(_ args: [String: Any]) async throws -> String {
        try await tool.execute(args: args)
    }
}

/// The `van_stock` tool, per authority (Plan MM §5).
@MainActor
final class VanStockToolAuthorityTests: XCTestCase {

    private var h: StockSystemVanStockHarness!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() async throws {
        PolicyEnvelope.clear()
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        h = StockSystemVanStockHarness()
    }

    override func tearDown() async throws {
        h.cleanUp()
        PolicyEnvelope.clear()
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
    }

    // MARK: - Refused

    func testLoadCountStandardsAndTopUpsAreRefusedWithTheSentence() async throws {
        try h.connect()
        let load = try await h.run(["action": "load", "part": "ZX-455", "quantity": 4])
        XCTAssertTrue(load.hasPrefix("Stock is kept in Square, so each load and count is done there"), load)
        let topUpLoad = try await h.run(["action": "load", "to_standard": true])
        XCTAssertTrue(topUpLoad.hasPrefix("Stock is kept in Square"), topUpLoad)
        let count = try await h.run(["action": "count", "part": "ZX-455", "quantity": 9])
        XCTAssertTrue(count.hasPrefix("Stock is kept in Square, so counting is done there"), count)
        let standard = try await h.run(["action": "set_standard", "part": "ZX-455", "quantity": 5])
        XCTAssertTrue(standard.contains("standard load and reordering are set there"), standard)
        let topUp = try await h.run(["action": "top_up"])
        XCTAssertTrue(topUp.hasPrefix("Stock is kept in Square"), topUp)
        for answer in [load, topUpLoad, count, standard, topUp] {
            XCTAssertTrue(answer.contains("Nothing was changed"), answer)
            XCTAssertFalse(answer.contains("Say:"), "nothing changed, nothing to say")
        }
        XCTAssertTrue(h.vanStore.log.isEmpty, "a count is never written, on the phone or anywhere")
        XCTAssertTrue(h.staged.isEmpty)
        XCTAssertEqual(h.system?.snapshot, StockSystemVanStockHarness.snapshot(), "the system's figures are untouched")
    }

    func testAtPremisesTheRefusalSaysReceipt() async throws {
        h.kind = .store
        try h.connect()
        let load = try await h.run(["action": "load", "part": "ZX-455", "quantity": 4])
        XCTAssertTrue(load.hasPrefix("Stock is kept in Square, so each receipt and count is done there"), load)
    }

    func testSendToBaseIsNotOffered() async throws {
        try h.connect()
        let answer = try await h.run(["action": "send_to_base"])
        XCTAssertEqual(answer, "Stock is kept in Square, so there is no need to send the stock to base: Square already has it.")
        h.kind = .store
        let shop = try await h.run(["action": "send_to_base", "answered": true])
        XCTAssertEqual(shop, "Stock is kept in Square, so there is no need to send the stock list: Square already has it.")
    }

    func testNoSaleAtATill() async throws {
        h.kind = .store
        try h.connect()
        for action in ["sell", "sale", "sold"] {
            let answer = try await h.run(["action": action, "part": "ZX-455"])
            XCTAssertEqual(answer, "Sales come off Square's count at the till; the phone never records a sale. Nothing was changed.")
        }
        XCTAssertTrue(h.staged.isEmpty)
        let description = h.tool.description
        XCTAssertFalse(description.lowercased().contains("sold"), description)
        XCTAssertTrue(description.contains("A sale is never recorded here"), description)
    }

    // MARK: - Use

    func testAUseIsStagedOnTheOpenJobAndSaysSo() async throws {
        h.job = .init(sessionID: "S1", reference: "1027")
        try h.connect()
        let answer = try await h.run(["action": "use", "part": "ZX-455", "description": "45/5 capacitor"])
        XCTAssertTrue(answer.hasPrefix("I've noted 1 × Run capacitor 45/5 (ZX-455) used on job 1027. It goes to Square "
            + "when the technician confirms the job's parts, and Square's count does not change until then."), answer)
        XCTAssertTrue(answer.contains("\nSay: 1 × Run capacitor 45/5 (ZX-455) noted for Square on job 1027."), answer)

        let entry = try XCTUnwrap(h.staged.first)
        XCTAssertEqual(h.staged.count, 1)
        XCTAssertEqual(entry.scope, .job("S1"))
        XCTAssertEqual(entry.jobReference, "1027")
        XCTAssertEqual(entry.connectorID, "square")
        XCTAssertEqual(entry.locationID, StockSystemConnectionSamples.main.id)
        XCTAssertNil(entry.reason)
        XCTAssertEqual(entry.use.itemID, "ITEM-CAP")
        XCTAssertEqual(entry.use.part, "ZX-455")
        XCTAssertEqual(entry.use.quantity, .whole(1))
        XCTAssertEqual(entry.use.unit, .each)
        XCTAssertEqual(entry.use.source, .spoken)
        XCTAssertEqual(entry.use.verification, .notChecked, "no book, so nothing was checked")

        XCTAssertTrue(h.vanStore.log.isEmpty, "a system-held place writes no movement of its own")
        XCTAssertTrue(h.recordedUses.isEmpty, "and puts no phone use on the job's record")
        XCTAssertEqual(h.system?.snapshot, StockSystemVanStockHarness.snapshot(), "the system's count does not change")

        // The next check says what is noted and not yet sent.
        let check = try await h.run(["action": "check", "part": "ZX-455"])
        XCTAssertTrue(check.contains("3 × Run capacitor 45/5 (ZX-455) on the van in Square, as of 09:10"), check)
        XCTAssertTrue(check.contains("1 used on this job is noted and not yet sent to Square"), check)
    }

    func testAModelRetryIsNotNotedTwice() async throws {
        h.job = .init(sessionID: "S1", reference: nil)
        try h.connect()
        _ = try await h.run(["action": "use", "part": "ZX-455"])
        let again = try await h.run(["action": "use", "part": "ZX-455"])
        XCTAssertTrue(again.hasPrefix("Already noted a moment ago"), again)
        XCTAssertEqual(h.staged.count, 1)
    }

    func testAScannedUseInAMeasuredUnitIsStagedInThatUnit() async throws {
        h.job = .init(sessionID: "S1", reference: nil)
        try h.connect()
        let answer = try await h.run(["action": "use", "part": "CL-50", "quantity": 0.5, "code": "CL-50"])
        XCTAssertTrue(answer.hasPrefix("I've noted 0.5 litres of Coolant (CL-50) used on this job."), answer)
        XCTAssertEqual(h.staged.first?.use.quantity, StockQuantity(scaled: 500))
        XCTAssertEqual(h.staged.first?.use.unit, .l)
        XCTAssertEqual(h.staged.first?.use.source, .scanned)
    }

    func testAQuantityTheItemCannotTakeIsRefusedBeforeStaging() async throws {
        h.job = .init(sessionID: "S1", reference: nil)
        try h.connect()
        let finer = try await h.run(["action": "use", "part": "CL-50", "quantity": 0.125])
        XCTAssertTrue(finer.contains("Square keeps that item to 2 decimal places, so 0.125 litres can't be sent."), finer)
        let other = try await h.run(["action": "use", "part": "CL-50", "quantity": 1, "unit": "each"])
        XCTAssertTrue(other.contains("Square keeps Coolant (CL-50) in litres, not each"), other)
        let unmapped = try await h.run(["action": "use", "part": "GR-1"])
        XCTAssertTrue(unmapped.contains("can't be sent"), unmapped)
        let fraction = try await h.run(["action": "use", "part": "ZX-455", "quantity": 0.5])
        XCTAssertTrue(fraction.contains("Nothing recorded for Run capacitor 45/5 (ZX-455)"), fraction)
        XCTAssertTrue(h.staged.isEmpty, "nothing is staged that the item cannot take")
    }

    func testAPartTheSystemDoesNotCarryIsNotStaged() async throws {
        h.job = .init(sessionID: "S1", reference: nil)
        try h.connect()
        let answer = try await h.run(["action": "use", "part": "XX-999"])
        XCTAssertTrue(answer.hasPrefix("Square doesn't carry that number"), answer)
        XCTAssertTrue(h.staged.isEmpty)
    }

    func testRemoveWithAReasonTheSystemKeepsIsStaged() async throws {
        h.job = .init(sessionID: "S1", reference: nil)
        try h.connect()
        let damaged = try await h.run(["action": "remove", "part": "ZX-455", "reason": "damaged"])
        XCTAssertTrue(damaged.hasPrefix("I've noted 1 × Run capacitor 45/5 (ZX-455) written off as damaged, on this job."),
                      damaged)
        XCTAssertEqual(h.staged.first?.reason, .waste, "the reason this system keeps for it")

        let returned = try await h.run(["action": "remove", "part": "ZX-455", "reason": "returned"])
        XCTAssertTrue(returned.hasPrefix("Stock is kept in Square"), returned)
        XCTAssertTrue(returned.contains("Only stock written off as damaged is noted here"), returned)
        let noReason = try await h.run(["action": "remove", "part": "ZX-455"])
        XCTAssertTrue(noReason.hasPrefix("Stock is kept in Square"), noReason)
        XCTAssertEqual(h.staged.count, 1)
    }

    func testAVehicleWithNoJobRefusesAndPremisesStageOnTheDaysList() async throws {
        try h.connect()
        let van = try await h.run(["action": "use", "part": "ZX-455"])
        XCTAssertEqual(van, "Every part taken off the van goes on a job, and no job is open, so nothing was noted. "
            + "Ask the technician which job it was for.")
        XCTAssertTrue(h.staged.isEmpty)

        h.kind = .store
        let shop = try await h.run(["action": "use", "part": "ZX-455"])
        XCTAssertTrue(shop.hasPrefix("I've noted 1 × Run capacitor 45/5 (ZX-455) used today. It goes to Square "
            + "when the person confirms today's list"), shop)
        XCTAssertEqual(h.staged.first?.scope, .day("2026-11-20"))
        XCTAssertEqual(h.system?.staged.entries(forDay: "2026-11-20").count, 1, "readable per premises day")
    }

    func testUndoTakesBackTheLastNoteBeforeItIsSent() async throws {
        h.job = .init(sessionID: "S1", reference: nil)
        try h.connect()
        let nothing = try await h.run(["action": "undo"])
        XCTAssertTrue(nothing.hasPrefix("Nothing is noted on the phone to take back. Stock is kept in Square"), nothing)

        _ = try await h.run(["action": "use", "items": [["part": "ZX-455"], ["part": "CL-50", "quantity": 2]]])
        XCTAssertEqual(h.staged.count, 2)
        let undone = try await h.run(["action": "undo"])
        XCTAssertTrue(undone.hasPrefix("Taken back: 1 × Run capacitor 45/5 (ZX-455); 2 litres of Coolant (CL-50). "
            + "Nothing goes to Square for them."), undone)
        XCTAssertTrue(h.staged.isEmpty)
        XCTAssertTrue(h.vanStore.log.isEmpty)
    }

    // MARK: - Check, low, list

    func testCheckSaysTheSystemsFigureWithItsTime() async throws {
        try h.connect()
        let check = try await h.run(["action": "check", "part": "ZX-455"])
        XCTAssertEqual(check, "3 × Run capacitor 45/5 (ZX-455) on the van in Square, as of 09:10.")
        let byWords = try await h.run(["action": "check", "description": "run capacitor"])
        XCTAssertEqual(byWords, check, "words find the same line")

        let unknown = try await h.run(["action": "check", "part": "WW-09"])
        XCTAssertTrue(unknown.hasPrefix("Square lists Welding wire (WW-09) but has no count for it."), unknown)
        XCTAssertTrue(unknown.contains("more decimal places than I keep"), unknown)
        XCTAssertFalse(unknown.contains("1.23"), "an unknown is never a number")

        let none = try await h.run(["action": "check", "part": "FU-10"])
        XCTAssertTrue(none.hasPrefix("No Fuse 10A (FU-10) on the van in Square, as of 09:10; 2 at Van 1."), none)

        let notCarried = try await h.run(["action": "check", "part": "XX-999"])
        XCTAssertTrue(notCarried.hasPrefix("Square doesn't carry that number"), notCarried)

        for answer in [check, unknown, none, notCarried] {
            XCTAssertFalse(answer.lowercased().contains("counted"), answer)
        }
    }

    func testAStaleSnapshotSaysItsAgeFirst() async throws {
        try h.connect()
        h.clock = StockSystemVanStockHarness.asOf.addingTimeInterval(25 * 3600)
        let check = try await h.run(["action": "check", "part": "ZX-455"])
        XCTAssertEqual(check, "As of yesterday at 09:10, Square had 3 × Run capacitor 45/5 (ZX-455) on the van.")
    }

    func testNoFiguresYetIsNeverAGuess() async throws {
        try h.connect(snapshot: nil)
        let check = try await h.run(["action": "check", "part": "ZX-455"])
        XCTAssertTrue(check.hasPrefix("Stock on the van is kept in Square, and no figures from Square are on this phone yet"),
                      check)
        let use = try await h.run(["action": "use", "part": "ZX-455"])
        XCTAssertEqual(use, check, "nothing is noted against figures the phone does not have")
    }

    func testLowIsTheSystemsReorderPointOrNone() async throws {
        try h.connect()
        let low = try await h.run(["action": "low"])
        XCTAssertTrue(low.hasPrefix("In Square, as of 09:10, at or below its reorder point or at none:"), low)
        XCTAssertFalse(low.contains("Run capacitor"), "3 is above its reorder point of 2: \(low)")
        XCTAssertTrue(low.contains("none of Fuse 10A (FU-10)"), low)
        XCTAssertTrue(low.contains("Square has no count for 2 lines"), low)
        XCTAssertFalse(low.contains("Coolant"), low)
    }

    func testListIsTheSystemsFigures() async throws {
        try h.connect()
        let list = try await h.run(["action": "list", "bin": "left shelf"])
        XCTAssertTrue(list.hasPrefix("Square's figures carry no bins on the phone"), list)
        XCTAssertTrue(list.contains("Run capacitor 45/5 (ZX-455): 3"), list)
        XCTAssertTrue(list.contains("Coolant (CL-50): 12.5 litres"), list)
        XCTAssertTrue(list.contains("Welding wire (WW-09): no count"), list)
    }

    // MARK: - The description

    func testTheDescriptionFollowsTheAuthority() async throws {
        let phone = h.tool.description
        XCTAssertTrue(phone.contains("'load'"), phone)
        XCTAssertTrue(phone.contains("kept on the phone"), phone)
        XCTAssertNotNil((h.tool.parametersSchema["properties"] as? [String: Any])?["to_standard"])

        try h.connect()
        let system = h.tool.description
        XCTAssertTrue(system.hasPrefix("The stock on the van, as Square holds it"), system)
        for offered in ["'load'", "'count'", "'set_standard'", "'top_up'", "'send_to_base'", "'list'", "'low'"] {
            XCTAssertEqual(system.contains(offered), ["'list'", "'low'"].contains(offered), "\(offered) in \(system)")
        }
        for word in ["kept on the phone", "counted", "loaded", "received", "sold", "stocktake'"] {
            XCTAssertFalse(system.contains(word), "\(word) in \(system)")
        }
        let properties = try XCTUnwrap(h.tool.parametersSchema["properties"] as? [String: Any])
        XCTAssertNil(properties["to_standard"])
        XCTAssertNil(properties["answered"])
        XCTAssertNil(properties["new_line"])
        let action = try XCTUnwrap(properties["action"] as? [String: Any])
        XCTAssertEqual(action["enum"] as? [String], VanStockTool.actions, "the action values stay")
        let quantity = try XCTUnwrap(properties["quantity"] as? [String: Any])
        XCTAssertFalse((quantity["description"] as? String ?? "").contains("'load'"))

        h.kind = .store
        XCTAssertTrue(h.tool.description.contains("on the open job, or on today's list when no job is open"))
        h.disconnect()
        XCTAssertEqual(h.tool.description, VanStockTool.description(for: .store), "the phone's description comes back")
    }
}

/// The service's wiring of who holds the count (Plan MM §1, Decision 3).
@MainActor
final class VanStockServiceAuthorityTests: XCTestCase {

    private var h: StockSystemVanStockHarness!

    override func setUp() async throws {
        PolicyEnvelope.clear()
        h = StockSystemVanStockHarness()
    }

    override func tearDown() async throws {
        h.cleanUp()
        PolicyEnvelope.clear()
    }

    private func loadPhoneList() {
        _ = h.vanStock.load([.init(part: "ZX-455", description: "Run capacitor 45/5", quantity: .whole(7))])
        XCTAssertEqual(h.vanStore.log.items.count, 1)
    }

    func testThePhonesListIsKeptReadOnlyWhileTheSystemHoldsAndComesBackUnchanged() throws {
        loadPhoneList()
        let before = h.vanStore.log
        XCTAssertEqual(h.vanStock.authority, .phone)
        XCTAssertTrue(h.vanStock.check(.init(part: "ZX-455")).contains("7"))

        try h.connect()
        XCTAssertEqual(h.vanStock.authority, .system(connectorID: "square", locationIDs: [StockSystemConnectionSamples.main.id]))
        XCTAssertEqual(h.vanStock.check(.init(part: "ZX-455")), "3 × Run capacitor 45/5 (ZX-455) on the van in Square, as of 09:10.")
        let item = try XCTUnwrap(h.vanStore.log.items.first)

        // Nothing reaches the previous list while the system holds the count.
        h.job = .init(sessionID: "S1", reference: nil)
        _ = h.vanStock.use([.init(part: "ZX-455")])
        _ = h.vanStock.load([.init(part: "ZX-455", quantity: .whole(2))])
        _ = h.vanStock.count([.init(part: "ZX-455", quantity: .whole(1))])
        _ = h.vanStock.remove([.init(part: "ZX-455")], reason: .damaged)
        _ = h.vanStock.undo()
        _ = h.vanStock.setStandard(.init(part: "ZX-455", quantity: .whole(9)))
        _ = h.vanStock.loadToStandard()
        XCTAssertFalse(h.vanStock.setCount(itemID: item.id, to: .whole(40)))
        XCTAssertFalse(h.vanStock.edit(itemID: item.id, [.description("Renamed")]))
        XCTAssertEqual(h.vanStock.deletionBlock(itemID: item.id), .systemHolds)
        XCTAssertFalse(h.vanStock.deleteLine(itemID: item.id))
        XCTAssertNil(h.vanStock.noteOrdered(number: "ZX-455", quantity: 2, requestID: "R1"))
        XCTAssertFalse(h.vanStock.canUndo, "the screen's undo would touch the previous list")
        XCTAssertEqual(h.vanStore.log, before, "the previous list is read-only")
        XCTAssertTrue(h.recordedUses.isEmpty)

        // Removing the connection gives the phone's list back exactly as it was.
        h.disconnect()
        XCTAssertEqual(h.vanStock.authority, .phone)
        XCTAssertEqual(h.vanStore.log, before)
        XCTAssertTrue(h.vanStock.check(.init(part: "ZX-455")).contains("7"))
        _ = h.vanStock.use([.init(part: "ZX-455")])
        XCTAssertEqual(h.vanStore.log.level(of: item.id).onHand, .whole(6), "it counts again")
        XCTAssertEqual(h.recordedUses.count, 1)
    }

    func testTheOfficeRouteLeavesThePhoneHoldingTheCount() throws {
        loadPhoneList()
        try h.connect()
        var result = ProfileApplier.Result()
        result.ceilings[.organizationFieldServiceRoute] = .string("office")
        PolicyEnvelope.install(result, organizationName: "Office firm")
        XCTAssertEqual(h.vanStock.authority, .phone)
        XCTAssertNil(h.vanStock.systemDesk)
        XCTAssertTrue(h.vanStock.check(.init(part: "ZX-455")).contains("7"))
    }

    func testNoPlaceIsEverAnsweredBothWays() throws {
        loadPhoneList()
        func assertOneWay(_ label: String) {
            let authority = h.vanStock.authority
            XCTAssertEqual(authority.isSystem, h.vanStock.systemDesk != nil, label)
            XCTAssertEqual(authority.isSystem, h.vanStock.systemName != nil, label)
            XCTAssertEqual(authority.phoneList == .counting, !authority.isSystem, label)
            let check = h.vanStock.check(.init(part: "ZX-455"))
            XCTAssertEqual(check.contains("in Square"), authority.isSystem, "\(label): \(check)")
        }
        assertOneWay("no connection")
        try h.connect(locations: [])
        assertOneWay("no location chosen")
        try h.connect()
        assertOneWay("connected")
        h.disconnect()
        assertOneWay("removed")
    }

    func testAJobIsReadablePerJobForTheConfirmation() throws {
        try h.connect()
        h.job = .init(sessionID: "S1", reference: "1027")
        _ = h.vanStock.use([.init(part: "ZX-455"), .init(part: "CL-50", quantity: StockQuantity(scaled: 2_500))])
        h.job = .init(sessionID: "S2", reference: "1028")
        _ = h.vanStock.use([.init(part: "FU-10")])
        let first = try XCTUnwrap(h.system?.staged.entries(forJob: "S1"))
        XCTAssertEqual(first.map(\.use.itemID), ["ITEM-CAP", "ITEM-COOL"])
        XCTAssertEqual(first.map(\.use.quantity), [.whole(1), StockQuantity(scaled: 2_500)])
        XCTAssertEqual(h.system?.staged.entries(forJob: "S2").map(\.use.itemID), ["ITEM-FUSE"])
    }

    func testLeavingTheOrganisationClearsTheNotedUses() throws {
        try h.connect()
        h.job = .init(sessionID: "S1", reference: nil)
        _ = h.vanStock.use([.init(part: "ZX-455")])
        h.system?.remove()
        XCTAssertEqual(h.system?.staged.entries.count, 1, "removing the connection keeps the noted uses for the job")
        h.system?.removeAll()
        XCTAssertEqual(h.system?.staged.entries.count, 0)
    }
}
