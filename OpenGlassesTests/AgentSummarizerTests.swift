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

    /// Plan FE P0 — the old assertion here WAS the bug: a result the harness never filled in was
    /// narrated as "no file changes", which is a claim about the run rather than the absence of
    /// information. Nothing reported now says exactly that.
    func testEmptyUnreportedResultSaysItDoesNotKnow() {
        XCTAssertEqual(AgentSummarizer.summarize(AgentRunResult(), status: .completed),
                       "The agent finished; it didn't report what changed.")
    }

    /// …and "no file changes" survives for the case it was always true of: the harness reported
    /// both file lists and both were empty.
    func testExplicitlyReportedEmptyListsStillSayNoFileChanges() {
        var result = AgentRunResult()
        result.reported = [.filesCreated, .filesModified]
        XCTAssertEqual(AgentSummarizer.summarize(result, status: .completed),
                       "The agent finished with no file changes. Done.")
        XCTAssertTrue(result.reportedNoFileChanges)
    }

    func testRemoteCancellationIsNotSpokenAsCompletion() {
        XCTAssertEqual(AgentSummarizer.summarize(AgentRunResult(), status: .cancelled),
                       "The agent run was cancelled before it finished.")
        XCTAssertEqual(AgentSummarizer.summarize(AgentRunResult(filesModified: ["a"]), status: .cancelled),
                       "The agent run was cancelled. Before it stopped it modified one file.")
        // Our own cancellation still speaks in the first person.
        XCTAssertEqual(AgentSummarizer.summarize(AgentRunResult(), status: .cancelled, cancellation: .local),
                       "Cancelled the agent run.")
    }

    func testContactLinesBlameTheEndpointNeverTheRun() {
        let network = AgentSummarizer.line(for: .network(attempts: 5))
        XCTAssertTrue(network.contains("lost contact"))
        XCTAssertTrue(network.contains("may still be running"))
        XCTAssertFalse(network.lowercased().contains("failed"))
        XCTAssertFalse(network.lowercased().contains("cancel"))

        XCTAssertTrue(AgentSummarizer.line(for: .auth(status: 401)).contains("rejected my credentials"))
        XCTAssertTrue(AgentSummarizer.line(for: .unknownStatus("frobnicating")).contains("frobnicating"))
        XCTAssertFalse(AgentSummarizer.line(for: .unknownStatus("")).contains(":"))
        XCTAssertTrue(AgentSummarizer.line(for: .noStatusEndpoint).contains("no status address"))

        // A hostile status label cannot smuggle a novel into a spoken line.
        let long = AgentSummarizer.line(for: .unknownStatus(String(repeating: "x", count: 4000)))
        XCTAssertLessThanOrEqual(long.count, AgentSummarizer.maxLength)
    }

    func testStatusLineAfterContactLostReportsTimeAndLastKnownState() {
        XCTAssertEqual(
            AgentSummarizer.statusLine(afterContactLost: .network(attempts: 3), at: "3:42 PM", lastKnown: .running),
            "I lost contact with the agent endpoint at 3:42 PM, so I stopped checking. The last I knew, the agent was working.")
        XCTAssertTrue(
            AgentSummarizer.statusLine(afterContactLost: .auth(status: 401), at: "3:42 PM", lastKnown: .awaitingInput)
                .contains("waiting for your confirmation"))
    }

    func testFailedAndCancelled() {
        XCTAssertEqual(AgentSummarizer.summarize(AgentRunResult(error: "build broke"), status: .failed),
                       "The agent run failed: build broke.")
        // Plan FE P0: the *default* origin is now remote, because that is what a terminal
        // `cancelled` from a harness means. Our own cancel passes `.local` and keeps its wording.
        XCTAssertEqual(AgentSummarizer.summarize(AgentRunResult(), status: .cancelled, cancellation: .local),
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
        // Plan FE P1: a question is narrated by the session, once per question identity — not by
        // the generic narrator, which would re-announce every polled repeat.
        XCTAssertNil(AgentSummarizer.narration(for: .awaitingInput(
            AgentQuestion(id: "q1", revision: 0, kind: .approval(actionSummary: "Push to main?"),
                          prompt: "Push to main?", runID: "r1"))))
        XCTAssertEqual(AgentSummarizer.narration(for: .error("boom")), "The agent hit an error: boom.")
    }

    func testNarrationSuppressesTerminalAndConnectionEvents() {
        // The session speaks one final line and one contact line; narrating them here as well
        // would say everything twice.
        XCTAssertNil(AgentSummarizer.narration(for: .failed(AgentRunResult())))
        XCTAssertNil(AgentSummarizer.narration(for: .cancelled(AgentRunResult())))
        XCTAssertNil(AgentSummarizer.narration(for: .connection(.reconnecting(attempt: 1, nextRetryIn: 2))))
        XCTAssertNil(AgentSummarizer.narration(for: .connection(.lost(.network(attempts: 3)))))
    }

    func testNarrationSuppressesNoisyEvents() {
        XCTAssertNil(AgentSummarizer.narration(for: .fileCreated("a")))
        XCTAssertNil(AgentSummarizer.narration(for: .fileModified("b")))
        XCTAssertNil(AgentSummarizer.narration(for: .commandRun(command: "swift test", ok: true)))
        XCTAssertNil(AgentSummarizer.narration(for: .assistantText("hi")))
        XCTAssertNil(AgentSummarizer.narration(for: .progress("   ")))
    }
}
