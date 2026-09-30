import CoreLocation
import XCTest
@testable import OpenGlasses

/// Plan GH P1 — the `parking` tool against a temp-directory store and faked device edges.
@MainActor
final class ParkingToolTests: XCTestCase {

    private var directory: URL!
    private var store: ParkingStore!
    private var history = false
    private var location: CLLocation?
    private var pins: [String] = []
    private var directionsCalls: [(CLLocationCoordinate2D, String)] = []
    private var ingested: [String] = []
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParkingToolTests_\(UUID().uuidString)", isDirectory: true)
        history = false
        store = ParkingStore(directory: directory, keepHistory: { [unowned self] in self.history })
        location = CLLocation(coordinate: .init(latitude: -36.85, longitude: 174.76), altitude: 0,
                              horizontalAccuracy: 12, verticalAccuracy: -1, timestamp: now)
        pins = []
        directionsCalls = []
        ingested = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeTool(photoFlow: ParkingPhotoFlow? = nil) -> ParkingTool {
        ParkingTool(seams: .init(
            store: { [unowned self] in self.store },
            currentLocation: { [unowned self] in self.location },
            photoFlow: { photoFlow },
            startDirections: { [unowned self] coordinate, label in
                self.directionsCalls.append((coordinate, label))
                return "Starting walking directions to \(label)."
            },
            showPin: { [unowned self] line in self.pins.append(line) },
            metric: { true },
            now: { [unowned self] in self.now },
            keepHistory: { [unowned self] in self.history },
            ingest: { [unowned self] text in self.ingested.append(text) }))
    }

    func testSavingByVoiceParsesTheDetailsAndKeepsTheFix() async throws {
        let reply = try await makeTool().execute(args: ["action": "save", "details": "level 2, space 41"])
        XCTAssertEqual(store.active?.level, "2")
        XCTAssertEqual(store.active?.space, "41")
        XCTAssertEqual(store.active?.capture, .voice)
        XCTAssertEqual(store.active?.latitude, -36.85)
        XCTAssertTrue(reply.contains("level 2, space 41"), reply)
    }

    func testDetailsWithoutAnActionMeanSave() async throws {
        _ = try await makeTool().execute(args: ["details": "P3 bay B12"])
        XCTAssertEqual(store.active?.level, "3")
        XCTAssertEqual(store.active?.space, "B12")
    }

    func testSavingWithoutAFixSaysSoAndKeepsTheDetails() async throws {
        location = nil
        let reply = try await makeTool().execute(args: ["action": "save", "details": "B2 space 7"])
        XCTAssertNil(store.active?.coordinate)
        XCTAssertEqual(store.active?.level, "B2")
        XCTAssertTrue(reply.contains("couldn't get a GPS fix"), reply)
    }

    func testRecallWithNothingSavedExplainsHowToSave() async throws {
        let reply = try await makeTool().execute(args: ["action": "where"])
        XCTAssertTrue(reply.contains("don't have a parking spot saved"), reply)
        XCTAssertTrue(pins.isEmpty)
    }

    func testRecallSpeaksAndPinsTheSpotOnTheGlasses() async throws {
        let tool = makeTool()
        _ = try await tool.execute(args: ["action": "save", "details": "level 2 space 41"])
        let reply = try await tool.execute(args: [:])
        XCTAssertTrue(reply.hasPrefix("You parked on level 2, space 41."), reply)
        XCTAssertEqual(pins.last?.hasPrefix("Car · L2 · 41"), true, pins.description)
    }

    func testDirectionsWalkToTheSavedCoordinate() async throws {
        let tool = makeTool()
        _ = try await tool.execute(args: ["action": "save", "details": "level 2"])
        let reply = try await tool.execute(args: ["action": "directions"])
        XCTAssertEqual(directionsCalls.count, 1)
        XCTAssertEqual(directionsCalls.first?.0.latitude, -36.85)
        XCTAssertEqual(directionsCalls.first?.1, "your car")
        XCTAssertTrue(reply.contains("your car"), reply)
    }

    func testDirectionsWithoutACoordinateAreRefusedHonestly() async throws {
        location = nil
        let tool = makeTool()
        _ = try await tool.execute(args: ["action": "save", "details": "level 2"])
        let reply = try await tool.execute(args: ["action": "directions"])
        XCTAssertTrue(directionsCalls.isEmpty)
        XCTAssertTrue(reply.contains("don't have a map position"), reply)
    }

    func testUpdateCorrectsTheSavedSpace() async throws {
        let tool = makeTool()
        _ = try await tool.execute(args: ["action": "save", "details": "level 2 space 41"])
        _ = try await tool.execute(args: ["action": "update", "details": "space 14"])
        XCTAssertEqual(store.active?.level, "2")
        XCTAssertEqual(store.active?.space, "14")
    }

    func testClearForgetsTheSpot() async throws {
        let tool = makeTool()
        _ = try await tool.execute(args: ["action": "save", "details": "level 2"])
        _ = try await tool.execute(args: ["action": "clear"])
        XCTAssertNil(store.active)
    }

    func testHistoryIsOffByDefaultAndTheGraphIsNotFed() async throws {
        let tool = makeTool()
        _ = try await tool.execute(args: ["action": "save", "details": "level 2"])
        let reply = try await tool.execute(args: ["action": "history"])
        XCTAssertTrue(reply.contains("history is off"), reply)
        XCTAssertTrue(ingested.isEmpty, "with history off the graph must not keep a copy")
    }

    func testHistoryOnListsSpotsAndFeedsTheGraph() async throws {
        history = true
        let tool = makeTool()
        _ = try await tool.execute(args: ["action": "save", "details": "level 1"])
        _ = try await tool.execute(args: ["action": "save", "details": "level 2"])
        let reply = try await tool.execute(args: ["action": "history"])
        XCTAssertTrue(reply.contains("on level 2"), reply)
        XCTAssertTrue(reply.contains("on level 1"), reply)
        XCTAssertEqual(ingested, ["I parked on level 1", "I parked on level 2"])
    }

    func testPhotoWithoutACameraStillSavesTheSpot() async throws {
        let reply = try await makeTool(photoFlow: ParkingPhotoFlow()).execute(args: ["action": "photo"])
        XCTAssertNotNil(store.active)
        XCTAssertNil(store.active?.photoFile)
        XCTAssertTrue(reply.contains("camera isn't available"), reply)
    }

    func testTheToolIsRegisteredAndSaveLocationNoLongerClaimsParking() {
        let registry = NativeToolRegistry(locationService: LocationService())
        XCTAssertNotNil(registry.tool(named: "parking"))
        let saveLocation = registry.tool(named: "save_location")?.description.lowercased() ?? ""
        XCTAssertFalse(saveLocation.contains("where they parked"))
        XCTAssertTrue(saveLocation.contains("parking tool"))
    }
}
