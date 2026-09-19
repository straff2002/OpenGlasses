import XCTest
@testable import OpenGlasses

/// Plan FI prerequisite — when no semantic ranking applies, the prompt memory block keeps the most
/// recently written facts (newest first) instead of the alphabetically first. Persona memory uses
/// the same order; semantic results keep their own order. Headless: temp-dir store, injected clock.
@MainActor
final class MemoryRecentFirstRenderTests: XCTestCase {

    private final class TestClock {
        var current = Date(timeIntervalSince1970: 1_800_000_000)
        func tick(_ seconds: TimeInterval = 1) { current = current.addingTimeInterval(seconds) }
    }

    private func makeStore(clock: TestClock) -> SemanticMemoryStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SemanticMemoryStore(directory: dir, now: { clock.current })
    }

    /// Keys of the bullet lines in one section, in rendered order.
    private func keys(in context: String, section header: String) -> [String] {
        let sections = context.components(separatedBy: "\n\n")
        guard let block = sections.first(where: { $0.hasPrefix(header) }) else { return [] }
        return block.components(separatedBy: "\n")
            .filter { $0.hasPrefix("- ") }
            .compactMap { $0.dropFirst(2).components(separatedBy: ":").first }
    }

    /// Twelve facts written k00…k11 in order, so alphabetical and oldest-first coincide and the
    /// old alphabetical render would have shown k00…k07.
    private func writeTwelve(_ store: SemanticMemoryStore, clock: TestClock, global: Bool = true) {
        for i in 0..<12 {
            let key = String(format: "k%02d", i)
            if global { store.rememberGlobal(key, value: "v\(i)") } else { store.remember(key, value: "v\(i)") }
            clock.tick()
        }
    }

    func testNoQueryShowsTheEightMostRecentNewestFirst() {
        let clock = TestClock()
        let store = makeStore(clock: clock)
        writeTwelve(store, clock: clock)

        let context = store.systemPromptContext(query: nil) ?? ""
        XCTAssertEqual(keys(in: context, section: "SHARED MEMORY"),
                       ["k11", "k10", "k09", "k08", "k07", "k06", "k05", "k04"])
    }

    func testRewritingAnOldKeyBringsItBackIntoTheEight() {
        let clock = TestClock()
        let store = makeStore(clock: clock)
        writeTwelve(store, clock: clock)
        XCTAssertTrue(store.rememberGlobal("k00", value: "updated"))

        let shown = keys(in: store.systemPromptContext(query: nil) ?? "", section: "SHARED MEMORY")
        XCTAssertEqual(shown.first, "k00", "the re-written key is now the newest")
        XCTAssertEqual(shown, ["k00", "k11", "k10", "k09", "k08", "k07", "k06", "k05"])
    }

    func testPersonaSectionFollowsTheSameOrder() {
        let clock = TestClock()
        let store = makeStore(clock: clock)
        store.activePersonaId = "projA"
        writeTwelve(store, clock: clock, global: false)

        let context = store.systemPromptContext(query: nil) ?? ""
        XCTAssertEqual(keys(in: context, section: "PERSONA MEMORY"),
                       ["k11", "k10", "k09", "k08", "k07", "k06", "k05", "k04"])
    }

    /// Facts written at the same instant fall back to key order, never dictionary order.
    func testTiesAreBrokenByKey() {
        let clock = TestClock()
        let store = makeStore(clock: clock)
        for key in ["delta", "alpha", "charlie", "bravo"] { store.rememberGlobal(key, value: "x") }
        clock.tick()
        store.rememberGlobal("zulu", value: "newest")

        for _ in 0..<5 {
            let shown = keys(in: store.systemPromptContext(query: nil) ?? "", section: "SHARED MEMORY")
            XCTAssertEqual(shown, ["zulu", "alpha", "bravo", "charlie", "delta"])
        }
    }

    /// Recency applies only where no semantic ranking does: semantic hits keep their own order.
    func testSemanticResultsKeepTheirOrder() throws {
        let clock = TestClock()
        let store = makeStore(clock: clock)
        let facts = [("favourite drink", "flat white coffee"), ("car", "blue hatchback"),
                     ("coffee shop", "the corner cafe serves coffee"), ("dog", "a spaniel named Rex"),
                     ("morning routine", "coffee then a run")]
        for (k, v) in facts { store.rememberGlobal(k, value: v); clock.tick() }

        let query = "coffee"
        let semantic = store.semanticSearch(query: query, limit: SemanticMemoryStore.maxMemoryLines,
                                            namespace: "global")
        guard store.isSemanticRankingAvailable, !semantic.isEmpty else {
            throw XCTSkip("no embedder or no semantic hits on this host — the fallback path applies")
        }
        let context = store.systemPromptContext(query: query) ?? ""
        XCTAssertEqual(keys(in: context, section: "SHARED MEMORY"), semantic.map(\.keyName),
                       "semantic hits must be rendered in their ranked order, not re-sorted by recency")
    }
}
