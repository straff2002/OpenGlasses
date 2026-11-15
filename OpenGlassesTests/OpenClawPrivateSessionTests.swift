import XCTest
@testable import OpenGlasses

/// Plan LU §5 — the gateway in a private conversation: a throwaway session key made for it and
/// dropped at its end, the stable key and its generation untouched, and nothing pushed to or asked
/// of the gateway's memory.
@MainActor
final class OpenClawPrivateSessionTests: XCTestCase {

    private static let generationKey = "openClawSessionGeneration"
    private var savedGeneration: Any?
    private var directory: URL!

    override func setUp() {
        super.setUp()
        PrivateConversationGate.setActive(false)
        savedGeneration = UserDefaults.standard.object(forKey: Self.generationKey)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenClawPrivateSessionTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        PrivateConversationGate.setActive(false)
        if let savedGeneration {
            UserDefaults.standard.set(savedGeneration, forKey: Self.generationKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.generationKey)
        }
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testAPrivateConversationTalksUnderAThrowawayKeyAndLeavesTheStableOneAlone() {
        let bridge = OpenClawBridge()
        let stable = bridge.currentSessionKey
        let generation = UserDefaults.standard.integer(forKey: Self.generationKey)
        XCTAssertEqual(bridge.effectiveSessionKey, stable)
        XCTAssertNil(bridge.privateSessionKey)

        bridge.beginPrivateSession()
        let throwaway = try? XCTUnwrap(bridge.privateSessionKey)
        XCTAssertEqual(bridge.effectiveSessionKey, throwaway)
        XCTAssertNotEqual(throwaway, stable)
        XCTAssertTrue(throwaway?.hasPrefix("agent:main:glass:private:") == true, throwaway ?? "")
        XCTAssertEqual(bridge.currentSessionKey, stable, "the stable key is not rotated into")

        bridge.beginPrivateSession()
        XCTAssertEqual(bridge.privateSessionKey, throwaway, "one key for the whole private conversation")

        bridge.endPrivateSession()
        XCTAssertNil(bridge.privateSessionKey, "dropped at the end")
        XCTAssertEqual(bridge.effectiveSessionKey, stable)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: Self.generationKey), generation,
                       "the stable key's generation is untouched")

        bridge.beginPrivateSession()
        XCTAssertNotEqual(bridge.privateSessionKey, throwaway, "the next private conversation gets its own")
        bridge.endPrivateSession()
    }

    func testAThrowawayKeyIsNeverTheStableKeyOrAnotherConversations() {
        let first = OpenClawBridge.privateSessionKey(id: UUID())
        let second = OpenClawBridge.privateSessionKey(id: UUID())
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, "agent:main:glass")
        XCTAssertFalse(first.hasPrefix("agent:main:glass:1"))
    }

    func testNothingFromAPrivateConversationIsOfferedToTheGatewaysMemory() async {
        let memory = SemanticMemoryStore(directory: directory)

        PrivateConversationGate.setActive(true)
        _ = memory.parseAndExecuteCommands(in: "Sure. [REMEMBER: coffee = flat white]",
                                           userUtterance: "remember I like a flat white")
        XCTAssertEqual(memory.gatewayPushesOffered, 0, "no memory push while private")
        await memory.syncFromGateway()   // the query is skipped too; nothing is connected either way

        // The same reply outside a private conversation is offered — the check above can fail.
        PrivateConversationGate.setActive(false)
        _ = memory.parseAndExecuteCommands(in: "Sure. [REMEMBER: coffee = flat white]",
                                           userUtterance: "remember I like a flat white")
        XCTAssertEqual(memory.gatewayPushesOffered, 1)
    }
}
