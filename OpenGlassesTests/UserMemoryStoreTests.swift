import XCTest
@testable import OpenGlasses

/// Tests for UserMemoryStore: CRUD, persona isolation, character budgets, command parsing, nudges.
@MainActor
final class UserMemoryStoreTests: XCTestCase {

    private var store: UserMemoryStore!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "hipaaMode")
        store = UserMemoryStore()
        store.clearAll()
    }

    override func tearDown() {
        store.clearAll()
        UserDefaults.standard.removeObject(forKey: "hipaaMode")
        super.tearDown()
    }

    // MARK: - Basic CRUD

    func testRememberAndRecall() {
        store.remember("name", value: "Alice")
        XCTAssertEqual(store.recall("name"), "Alice")
    }

    func testKeyNormalization() {
        store.remember("  User Name  ", value: "Bob")
        XCTAssertEqual(store.recall("user name"), "Bob")
        XCTAssertEqual(store.recall("  USER NAME  "), "Bob")
    }

    func testEmptyKeyIgnored() {
        store.remember("", value: "should not store")
        XCTAssertTrue(store.memories.isEmpty)
    }

    func testEmptyValueIgnored() {
        store.remember("key", value: "")
        XCTAssertNil(store.recall("key"))
    }

    func testForget() {
        store.remember("city", value: "Auckland")
        XCTAssertNotNil(store.recall("city"))

        store.forget("city")
        XCTAssertNil(store.recall("city"))
    }

    func testForgetNonexistentKeyDoesNotCrash() {
        store.forget("nonexistent")
        // Should not crash
    }

    func testUpdateExistingMemory() {
        store.remember("color", value: "blue")
        store.remember("color", value: "violet")
        XCTAssertEqual(store.recall("color"), "violet")
    }

    func testDuplicateExactValueNotRewritten() {
        store.remember("pet", value: "cat")
        let countBefore = store.memories.count
        store.remember("pet", value: "cat") // exact same
        XCTAssertEqual(store.memories.count, countBefore)
    }

    func testClearAll() {
        store.remember("a", value: "1")
        store.remember("b", value: "2")
        store.clearAll()
        XCTAssertTrue(store.memories.isEmpty)
    }

    // MARK: - Persona Isolation

    func testPersonaMemoriesIsolatedFromGlobal() {
        store.remember("global_fact", value: "shared")

        store.activePersonaId = "claude"
        store.remember("persona_fact", value: "isolated")

        // Persona should see persona_fact
        XCTAssertEqual(store.recall("persona_fact"), "isolated")
        // Persona should also see global (fallback)
        XCTAssertEqual(store.recall("global_fact"), "shared")
        // But persona_fact should NOT be in global
        XCTAssertNil(store.memories["persona_fact"])
    }

    func testRememberGlobalAlwaysGoesToGlobal() {
        store.activePersonaId = "claude"
        store.rememberGlobal("timezone", value: "NZST")

        // Should be in global, not persona
        XCTAssertEqual(store.memories["timezone"], "NZST")
        XCTAssertNil(store.personaMemories["timezone"])
    }

    func testSwitchingPersonaClearsPersonaMemories() {
        store.activePersonaId = "claude"
        store.remember("style", value: "formal")

        store.activePersonaId = "jarvis"
        // New persona should not see claude's memories
        XCTAssertNil(store.personaMemories["style"])
    }

    func testForgetFromPersonaFirst() {
        store.remember("global_key", value: "global_val")
        store.activePersonaId = "claude"
        store.remember("global_key", value: "persona_val")

        // Forget should remove persona version first
        store.forget("global_key")
        XCTAssertNil(store.personaMemories["global_key"])
        // Global should still exist
        XCTAssertEqual(store.memories["global_key"], "global_val")
    }

    // MARK: - Character Budget

    func testGlobalCharBudgetTrimsWhenExceeded() {
        // Fill with a lot of data
        for i in 0..<200 {
            store.remember("key_\(i)", value: String(repeating: "x", count: 20))
        }
        let totalChars = store.globalCharUsage
        XCTAssertLessThanOrEqual(totalChars, 3000,
                                  "Global memories should be trimmed to character budget")
    }

    func testPersonaCharBudgetTrimsWhenExceeded() {
        store.activePersonaId = "claude"
        for i in 0..<200 {
            store.remember("pkey_\(i)", value: String(repeating: "y", count: 15))
        }
        let totalChars = store.personaCharUsage
        XCTAssertLessThanOrEqual(totalChars, 1500,
                                  "Persona memories should be trimmed to character budget")
    }

    // MARK: - Command Parsing

    func testParseRememberCommand() {
        let response = "Sure! [REMEMBER: favorite_food = sushi] I'll keep that in mind."
        let cleaned = store.parseAndExecuteCommands(in: response)

        XCTAssertEqual(store.recall("favorite_food"), "sushi")
        XCTAssertFalse(cleaned.contains("[REMEMBER:"))
        XCTAssertTrue(cleaned.contains("Sure!"))
        XCTAssertTrue(cleaned.contains("keep that in mind"))
    }

    func testParseRememberGlobalCommand() {
        store.activePersonaId = "claude"
        let response = "[REMEMBER_GLOBAL: user_name = Greig] Got it!"
        let cleaned = store.parseAndExecuteCommands(in: response)

        // Should be in global, not persona
        XCTAssertEqual(store.memories["user_name"], "Greig")
        XCTAssertNil(store.personaMemories["user_name"])
        XCTAssertFalse(cleaned.contains("[REMEMBER_GLOBAL:"))
    }

    func testParseForgetCommand() {
        store.remember("old_fact", value: "outdated")
        let response = "Updated! [FORGET: old_fact]"
        _ = store.parseAndExecuteCommands(in: response)

        XCTAssertNil(store.recall("old_fact"))
    }

    func testParseMultipleCommands() {
        let response = """
        [REMEMBER: city = Wellington] [REMEMBER: role = developer] [FORGET: old_city] Done!
        """
        let cleaned = store.parseAndExecuteCommands(in: response)

        XCTAssertEqual(store.recall("city"), "Wellington")
        XCTAssertEqual(store.recall("role"), "developer")
        XCTAssertTrue(cleaned.contains("Done!"))
        XCTAssertFalse(cleaned.contains("[REMEMBER:"))
        XCTAssertFalse(cleaned.contains("[FORGET:"))
    }

    func testParseNoCommands() {
        let response = "Just a normal response with no commands."
        let cleaned = store.parseAndExecuteCommands(in: response)
        XCTAssertEqual(cleaned, response)
    }

    // MARK: - System Prompt Context

    func testSystemPromptContextNilWhenEmpty() {
        XCTAssertNil(store.systemPromptContext())
    }

    func testSystemPromptContextIncludesGlobalMemories() {
        store.remember("name", value: "Greig")
        let ctx = store.systemPromptContext()
        XCTAssertNotNil(ctx)
        XCTAssertTrue(ctx!.contains("SHARED MEMORY"))
        XCTAssertTrue(ctx!.contains("name: Greig"))
    }

    func testSystemPromptContextIncludesPersonaMemories() {
        store.remember("global", value: "fact")
        store.activePersonaId = "claude"
        store.remember("style", value: "casual")

        let ctx = store.systemPromptContext()
        XCTAssertNotNil(ctx)
        XCTAssertTrue(ctx!.contains("PERSONA MEMORY"))
        XCTAssertTrue(ctx!.contains("style: casual"))
    }

    // MARK: - Nudge System

    func testNudgeTriggersAfterInterval() {
        for _ in 0..<7 {
            XCTAssertFalse(store.incrementTurnAndCheckNudge())
        }
        // 8th turn should trigger nudge
        XCTAssertTrue(store.incrementTurnAndCheckNudge())
    }

    func testNudgeResetsAfterTrigger() {
        for _ in 0..<8 {
            _ = store.incrementTurnAndCheckNudge()
        }
        // Counter should have reset
        XCTAssertEqual(store.turnsSinceLastNudge, 0)
    }

    func testNudgePromptExists() {
        XCTAssertFalse(UserMemoryStore.nudgePrompt.isEmpty)
        XCTAssertTrue(UserMemoryStore.nudgePrompt.contains("REMEMBER"))
    }

    // MARK: - HIPAA Guards

    func testGatewaySyncBlockedInHipaaMode() async {
        Config.hipaaMode = true
        // Should not crash — the guard returns early
        await store.syncFromGateway(query: "test")
        // gatewayMemories should remain empty
        XCTAssertTrue(store.gatewayMemories.isEmpty)
    }
}
