import XCTest
@testable import OpenGlasses

/// Tests for the harness-agnostic agent summarizer + result aggregation (Plan N) — the highest-value
/// pure unit: event lists → spoken English, identical for every adapter.
final class AgentSummarizerTests: XCTestCase {

    // MARK: - AgentRunResult aggregation

    func testReduceTalliesAndDedupesFiles() {
        let result = AgentRunResult.reduce([
            .fileCreated("a.swift"),
            .fileModified("b.swift"),
            .fileModified("b.swift"),          // dup ignored
            .commandRun(command: "swift test", ok: true),
            .prOpened(url: "https://x/pr/1"),
            .pushed,
            .assistantText("All set."),
        ])
        XCTAssertEqual(result.filesCreated, ["a.swift"])
        XCTAssertEqual(result.filesModified, ["b.swift"])
        XCTAssertEqual(result.commandsRun, ["swift test"])
        XCTAssertEqual(result.prURL, "https://x/pr/1")
        XCTAssertTrue(result.pushed)
        XCTAssertEqual(result.finalText, "All set.")
    }

    func testCompletedEventSupersedesRunningTally() {
        var result = AgentRunResult()
        result.apply(.fileCreated("draft.swift"))
        result.apply(.completed(AgentRunResult(filesModified: ["final.swift"])))
        XCTAssertTrue(result.filesCreated.isEmpty)
        XCTAssertEqual(result.filesModified, ["final.swift"])
    }

    // MARK: - summarize

    func testSummarizesAFullRunWithDoneTerminator() {
        let result = AgentRunResult(filesCreated: ["a", "b"], filesModified: ["c"],
                                    commandsRun: ["swift test"], prURL: "https://x", pushed: true)
        let line = AgentSummarizer.summarize(result, status: .completed)
        XCTAssertEqual(line,
            "The agent created two files, modified one file, ran one command, pushed the changes, and opened a pull request. Done.")
    }

    func testSingularVsPluralCounts() {
        XCTAssertEqual(AgentSummarizer.summarize(AgentRunResult(filesCreated: ["x"]), status: .completed),
                       "The agent created one file. Done.")
        XCTAssertEqual(AgentSummarizer.summarize(AgentRunResult(filesCreated: ["x", "y", "z"]), status: .completed),
                       "The agent created three files. Done.")
    }

    func testEmptyResultFallsBackToFinalText() {
        let line = AgentSummarizer.summarize(AgentRunResult(finalText: "Nothing needed changing"), status: .completed)
        XCTAssertEqual(line, "Nothing needed changing. Done.")
    }

    func testEmptyResultNoTextDefault() {
        XCTAssertEqual(AgentSummarizer.summarize(AgentRunResult(), status: .completed),
                       "The agent finished with no file changes. Done.")
    }

    func testFailedAndCancelled() {
        XCTAssertEqual(AgentSummarizer.summarize(AgentRunResult(error: "build broke"), status: .failed),
                       "The agent run failed: build broke.")
        XCTAssertEqual(AgentSummarizer.summarize(AgentRunResult(), status: .cancelled),
                       "Cancelled the agent run.")
    }

    func testErrorInResultForcesFailureLineEvenIfStatusCompleted() {
        XCTAssertEqual(AgentSummarizer.summarize(AgentRunResult(error: "oops"), status: .completed),
                       "The agent run failed: oops.")
    }

    func testCapsAt320Characters() {
        let manyFiles = (0..<200).map { "file\($0).swift" }
        let line = AgentSummarizer.summarize(AgentRunResult(filesModified: manyFiles), status: .completed)
        XCTAssertLessThanOrEqual(line.count, AgentSummarizer.maxLength)
    }

    // MARK: - Helpers

    func testCountPhrase() {
        XCTAssertEqual(AgentSummarizer.countPhrase(1, "file"), "one file")
        XCTAssertEqual(AgentSummarizer.countPhrase(2, "command"), "two commands")
        XCTAssertEqual(AgentSummarizer.countPhrase(42, "file"), "42 files")
    }

    func testJoinClauses() {
        XCTAssertEqual(AgentSummarizer.joinClauses(["a"]), "a")
        XCTAssertEqual(AgentSummarizer.joinClauses(["a", "b"]), "a and b")
        XCTAssertEqual(AgentSummarizer.joinClauses(["a", "b", "c"]), "a, b, and c")
    }

    // MARK: - narration(for:)

    func testNarrationForKeyEvents() {
        XCTAssertEqual(AgentSummarizer.narration(for: .prOpened(url: "x")), "Opened a pull request.")
        XCTAssertEqual(AgentSummarizer.narration(for: .pushed), "Pushed the changes.")
        XCTAssertEqual(AgentSummarizer.narration(for: .progress("Running tests")), "Running tests")
        XCTAssertEqual(AgentSummarizer.narration(for: .commandRun(command: "rm -rf x", ok: false)),
                       "A command failed: rm -rf x.")
        XCTAssertEqual(AgentSummarizer.narration(for: .awaitingInput(prompt: "Push to main?")), "Push to main?")
        XCTAssertEqual(AgentSummarizer.narration(for: .error("boom")), "The agent hit an error: boom.")
    }

    func testNarrationSuppressesNoisyEvents() {
        XCTAssertNil(AgentSummarizer.narration(for: .fileCreated("a")))
        XCTAssertNil(AgentSummarizer.narration(for: .fileModified("b")))
        XCTAssertNil(AgentSummarizer.narration(for: .commandRun(command: "swift test", ok: true)))
        XCTAssertNil(AgentSummarizer.narration(for: .assistantText("hi")))
        XCTAssertNil(AgentSummarizer.narration(for: .progress("   ")))
    }
}
