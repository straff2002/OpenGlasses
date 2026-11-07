import XCTest
@testable import OpenGlasses

/// Plan KR P7 — what was done is said. In the partner's run a part came off the van in the same
/// request as a question about a test; the stock was recorded and the reply answered only the
/// question. Every `van_stock` write now ends with the one line the reply must carry; a read
/// carries none. Invented parts throughout.
@MainActor
final class KRStockSaidTests: XCTestCase {

    private var directory: URL!
    private var store: VanStockStore!
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)
    private var job: VanStockService.Job?
    private var counter = 0
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kr-stock-said-\(UUID().uuidString)", isDirectory: true)
        store = VanStockStore(directory: directory, now: clock)
        job = nil
        counter = 0
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private lazy var service: VanStockService = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return VanStockService(
            store: store,
            verify: { TaskPart(number: VaultPartsIndex.normalise($0), partDescription: nil, verified: false) },
            partsIndex: { VaultPartsIndex(files: []) },
            activeJob: { [unowned self] in self.job },
            now: { [unowned self] in self.clock },
            calendar: calendar,
            makeID: { [unowned self] in
                self.counter += 1
                return "id-\(self.counter)"
            },
            jobUses: .init(record: { _ in }, remove: { _ in }, notFromVan: { _ in true }, unrecorded: { [] }))
    }()

    private lazy var tool = VanStockTool(service: service)

    private func run(_ args: [String: Any]) async throws -> String {
        let answer = try await tool.execute(args: args)
        clock.addTimeInterval(60)
        return answer
    }

    /// The line the reply must carry, or nil when the result has none.
    private func sayLine(_ answer: String) -> String? {
        let last = answer.components(separatedBy: "\n").last ?? ""
        return last.hasPrefix(VanStockService.sayPrefix) ? last : nil
    }

    func testTakingAPartOffTheVanEndsWithWhatToSay() async throws {
        _ = try await run(["action": "load", "description": "Hot surface ignitor", "quantity": 2])
        job = .init(sessionID: "session-1", reference: "4410")
        let answer = try await run(["action": "use", "description": "hot surface ignitor"])
        XCTAssertTrue(answer.hasPrefix("Used 1 × Hot surface ignitor on job 4410."), answer)
        XCTAssertEqual(sayLine(answer),
                       "Say: 1 × Hot surface ignitor taken off the van for job 4410. "
                       + "Put this in the reply, whatever else the technician asked this turn.")
    }

    func testEveryWriteCarriesTheLine() async throws {
        let load = try await run(["action": "load", "description": "Pressure switch", "quantity": 3])
        XCTAssertEqual(sayLine(load)?.hasPrefix("Say: 3 × Pressure switch put on the van."), true, load)

        let removed = try await run(["action": "remove", "description": "pressure switch", "reason": "returned"])
        XCTAssertEqual(sayLine(removed)?.hasPrefix("Say: 1 × Pressure switch taken off the van (returned)."), true, removed)

        let counted = try await run(["action": "count", "description": "pressure switch", "quantity": 5])
        XCTAssertEqual(sayLine(counted)?.hasPrefix("Say: Pressure switch counted: 5 on the van."), true, counted)

        let undone = try await run(["action": "undo"])
        XCTAssertEqual(sayLine(undone)?.hasPrefix("Say: the last van stock entry taken back."), true, undone)

        let standard = try await run(["action": "set_standard", "description": "pressure switch", "quantity": 4])
        XCTAssertNotNil(sayLine(standard), standard)

        let notFromVan = try await run(["action": "not_from_van", "part": "PS-0001"])
        XCTAssertNotNil(sayLine(notFromVan), notFromVan)
    }

    func testSeveralPartsInOneCallAreSaidInOneLine() async throws {
        let answer = try await run(["action": "load", "items": [
            ["description": "Flame rod", "quantity": 2] as [String: Any],
            ["description": "Draft inducer", "quantity": 1] as [String: Any],
        ]])
        XCTAssertEqual(answer.components(separatedBy: "\n").filter { $0.hasPrefix(VanStockService.sayPrefix) }.count, 1)
        XCTAssertEqual(sayLine(answer)?.hasPrefix("Say: 2 × Flame rod put on the van; 1 × Draft inducer put on the van."),
                       true, answer)
    }

    func testReadsAndRefusalsCarryNoLine() async throws {
        _ = try await run(["action": "load", "description": "Flame rod", "quantity": 1])
        for args: [String: Any] in [["action": "check", "description": "flame rod"], ["action": "low"],
                                    ["action": "top_up"], ["action": "unrecorded"],
                                    ["action": "use", "part": "ZZ-404"],
                                    ["action": "load", "description": "Flame rod", "quantity": 0]] {
            let answer = try await run(args)
            XCTAssertNil(sayLine(answer), "\(args): \(answer)")
            XCTAssertFalse(answer.contains(VanStockService.sayPrefix), "\(args): \(answer)")
        }
    }

    func testTheLineIsAddedOnlyWhenSomethingWasDone() {
        XCTAssertEqual(VanStockService.saying("Nothing to do.", []), "Nothing to do.")
        XCTAssertEqual(VanStockService.saying("Loaded.", ["1 × Flame rod put on the van"]),
                       "Loaded.\nSay: 1 × Flame rod put on the van. "
                       + "Put this in the reply, whatever else the technician asked this turn.")
    }
}
