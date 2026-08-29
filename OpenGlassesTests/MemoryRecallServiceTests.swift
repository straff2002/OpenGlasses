import XCTest
@testable import OpenGlasses

/// Headless tests for Memory & Recall Phase 2 — `RecallService` (search + summarize + cite).
/// The summarizer is injected (the real one calls the user's LLM), and the index is a temp
/// FTS DB, so the search→answer flow runs with no model and no hardware.
@MainActor
final class MemoryRecallServiceTests: XCTestCase {

    private func populatedCoordinator() async -> ConversationRecallCoordinator {
        let coordinator = ConversationRecallCoordinator()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        coordinator.start(threads: [], isLocked: false, legacyDirectory: dir)
        await waitUntilReady(coordinator)
        let turns = [
            IndexedTurn(id: "1", threadID: "t1", role: "user",
                        text: "Let's go with the coral accent for the AI elements", timestamp: Date()),
            IndexedTurn(id: "2", threadID: "t1", role: "assistant",
                        text: "Got it — coral it is, never cyan", timestamp: Date()),
            IndexedTurn(id: "3", threadID: "t2", role: "user",
                        text: "Remind me to water the plants", timestamp: Date()),
        ]
        for turn in turns {
            coordinator.apply(.messageUpsert(turn), persistedSnapshot: [])
        }
        return coordinator
    }

    private func waitUntilReady(_ coordinator: ConversationRecallCoordinator) async {
        for _ in 0..<200 {
            if case .ready = coordinator.state { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Recall coordinator did not become ready")
    }

    func testRecallReturnsCitedAnswer() async {
        let service = RecallService()
        service.configure(coordinator: await populatedCoordinator()) { question, hits in
            "Answered '\(question)' from \(hits.count) excerpts"
        }
        let answer = await service.recall("what accent color did we choose")
        XCTAssertFalse(answer.isEmpty)
        XCTAssertTrue(answer.citations.contains { $0.id == "1" })
        XCTAssertFalse(answer.citations.contains { $0.id == "3" })   // unrelated turn excluded
        XCTAssertTrue(answer.summary.hasPrefix("Answered"))
    }

    func testRecallEmptyWhenNoMatch() async {
        let service = RecallService()
        service.configure(coordinator: await populatedCoordinator()) { _, _ in "should not be called" }
        let answer = await service.recall("quarterly tax filing deadline")
        XCTAssertTrue(answer.isEmpty)
        XCTAssertTrue(answer.summary.lowercased().contains("couldn't find"))
    }

    func testSearchDelegatesToCoordinator() async {
        let service = RecallService()
        service.configure(coordinator: await populatedCoordinator()) { _, _ in "" }
        guard case .ready(let hits, _) = service.search("plants") else {
            return XCTFail("Expected ready recall search")
        }
        XCTAssertTrue(hits.contains { $0.id == "3" })
    }

    func testUnconfiguredServiceIsSafe() async {
        let service = RecallService()
        XCTAssertFalse(service.isConfigured)
        XCTAssertEqual(service.search("anything"), .unavailable)
        let answer = await service.recall("anything")
        XCTAssertTrue(answer.isEmpty)
    }

    func testSummarizationPromptCitesExcerpts() {
        let hits = [
            RecallHit(id: "1", threadID: "t", role: "user", text: "ship Friday",
                      timestamp: Date(timeIntervalSinceReferenceDate: 0), snippet: "ship Friday", rank: -1),
        ]
        let p = RecallService.summarizationPrompt(question: "when do we ship?", hits: hits)
        XCTAssertTrue(p.user.contains("when do we ship?"))
        XCTAssertTrue(p.user.contains("[1]"))
        XCTAssertTrue(p.user.contains("ship Friday"))
        XCTAssertTrue(p.system.lowercased().contains("only"))   // answer strictly from excerpts
    }

    func testFallbackSummaryBulletsHits() {
        let hits = (1...3).map {
            RecallHit(id: "\($0)", threadID: "t", role: "user", text: "line \($0)",
                      timestamp: Date(), snippet: "line \($0)", rank: 0)
        }
        let summary = RecallService.fallbackSummary(hits)
        XCTAssertTrue(summary.contains("• line 1"))
        XCTAssertEqual(summary.components(separatedBy: "\n").count, 3)
    }
}
