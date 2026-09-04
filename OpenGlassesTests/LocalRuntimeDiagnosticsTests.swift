import XCTest
@testable import OpenGlasses

/// Plan DZ P2 — the diagnostics card.
///
/// The card's whole claim is that its numbers *are* the ones the runtime recorded. So what is
/// tested is the derivation (tokens per second, which is the only figure the card computes) and the
/// row set — including the honest empty state, and the rule that keeps a no-op reload from wiping
/// the timings of the turn before it.
final class LocalRuntimeDiagnosticsTests: XCTestCase {

    // MARK: - Derived rate

    func testTokensPerSecondMeasuresDecodeAndExcludesPrefill() {
        // 41 tokens, first at 500 ms, finished at 2500 ms: 40 tokens produced across 2 seconds.
        let sample = generation(generatedTokens: 41, firstTokenMilliseconds: 500,
                                totalMilliseconds: 2500)
        XCTAssertEqual(sample.tokensPerSecond ?? 0, 20, accuracy: 0.001)
    }

    func testTokensPerSecondIsUnreportedWhenThereIsNothingToDivide() {
        XCTAssertNil(generation(generatedTokens: 0, firstTokenMilliseconds: nil,
                                totalMilliseconds: 900).tokensPerSecond)
        XCTAssertNil(generation(generatedTokens: 1, firstTokenMilliseconds: 100,
                                totalMilliseconds: 900).tokensPerSecond,
                     "one token is the token produced at first-token time, not a rate")
        XCTAssertNil(generation(generatedTokens: 40, firstTokenMilliseconds: 500,
                                totalMilliseconds: 540).tokensPerSecond,
                     "a 40 ms window measures the clock, not the model")
        XCTAssertNil(load().tokensPerSecond, "a load produces no tokens")
    }

    // MARK: - Card rows

    func testTheCardCoversEveryFieldThePlanNames() {
        let required = ["framework", "modelRevision", "context", "firstToken", "rate", "memory",
                        "thermal"]
        let rows = LocalRuntimeDiagnosticsCard.rows(sample: generation(),
                                                     frameworkDescription: "llama.cpp v0.3.0 (abc)")
        let ids = Set(rows.map(\.id))
        let missing = required.filter { !ids.contains($0) }
        XCTAssertTrue(missing.isEmpty, "missing rows: \(missing)")
        for row in rows { XCTAssertFalse(row.spokenLabel.isEmpty) }
    }

    func testWithNoRunRecordedTheCardSaysSoRatherThanShowingZeroes() {
        let rows = LocalRuntimeDiagnosticsCard.rows(sample: nil,
                                                     frameworkDescription: "llama.cpp (unknown)")
        XCTAssertEqual(rows.map(\.id), ["framework", "empty"])
        XCTAssertFalse(rows.contains { $0.value.contains("0 ms") })
    }

    func testAnUnpinnedModelRevisionIsSaidToBeUnpinnedNotShownAsAHash() {
        let sample = generation(modelRevision: LocalModelDescriptor.floatingRevision)
        let row = LocalRuntimeDiagnosticsCard.rows(sample: sample, frameworkDescription: "x")
            .first { $0.id == "modelRevision" }
        XCTAssertEqual(row?.value, "Not pinned")
    }

    func testTheMemoryDeltaIsSignedAndSpokenInWords() {
        let lost = LocalRuntimeDiagnosticsCard.rows(sample: generation(headroomDelta: -200_000_000),
                                                     frameworkDescription: "x")
            .first { $0.id == "memory" }
        XCTAssertTrue(lost?.value.hasPrefix("−") ?? false, lost?.value ?? "")
        XCTAssertTrue(lost?.spokenValue?.contains("less free") ?? false)

        let unchanged = LocalRuntimeDiagnosticsCard.rows(sample: generation(headroomDelta: 0),
                                                         frameworkDescription: "x")
            .first { $0.id == "memory" }
        XCTAssertEqual(unchanged?.value, "unchanged")
    }

    func testALoadSampleReportsLoadTimeRatherThanAFabricatedFirstToken() {
        let rows = LocalRuntimeDiagnosticsCard.rows(sample: load(), frameworkDescription: "x")
        XCTAssertTrue(rows.contains { $0.id == "loadTime" })
        XCTAssertFalse(rows.contains { $0.id == "firstToken" })
    }

    // MARK: - Store

    func testTheStoreKeepsTheLatestSamplePerRuntime() {
        let store = LocalRuntimeDiagnostics()
        store.record(generation(recordedAt: Date(timeIntervalSince1970: 10)))
        store.record(generation(generatedTokens: 99, recordedAt: Date(timeIntervalSince1970: 20)))
        XCTAssertEqual(store.latest(for: .llamaCpp)?.generatedTokens, 99)
        XCTAssertNil(store.latest(for: .mlx))
        XCTAssertEqual(store.latest?.generatedTokens, 99)
    }

    func testALoadOfTheAlreadyMeasuredModelDoesNotWipeItsTimings() {
        // Re-loading a resident model is a no-op; letting its load sample replace the generation
        // sample would blank the card between turns.
        let store = LocalRuntimeDiagnostics()
        store.record(generation(generatedTokens: 42))
        store.record(load())
        XCTAssertEqual(store.latest(for: .llamaCpp)?.generatedTokens, 42)

        // A *different* model's load is real news and does replace it.
        store.record(load(modelID: LocalModelID("other/model")))
        XCTAssertEqual(store.latest(for: .llamaCpp)?.kind, .load)
    }

    // MARK: - Helpers

    private func generation(modelID: LocalModelID = LocalModelID("owner/repo#m.gguf"),
                            modelRevision: String = String(repeating: "b", count: 40),
                            generatedTokens: Int = 41,
                            firstTokenMilliseconds: Int? = 500,
                            totalMilliseconds: Int = 2500,
                            headroomDelta: Int64 = -100_000_000,
                            recordedAt: Date = Date(timeIntervalSince1970: 0))
        -> LocalRuntimeDiagnosticsSample {
        LocalRuntimeDiagnosticsSample(
            kind: .generation, modelID: modelID, runtime: .llamaCpp, modelRevision: modelRevision,
            contextTokens: 4096, promptTokens: 120, generatedTokens: generatedTokens,
            firstTokenMilliseconds: firstTokenMilliseconds, totalMilliseconds: totalMilliseconds,
            headroomDeltaBytes: headroomDelta, footprintBytes: 900_000_000,
            thermalState: .fair, recordedAt: recordedAt)
    }

    private func load(modelID: LocalModelID = LocalModelID("owner/repo#m.gguf"))
        -> LocalRuntimeDiagnosticsSample {
        LocalRuntimeDiagnosticsSample(
            kind: .load, modelID: modelID, runtime: .llamaCpp,
            modelRevision: String(repeating: "b", count: 40),
            contextTokens: 4096, promptTokens: 0, generatedTokens: 0,
            firstTokenMilliseconds: nil, totalMilliseconds: 1800,
            headroomDeltaBytes: 0, footprintBytes: 900_000_000,
            thermalState: .nominal, recordedAt: Date(timeIntervalSince1970: 30))
    }
}
