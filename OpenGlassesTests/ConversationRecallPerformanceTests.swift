import XCTest
@testable import OpenGlasses

/// Opt-in DK P3 device harness. Run once for each representative corpus size:
/// Set `DK_RECALL_BENCHMARK` and `DK_RECALL_BENCHMARK_TURNS` in the test scheme or simulator
/// launch environment, then run this test for 1000, 10000, and 50000 turns.
/// The harness reports wall-clock and retained physical-memory delta without logging conversation
/// text. Run it on the oldest supported phone for the release record; simulator numbers are only a
/// regression smoke signal.
final class ConversationRecallPerformanceTests: XCTestCase {
    func testInMemoryRecallRebuild() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["DK_RECALL_BENCHMARK"] == "1",
                          "Set DK_RECALL_BENCHMARK=1 to run the device performance gate")

        let turnCount = Int(environment["DK_RECALL_BENCHMARK_TURNS"] ?? "1000") ?? 0
        try XCTSkipUnless([1_000, 10_000, 50_000].contains(turnCount),
                          "DK_RECALL_BENCHMARK_TURNS must be 1000, 10000, or 50000")
        let turns = (0..<turnCount).map { index in
            IndexedTurn(
                id: "message-\(index)",
                threadID: "thread-\(index / 20)",
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                text: "Synthetic private recall turn \(index) with stable benchmark tokens",
                timestamp: Date(timeIntervalSinceReferenceDate: TimeInterval(index))
            )
        }
        let footprintBefore = MemoryHeadroom.appFootprintBytes()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let index = ConversationIndex.inMemory()
        XCTAssertTrue(index.indexAll(turns))
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        let footprintAfter = MemoryHeadroom.appFootprintBytes()
        XCTAssertEqual(index.count(), turnCount)

        let retainedMiB = Double(max(0, footprintAfter - footprintBefore)) / 1_048_576
        print("[DK-P3] rebuild \(turnCount) turns: "
              + "\(String(format: "%.3f", elapsed)) s, "
              + "\(String(format: "%.1f", retainedMiB)) MiB retained footprint")
    }
}
