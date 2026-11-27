import XCTest
@testable import OpenGlasses

/// Plan NJ §1, §3 and §6 on the phone's own log: a clinical list never takes a job reference from
/// an open field session; a clinic's staff code is kept only on a waste, a removal or a count that
/// disagreed, never on a dose given and never on a van; older logs and lines decode unchanged; and
/// the sensitive flag is an edit an undo takes back. Invented lines and codes only.
@MainActor
final class VanStockServiceClinicalTests: XCTestCase {

    private var directory: URL!
    private var store: VanStockStore!
    private var clock = Date(timeIntervalSince1970: 1_795_341_600)
    private var counter = 0
    private var clinical = true
    private var job: VanStockService.Job? = VanStockService.Job(sessionID: "session-1", reference: "JOB-7731")
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clinical-service-\(UUID().uuidString)", isDirectory: true)
        store = VanStockStore(directory: directory, now: clock, profileClinical: .some(nil))
        counter = 0
        clinical = true
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private lazy var service = VanStockService(
        store: store, place: { .stock }, partsIndex: { VaultPartsIndex(files: []) },
        activeJob: { [unowned self] in self.job },
        now: { [unowned self] in self.clock },
        makeID: { [unowned self] in
            self.counter += 1
            return "id-\(self.counter)"
        },
        clinical: { [unowned self] in self.clinical })

    private func step() { clock = clock.addingTimeInterval(30) }
    private func line(_ quantity: Int) -> VanStockService.Line {
        VanStockService.Line(description: "Flu vaccine", quantity: StockQuantity(whole: quantity))
    }
    private var last: VanStockMovement? { store.log.movements.last }

    // MARK: - No job reference on a clinic's list

    func testAClinicalListTakesNoJobReferenceFromAnOpenSession() {
        _ = service.load([line(10)])
        XCTAssertEqual(last?.kind, .loaded)
        XCTAssertNil(last?.jobReference)
        XCTAssertNil(last?.jobSessionID)
        step()
        _ = service.use([line(1)])
        XCTAssertEqual(last?.kind, .used)
        XCTAssertNil(last?.jobReference, "a dose is never tied to a job")
        XCTAssertNil(last?.jobSessionID)
    }

    func testAVanStillTagsItsUseToTheOpenJob() {
        clinical = false
        _ = service.load([line(10)])
        step()
        _ = service.use([line(1)])
        XCTAssertEqual(last?.jobReference, "JOB-7731")
        XCTAssertEqual(last?.jobSessionID, "session-1")
    }

    // MARK: - The staff code (Decision 3)

    func testAStaffCodeIsKeptOnAWasteAndARemoval() {
        _ = service.load([line(10)])
        step()
        _ = service.waste([line(1)], reason: .coldChain, staffCode: "ab1")
        XCTAssertEqual(last?.kind, .wasted)
        XCTAssertEqual(last?.staffCode, "AB1")
        step()
        _ = service.remove([line(1)], reason: .returned, staffCode: "QX7")
        XCTAssertEqual(last?.kind, .removed)
        XCTAssertEqual(last?.staffCode, "QX7")
    }

    func testNoStaffCodeOnADoseGivenOrReceived() {
        _ = service.load([line(10)])
        XCTAssertNil(last?.staffCode)
        var log = store.log
        let item = log.items[0]
        log.record(.used, itemID: item.id, quantity: StockQuantity(whole: 1), at: clock, batch: "g", source: .spoken,
                   staffCode: "AB1")
        XCTAssertNil(log.movements.last?.staffCode, "the ledger keeps no code on a dose given")
        log.record(.loaded, itemID: item.id, quantity: StockQuantity(whole: 1), at: clock, batch: "l", source: .spoken,
                   staffCode: "AB1")
        XCTAssertNil(log.movements.last?.staffCode)
    }

    func testACountKeepsAStaffCodeOnlyWhenItDisagreed() {
        _ = service.load([line(10)])
        step()
        _ = service.count([line(10)], staffCode: "AB1")
        XCTAssertEqual(last?.kind, .counted)
        XCTAssertNil(last?.staffCode, "a count that matched needs nobody's code")
        step()
        _ = service.count([line(8)], staffCode: "AB1")
        XCTAssertEqual(last?.kind, .counted)
        XCTAssertEqual(last?.staffCode, "AB1")
    }

    func testAVanKeepsNoStaffCode() {
        clinical = false
        _ = service.load([line(10)])
        step()
        _ = service.remove([line(1)], reason: .damaged, staffCode: "AB1")
        XCTAssertNil(last?.staffCode)
    }

    func testAStaffCodeIsLettersAndDigitsUpToEight() {
        XCTAssertEqual(StaffCode.clean(" ab12 "), "AB12")
        XCTAssertEqual(StaffCode.clean("ABCDEFGH"), "ABCDEFGH")
        XCTAssertNil(StaffCode.clean("ABCDEFGHI"), "nine is too long")
        XCTAssertNil(StaffCode.clean("Jo Smith"), "a space is not a code")
        XCTAssertNil(StaffCode.clean("A-1"))
        XCTAssertNil(StaffCode.clean("é1"))
        XCTAssertNil(StaffCode.clean(""))
        XCTAssertNil(StaffCode.clean(nil))
        _ = service.load([line(10)])
        step()
        _ = service.waste([line(1)], reason: .expired, staffCode: "Jo Smith")
        XCTAssertNil(last?.staffCode, "a code that is not one is not kept")
    }

    func testTheToolPassesTheStaffCodeAndOffersItOnlyToAClinic() async throws {
        _ = service.load([line(10)])
        step()
        let tool = VanStockTool(service: service)
        _ = try await tool.execute(args: ["action": "waste", "description": "Flu vaccine", "quantity": 1,
                                          "waste_reason": "cold_chain", "staff_code": "AB1"])
        XCTAssertEqual(last?.kind, .wasted)
        XCTAssertEqual(last?.staffCode, "AB1")
        let clinic = try XCTUnwrap(VanStockTool.parametersSchema(for: .stock, clinical: true)["properties"] as? [String: Any])
        XCTAssertNotNil(clinic["staff_code"])
        let van = try XCTUnwrap(VanStockTool.parametersSchema(for: .van)["properties"] as? [String: Any])
        XCTAssertNil(van["staff_code"])
    }

    // MARK: - Older logs and lines

    func testAMovementFromBeforeTheStaffCodeDecodesUnchanged() throws {
        let json = Data(#"{"id":"m1","item_id":"flu","kind":"wasted","quantity":1000,"at":"2026-11-22T10:00:00Z","batch":"b","source":"spoken","waste_reason":"expired"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let movement = try decoder.decode(VanStockMovement.self, from: json)
        XCTAssertNil(movement.staffCode)
        XCTAssertEqual(movement.wasteReason, .expired)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var coded = movement
        coded.staffCode = "AB1"
        let back = try decoder.decode(VanStockMovement.self, from: encoder.encode(coded))
        XCTAssertEqual(back.staffCode, "AB1")
        XCTAssertFalse(String(decoding: try encoder.encode(movement), as: UTF8.self).contains("staff_code"),
                       "a movement with no code writes none")
    }

    func testALineFromBeforeTheSensitiveFlagDecodesAsNotSensitive() throws {
        let json = Data(#"{"id":"flu","description":"Flu vaccine","unit":"each","codes":[],"verified":false,"created_batch":"b"}"#.utf8)
        let item = try JSONDecoder().decode(VanStockItem.self, from: json)
        XCTAssertFalse(item.isSensitive)
        XCTAssertNil(item.sensitive)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(item), as: UTF8.self).contains("sensitive"))
    }

    func testMarkingALineSensitiveIsAnEditAnUndoTakesBack() {
        _ = service.load([line(10)])
        let id = store.log.items[0].id
        step()
        XCTAssertTrue(service.edit(itemID: id, [.sensitive(true)]))
        XCTAssertTrue(store.log.item(id: id)?.isSensitive == true)
        XCTAssertEqual(last?.attribute, .sensitive)
        step()
        _ = service.undo()
        XCTAssertFalse(store.log.item(id: id)?.isSensitive == true)
    }
}
