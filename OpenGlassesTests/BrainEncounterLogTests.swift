import XCTest
@testable import OpenGlasses

/// The brain tool's `log_encounter` action: the encounter log's writer since face recognition was
/// removed. Who comes from what the user said; where comes from what they said, else the phone.
@MainActor
final class BrainEncounterLogTests: XCTestCase {

    private var tempRoot: URL!
    private var store: BrainStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrainEncounterLogTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = BrainStore(directory: tempRoot)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func tool(place: BrainTool.EncounterPlace? = nil) -> BrainTool {
        var tool = BrainTool()
        tool.brainStore = store
        tool.currentPlace = { place }
        return tool
    }

    func testANamedPlaceIsKeptAsSaidWithoutThePhonesCoordinates() async throws {
        let phone = BrainTool.EncounterPlace(name: "Wellington", latitude: -41.29, longitude: 174.78)
        let reply = try await tool(place: phone).execute(args: [
            "action": "log_encounter", "person": "Sam", "place": "the café on Cuba St",
            "text": "coffee about the Henderson job",
        ])
        XCTAssertEqual(reply, "Noted: you met Sam at the café on Cuba St.")
        let logged = try XCTUnwrap(store.encounters(for: "Sam").first)
        XCTAssertEqual(logged.locationName, "the café on Cuba St")
        XCTAssertNil(logged.latitude, "a place the user named may not be where the phone is")
        XCTAssertNil(logged.longitude)
        XCTAssertEqual(logged.context, "coffee about the Henderson job")
    }

    func testWithoutAPlaceThePhonesLocationIsUsed() async throws {
        let phone = BrainTool.EncounterPlace(name: "Wellington", latitude: -41.29, longitude: 174.78)
        let reply = try await tool(place: phone).execute(args: ["action": "met", "person": "Priya"])
        XCTAssertEqual(reply, "Noted: you met Priya at Wellington.")
        let logged = try XCTUnwrap(store.encounters(for: "Priya").first)
        XCTAssertEqual(logged.locationName, "Wellington")
        XCTAssertEqual(logged.latitude, -41.29)
        XCTAssertEqual(logged.longitude, 174.78)
        XCTAssertNil(logged.context)
    }

    func testWithNoLocationTheEncounterIsStillLogged() async throws {
        let reply = try await tool(place: nil).execute(args: ["action": "log_encounter", "person": "Dana"])
        XCTAssertEqual(reply, "Noted: you met Dana.")
        let logged = try XCTUnwrap(store.encounters(for: "Dana").first)
        XCTAssertNil(logged.locationName)
        XCTAssertNil(logged.latitude)
    }

    func testThePersonBecomesABrainEntity() async throws {
        _ = try await tool().execute(args: ["action": "log_encounter", "person": "Dana"])
        XCTAssertTrue(store.entityNames(mentionedIn: "lunch with Dana", kind: "person").contains("Dana"))
    }

    func testANoteTheWriteGateDeclinesIsLeftOutButTheEncounterIsKept() async throws {
        let reply = try await tool().execute(args: [
            "action": "log_encounter", "person": "Sam", "text": "ask how the chemo went",
        ])
        let logged = try XCTUnwrap(store.encounters(for: "Sam").first)
        XCTAssertNil(logged.context, "a declined note is not stored with the encounter")
        XCTAssertTrue(reply.hasPrefix("Noted: you met Sam."))
        XCTAssertGreaterThan(reply.count, "Noted: you met Sam.".count, "the model hears the gate's notice")
        XCTAssertFalse(reply.contains("chemo"), "the declined note is not echoed back")
    }

    func testAMissingPersonAsksWhoAndLogsNothing() async throws {
        let reply = try await tool().execute(args: ["action": "log_encounter", "person": "  "])
        XCTAssertEqual(reply, "Who did you meet?")
        XCTAssertTrue(store.encounters().isEmpty)
    }

    func testLoggedEncountersShowInTheListAndAreErasedWithThePerson() async throws {
        _ = try await tool().execute(args: ["action": "log_encounter", "person": "Sam", "place": "the depot"])
        let listed = try await tool().execute(args: ["action": "encounters", "person": "Sam"])
        XCTAssertTrue(listed.contains("Sam"))
        XCTAssertTrue(listed.contains("the depot"))
        _ = try await tool().execute(args: ["action": "forget", "person": "Sam"])
        XCTAssertTrue(store.encounters(for: "Sam").isEmpty)
    }

    func testTheActionIsDeclaredAndTitled() {
        let schema = BrainTool().parametersSchema
        let properties = schema["properties"] as? [String: Any]
        let action = properties?["action"] as? [String: Any]
        XCTAssertTrue((action?["enum"] as? [String])?.contains("log_encounter") ?? false)
        XCTAssertNotNil(properties?["place"])
        XCTAssertTrue(BrainTool().description.contains("log_encounter"))
    }
}
