import XCTest
@testable import OpenGlasses

/// Plan GF P2 — running an installed add-on for the model: the gates checked again at run time,
/// memory writes namespaced and capped, the card handed to the display, the answer framed as data,
/// and the production transport's guard and error names.
@MainActor
final class AddOnRunServiceTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AddOnRunServiceTests_\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        MedicalEgressGuard.currentMode = { MedicalEgressGuard.Mode(hipaaMode: Config.hipaaMode, localOnly: Config.hipaaLocalOnly) }
        super.tearDown()
    }

    private func store(with data: Data) throws -> AddOnStore {
        let store = AddOnStore(directory: root.appendingPathComponent(UUID().uuidString), backupDirectory: root)
        let candidate = try XCTUnwrap(AddOnAdmission.review(data, installed: { _ in nil }, context: .init()).candidate)
        store.install(candidate, origin: .installed(via: .link))
        return store
    }

    private final class Sunk {
        var remembered: [(String, String, String)] = []
        var cards: [(String, RecipeDisplayPayload)] = []
        var announced: [String] = []
    }

    private func service(_ store: AddOnStore, transport: AddOnHTTPTransport = FakeAddOnHTTPTransport(json: "{}"),
                         conditions: AddOnAvailability.Conditions = .init(), medicalBlocks: Bool = false,
                         sunk: Sunk = Sunk()) -> AddOnRunService {
        AddOnRunService(
            runner: RecipeRunner(transport: transport, clock: FakeAddOnClock()),
            lookup: { try? store.loaded(id: $0).get() },
            conditions: { conditions },
            medicalBlocks: { medicalBlocks },
            context: { _ in RecipeAddOnFixtures.context },
            sinks: .init(remember: { id, key, value in sunk.remembered.append((id, key, value)); return true },
                         display: { name, payload in sunk.cards.append((name, payload)) },
                         announce: { sunk.announced.append($0) }))
    }

    private var currency: Data { Data(RecipeAddOnFixtures.currency.utf8) }

    func testACompletedRunIsFramedAsData() async throws {
        let transport = FakeAddOnHTTPTransport(json: #"{"rates":{"USD":"5.4"}}"#)
        let text = await service(try store(with: currency), transport: transport)
            .run(addOnID: "dev.frankfurter.currency", skill: "convert_currency",
                 arguments: ["amount": 5, "from": "EUR", "to": "USD"])
        XCTAssertTrue(text.contains("5 EUR is 5.4 USD"))
        XCTAssertTrue(text.contains("untrusted_tool_output"), "a host's words reach the model only as data")
        XCTAssertEqual(transport.requests.first?.url.host, "api.frankfurter.dev")
    }

    func testMemoryWritesAreNamespacedCappedAndNeedThePermission() async throws {
        let steps: [[String: Any]] = (1...3).map { ["remember": ["key": "k\($0)", "value": "v\($0)"]] } + [["say": "Saved."]]
        let withMemory = RecipeAddOnFixtures.file(skills: [RecipeAddOnFixtures.skill(steps: steps)],
                                                  permissions: ["memory": true])
        let sunk = Sunk()
        _ = await service(try store(with: withMemory), sunk: sunk)
            .run(addOnID: "org.example.test", skill: "look_up", arguments: [:])
        XCTAssertEqual(sunk.remembered.map(\.0), Array(repeating: "org.example.test", count: 3),
                       "every write is attributed to the add-on")
        XCTAssertEqual(sunk.remembered.map(\.1), ["k1", "k2", "k3"])
    }

    func testACardGoesToTheDisplaySink() async throws {
        let withDisplay = RecipeAddOnFixtures.file(skills: [RecipeAddOnFixtures.skill(steps: [
            ["display": ["kind": "list", "title": "Rates", "items": ["One", "Two"]]], ["say": "Here."],
        ])], permissions: ["display": true])
        let sunk = Sunk()
        _ = await service(try store(with: withDisplay), sunk: sunk)
            .run(addOnID: "org.example.test", skill: "look_up", arguments: [:])
        XCTAssertEqual(sunk.cards.first?.0, "Test add-on")
        XCTAssertEqual(sunk.cards.first?.1.items, ["One", "Two"])
    }

    func testMedicalComplianceRefusesANetworkAddOnAtRunTime() async throws {
        let transport = FakeAddOnHTTPTransport(json: "{}")
        var conditions = AddOnAvailability.Conditions()
        conditions.hipaaMode = true
        let text = await service(try store(with: currency), transport: transport, conditions: conditions)
            .run(addOnID: "dev.frankfurter.currency", skill: "convert_currency",
                 arguments: ["amount": 5, "from": "EUR", "to": "USD"])
        XCTAssertTrue(text.contains("Medical Compliance"))
        XCTAssertTrue(transport.requests.isEmpty, "nothing was sent")
    }

    func testLocalOnlyAtTheRequestEdgeSendsNothing() async throws {
        let transport = FakeAddOnHTTPTransport(json: "{}")
        let text = await service(try store(with: currency), transport: transport, medicalBlocks: true)
            .run(addOnID: "dev.frankfurter.currency", skill: "convert_currency",
                 arguments: ["amount": 5, "from": "EUR", "to": "USD"])
        XCTAssertEqual(text, MedicalEgressRefusal.userMessage)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testASwitchedOffOrRemovedAddOnDoesNotRun() async throws {
        let store = try store(with: currency)
        store.setEnabled(false, id: "dev.frankfurter.currency")
        let off = await service(store).run(addOnID: "dev.frankfurter.currency", skill: "convert_currency", arguments: [:])
        XCTAssertTrue(off.hasPrefix("That add-on can't run right now"))
        store.remove(id: "dev.frankfurter.currency")
        let gone = await service(store).run(addOnID: "dev.frankfurter.currency", skill: "convert_currency", arguments: [:])
        XCTAssertEqual(gone, "That add-on isn't installed any more.")
    }

    func testASlowAddOnSaysOneMomentFirst() async throws {
        let slow = RecipeAddOnFixtures.file(skills: [RecipeAddOnFixtures.skill(steps: [["say": "Done."]])],
                                            permissions: [:], overrides: ["slow": true])
        let sunk = Sunk()
        _ = await service(try store(with: slow), sunk: sunk).run(addOnID: "org.example.test", skill: "look_up", arguments: [:])
        XCTAssertEqual(sunk.announced, ["One moment."])
    }

    func testTheModelTextForEachOutcome() {
        func result(_ outcome: RecipeRunResult.Outcome, said: String = "") -> RecipeRunResult {
            RecipeRunResult(toolName: "t", outcome: outcome, spokenText: said, memoryWrites: [], display: nil,
                            requestsMade: 0)
        }
        XCTAssertEqual(AddOnRunService.modelText(for: result(.completed), toolName: "t", addOnName: "Tides"),
                       "Tides returned no answer.")
        XCTAssertTrue(AddOnRunService.modelText(for: result(.invalidArguments("amount is required")), toolName: "t",
                                                addOnName: "Tides").contains("amount is required"))
        XCTAssertTrue(AddOnRunService.modelText(for: result(.blockedCredential(["openai"])), toolName: "t",
                                                addOnName: "Tides").contains("Do not retry"))
        XCTAssertTrue(AddOnRunService.modelText(for: result(.timedOut, said: "Partial."), toolName: "t",
                                                addOnName: "Tides").contains("untrusted_tool_output"))
    }

    func testTheRunContextIsCoarseAndOnlyWithThePermission() {
        let none = AddOnRunContextSource.context(permissions: .empty, latitude: 51.507_35, longitude: -0.127_76)
        XCTAssertNil(none.location)
        var allowed = RecipeAddOnManifest.Permissions.empty
        allowed.location = true
        let some = AddOnRunContextSource.context(permissions: allowed, latitude: 51.507_35, longitude: -0.127_76,
                                                 locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(some.location?.latitude, 51.51)
        XCTAssertEqual(some.location?.longitude, -0.13)
        XCTAssertNil(some.location?.city)
        XCTAssertEqual(some.units, .metric)
    }

    // MARK: - The production transport

    func testTheTransportAsksTheMedicalGuardFirst() async {
        MedicalEgressGuard.currentMode = { .localOnly }
        do {
            _ = try await BoundedAddOnHTTPTransport().send(AddOnHTTPRequest(
                method: "GET", url: URL(string: "https://api.example.org/")!, headers: [:], body: nil,
                timeout: 15, maxResponseBytes: 1_000))
            XCTFail("Local Only must refuse the route before any socket")
        } catch {
            XCTAssertEqual(error as? MedicalEgressRefusal, MedicalEgressRefusal(route: .recipeAddOn))
        }
    }

    func testTheTransportNamesItsFailures() {
        XCTAssertEqual(BoundedAddOnHTTPTransport.mapped(.responseTooLarge) as? AddOnTransportError, .tooLarge)
        XCTAssertEqual(BoundedAddOnHTTPTransport.mapped(.unacceptableMIMEType) as? AddOnTransportError, .unsupportedType)
        XCTAssertEqual(BoundedAddOnHTTPTransport.mapped(.idleTimeout) as? AddOnTransportError, .timeout)
        XCTAssertEqual(BoundedAddOnHTTPTransport.mapped(.disallowedAddress) as? AddOnTransportError, .addressRefused)
        XCTAssertEqual(BoundedAddOnHTTPTransport.mapped(.transport) as? BoundedHTTPClient.ClientError, .transport)
    }

    func testTheSandboxKeepsANamedTransportFailure() async {
        let transport = FakeAddOnHTTPTransport { _ in throw AddOnTransportError.tooLarge }
        var sandbox = RecipeSandbox(rules: AddOnDomainRule.parseAllowlist(["api.example.org"]).rules,
                                    transport: transport, clock: FakeAddOnClock())
        let result = await sandbox.fetch(method: "GET", url: "https://api.example.org/x", headers: [:], body: nil,
                                         contentType: nil)
        XCTAssertEqual(result.error, "too_large")
    }
}
