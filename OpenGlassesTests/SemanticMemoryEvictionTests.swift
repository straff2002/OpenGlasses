import XCTest
@testable import OpenGlasses

/// Plan FI prerequisite — storage-cap eviction and memory-off in the memory tools.
///
/// Eviction is least-recently-written first (ties by id), never evicts the row the current write
/// produced, and a fact that alone exceeds its namespace's cap is refused up front: `remember`
/// returns false, the fact is not stored, any earlier value under the same key is kept, and nothing
/// else is evicted for it. Headless: temp-dir stores with small injected caps and a controlled clock.
@MainActor
final class SemanticMemoryEvictionTests: XCTestCase {

    /// A clock the test advances explicitly, so recency never depends on sleeping.
    private final class TestClock {
        var current = Date(timeIntervalSince1970: 1_800_000_000)
        func tick(_ seconds: TimeInterval = 1) { current = current.addingTimeInterval(seconds) }
    }

    private func makeStore(global: Int = 100, persona: Int = 100,
                           clock: TestClock) -> SemanticMemoryStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SemanticMemoryStore(directory: dir, maxGlobalChars: global, maxPersonaChars: persona,
                                   now: { clock.current })
    }

    // MARK: - Defaults

    func testProductionCapsAreRaised() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SemanticMemoryStore(directory: dir)
        XCTAssertEqual(store.maxGlobalChars, 20_000)
        XCTAssertEqual(store.maxPersonaChars, 10_000)
    }

    // MARK: - Oldest-written first

    /// The old policy evicted the shortest rows first, so a short, high-value fact was the first
    /// to go. Now the oldest-written row goes and the short new fact survives.
    func testShortFactSavedIntoFullStoreSurvivesAndOldestIsEvicted() {
        let clock = TestClock()
        let store = makeStore(global: 60, clock: clock)
        // Each row is 20 chars (key 2 + value 18): three rows fill the 60-char cap exactly.
        XCTAssertTrue(store.rememberGlobal("r1", value: String(repeating: "a", count: 18))); clock.tick()
        XCTAssertTrue(store.rememberGlobal("r2", value: String(repeating: "b", count: 18))); clock.tick()
        XCTAssertTrue(store.rememberGlobal("r3", value: String(repeating: "c", count: 18))); clock.tick()

        XCTAssertTrue(store.rememberGlobal("park", value: "lot B"), "a short fact must be kept")

        XCTAssertEqual(store.recall("park"), "lot B")
        XCTAssertNil(store.recall("r1"), "the oldest-written row is the one evicted")
        XCTAssertNotNil(store.recall("r2"))
        XCTAssertNotNil(store.recall("r3"))
        XCTAssertLessThanOrEqual(store.globalCharUsage, 60)
    }

    /// Only as many rows as needed go — the next-oldest survives when one eviction is enough.
    func testEvictsOnlyAsManyRowsAsNeeded() {
        let clock = TestClock()
        let store = makeStore(global: 60, clock: clock)
        store.rememberGlobal("r1", value: String(repeating: "a", count: 18)); clock.tick()
        store.rememberGlobal("r2", value: String(repeating: "b", count: 18)); clock.tick()
        store.rememberGlobal("r3", value: String(repeating: "c", count: 18)); clock.tick()
        // 38 chars: needs r1 and r2 gone (60 + 38 - 20 - 20 = 58).
        XCTAssertTrue(store.rememberGlobal("big", value: String(repeating: "d", count: 35)))
        XCTAssertNil(store.recall("r1"))
        XCTAssertNil(store.recall("r2"))
        XCTAssertNotNil(store.recall("r3"))
        XCTAssertNotNil(store.recall("big"))
    }

    // MARK: - Recency refresh

    func testRewritingAKeyRefreshesItsRecency() {
        let clock = TestClock()
        let store = makeStore(global: 60, clock: clock)
        store.rememberGlobal("r1", value: String(repeating: "a", count: 18)); clock.tick()
        store.rememberGlobal("r2", value: String(repeating: "b", count: 18)); clock.tick()
        store.rememberGlobal("r3", value: String(repeating: "c", count: 18)); clock.tick()
        // Rewrite r1 with a same-length new value: it becomes the newest row.
        XCTAssertTrue(store.rememberGlobal("r1", value: String(repeating: "z", count: 18))); clock.tick()

        XCTAssertTrue(store.rememberGlobal("new", value: "x"))

        XCTAssertEqual(store.recall("r1"), String(repeating: "z", count: 18),
                       "a rewritten key is no longer the eviction candidate")
        XCTAssertNil(store.recall("r2"), "the least-recently-written row goes instead")
        XCTAssertNotNil(store.recall("r3"))
        XCTAssertEqual(store.recall("new"), "x")
    }

    // MARK: - A write that cannot fit

    func testWriteLargerThanCapIsRefusedAndEvictsNothing() {
        let clock = TestClock()
        let store = makeStore(global: 60, clock: clock)
        store.rememberGlobal("r1", value: "zebra-7741"); clock.tick()
        store.rememberGlobal("r2", value: "short"); clock.tick()

        let oversized = String(repeating: "q", count: 61)
        XCTAssertFalse(store.rememberGlobal("huge", value: oversized),
                       "a fact larger than the cap must report that it was not saved")
        XCTAssertNil(store.recall("huge"), "the oversized fact is not readable afterwards")
        XCTAssertEqual(store.recall("r1"), "zebra-7741", "nothing else is evicted for it")
        XCTAssertEqual(store.recall("r2"), "short")
    }

    /// The refusal happens before the write, so an earlier value under the same key is kept.
    func testOversizedRewriteKeepsTheEarlierValue() {
        let clock = TestClock()
        let store = makeStore(global: 60, clock: clock)
        XCTAssertTrue(store.remember("note", value: "kept-value")); clock.tick()
        XCTAssertFalse(store.remember("note", value: String(repeating: "q", count: 80)))
        XCTAssertEqual(store.recall("note"), "kept-value")
    }

    /// A fact exactly at the cap fits (the cap is inclusive) and evicts everything else.
    func testFactExactlyAtCapFits() {
        let clock = TestClock()
        let store = makeStore(global: 60, clock: clock)
        store.rememberGlobal("r1", value: "old"); clock.tick()
        XCTAssertTrue(store.rememberGlobal("ab", value: String(repeating: "e", count: 58)))
        XCTAssertNotNil(store.recall("ab"))
        XCTAssertNil(store.recall("r1"))
    }

    // MARK: - Persona cap

    func testPersonaNamespaceUsesItsOwnCap() {
        let clock = TestClock()
        let store = makeStore(global: 1_000, persona: 40, clock: clock)
        store.activePersonaId = "projA"
        XCTAssertTrue(store.remember("p1", value: String(repeating: "a", count: 18))); clock.tick()
        XCTAssertTrue(store.remember("p2", value: String(repeating: "b", count: 18))); clock.tick()
        // 40 chars used; one more 20-char row must evict p1 under the 40-char persona cap even
        // though the global cap is far larger.
        XCTAssertTrue(store.remember("p3", value: String(repeating: "c", count: 18)))
        XCTAssertNil(store.personaMemories["p1"])
        XCTAssertNotNil(store.personaMemories["p2"])
        XCTAssertNotNil(store.personaMemories["p3"])
        XCTAssertLessThanOrEqual(store.personaCharUsage, 40)

        // A persona fact over the persona cap is refused even though it would fit the global cap.
        XCTAssertFalse(store.remember("p4", value: String(repeating: "d", count: 50)))
        XCTAssertNil(store.personaMemories["p4"])
    }

    /// A persona write never evicts global rows, and vice versa.
    func testEvictionStaysInsideTheWrittenNamespace() {
        let clock = TestClock()
        let store = makeStore(global: 1_000, persona: 40, clock: clock)
        store.rememberGlobal("g1", value: "global-fact"); clock.tick()
        store.activePersonaId = "projA"
        store.remember("p1", value: String(repeating: "a", count: 18)); clock.tick()
        store.remember("p2", value: String(repeating: "b", count: 18)); clock.tick()
        store.remember("p3", value: String(repeating: "c", count: 18))
        XCTAssertEqual(store.memories["g1"], "global-fact", "the older global row is not touched")
    }

    // MARK: - Tie-break

    /// Rows written at the same instant are evicted in id order (`global:<key>` ascending).
    func testEqualWriteTimesEvictInIdOrder() {
        let clock = TestClock()
        let store = makeStore(global: 60, clock: clock)
        // Same clock value for all three, written in reverse key order.
        store.rememberGlobal("r3", value: String(repeating: "c", count: 18))
        store.rememberGlobal("r2", value: String(repeating: "b", count: 18))
        store.rememberGlobal("r1", value: String(repeating: "a", count: 18))

        XCTAssertTrue(store.rememberGlobal("x", value: "y"))

        XCTAssertNil(store.recall("r1"), "lowest id goes first on a tie, regardless of write order")
        XCTAssertNotNil(store.recall("r2"))
        XCTAssertNotNil(store.recall("r3"))
    }

    // MARK: - Refused saves from [REMEMBER…] tags

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testOversizedTagAddsTheNoticeAndStoresNothing() {
        let clock = TestClock()
        let store = makeStore(global: 60, clock: clock)
        let huge = String(repeating: "q", count: 80)
        let out = store.parseAndExecuteCommands(in: "Sure thing. [REMEMBER_GLOBAL: bio = \(huge)]")

        XCTAssertEqual(occurrences(of: SemanticMemoryStore.saveFailedNotice, in: out), 1)
        XCTAssertFalse(out.contains("[REMEMBER"), "the tag is still stripped")
        XCTAssertTrue(out.hasPrefix("Sure thing."))
        XCTAssertNil(store.recall("bio"), "the refused value is not stored")
    }

    func testTwoFailedTagsAddTheNoticeOnce() {
        let clock = TestClock()
        let store = makeStore(global: 60, persona: 40, clock: clock)
        let huge = String(repeating: "q", count: 80)
        let out = store.parseAndExecuteCommands(
            in: "Noted. [REMEMBER: a = \(huge)] [REMEMBER_GLOBAL: b = \(huge)] [REMEMBER: c = \(huge)]")

        XCTAssertEqual(occurrences(of: SemanticMemoryStore.saveFailedNotice, in: out), 1)
        XCTAssertFalse(out.contains("[REMEMBER"))
        XCTAssertNil(store.recall("a"))
        XCTAssertNil(store.recall("b"))
        XCTAssertNil(store.recall("c"))
    }

    func testSuccessfulTagAddsNoNotice() {
        let clock = TestClock()
        let store = makeStore(global: 60, clock: clock)
        let out = store.parseAndExecuteCommands(in: "Got it. [REMEMBER: parking = lot B]")

        XCTAssertEqual(out, "Got it.")
        XCTAssertEqual(store.recall("parking"), "lot B")
    }

    /// A reply mixing tag kinds is stripped cleanly. Each pass used to match the original reply
    /// and cut the already-shortened text, so the second kind was removed at the wrong offsets.
    func testMixedTagKindsAreStrippedCleanly() {
        let clock = TestClock()
        let store = makeStore(global: 1_000, clock: clock)
        let out = store.parseAndExecuteCommands(
            in: "[REMEMBER_GLOBAL: home = Wellington] Done, I'll keep that. [REMEMBER: parking = lot B]")

        XCTAssertEqual(out, "Done, I'll keep that.")
        XCTAssertEqual(store.recall("home"), "Wellington")
        XCTAssertEqual(store.recall("parking"), "lot B")
    }

    /// One tag saved and one refused: the saved fact stays, and the notice still appears once.
    func testMixedTagsKeepTheGoodFactAndStillNotify() {
        let clock = TestClock()
        let store = makeStore(global: 60, clock: clock)
        let huge = String(repeating: "q", count: 80)
        let out = store.parseAndExecuteCommands(in: "OK. [REMEMBER: parking = lot B] [REMEMBER: bio = \(huge)]")

        XCTAssertEqual(occurrences(of: SemanticMemoryStore.saveFailedNotice, in: out), 1)
        XCTAssertEqual(store.recall("parking"), "lot B")
        XCTAssertNil(store.recall("bio"))
    }

    // MARK: - Memory off in the tools

    private func storeWithFact() -> SemanticMemoryStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SemanticMemoryStore(directory: dir)
        // "zebra-7741" appears only in the stored value, never in a query, so a no-results message
        // echoing the query cannot trip the absence assertions.
        XCTAssertTrue(store.rememberGlobal("parking spot", value: "level 3 bay zebra-7741"))
        return store
    }

    func testMemorySearchReadsNothingWhenMemoryIsOff() async throws {
        let store = storeWithFact()
        var tool = MemorySearchTool()
        tool.memoryStore = store
        tool.activeNamespace = { "global" }

        tool.memoryEnabled = { true }
        let on = try await tool.execute(args: ["query": "parking spot"])
        XCTAssertTrue(on.contains("zebra-7741"), "control: with memory on the fact is found")

        tool.memoryEnabled = { false }
        let off = try await tool.execute(args: ["query": "parking spot"])
        XCTAssertFalse(off.contains("zebra-7741"), "memory off must not surface saved facts")
        XCTAssertTrue(off.localizedCaseInsensitiveContains("turned off"))
    }

    func testBrainQueryReadsNoMemoryWhenMemoryIsOff() async throws {
        let store = storeWithFact()
        var brain = BrainTool()
        brain.memoryStore = store
        brain.activeNamespace = { "global" }

        brain.memoryEnabled = { true }
        let on = try await brain.execute(args: ["action": "query", "question": "parking spot"])
        XCTAssertTrue(on.contains("zebra-7741"), "control: with memory on the fact is found")

        brain.memoryEnabled = { false }
        let off = try await brain.execute(args: ["action": "query", "question": "parking spot"])
        XCTAssertFalse(off.contains("zebra-7741"), "memory off must not surface saved facts")
        XCTAssertFalse(off.contains("no matching facts") || off.contains("remembered facts,")
                       || off.hasSuffix("remembered facts"),
                       "memory off must not be reported as 'no remembered facts found'")
        XCTAssertTrue(off.contains("switched off"), "memory off is named as switched off")
    }

    func testBrainDossierReadsNoMemoryWhenMemoryIsOff() async throws {
        let store = storeWithFact()
        XCTAssertTrue(store.rememberGlobal("quillon", value: "quillon owes me zebra-7741"))
        var brain = BrainTool()
        brain.memoryStore = store
        brain.activeNamespace = { "global" }

        brain.memoryEnabled = { false }
        let off = try await brain.execute(args: ["action": "person", "person": "quillon"])
        XCTAssertFalse(off.contains("zebra-7741"), "the dossier must not read saved facts when off")
    }
}
