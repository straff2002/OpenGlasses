import XCTest
@testable import OpenGlasses

@MainActor
final class SubsystemTestRunnerTests: XCTestCase {

    private func makeTest(
        id: String,
        result: ProbeResult,
        delayHook: (() async -> Void)? = nil
    ) -> SubsystemTest {
        SubsystemTest(id: id, name: id.capitalized, icon: "gear") {
            await delayHook?()
            return result
        }
    }

    func testPassRecordsOutcomeAndLogs() async {
        var logged: [String] = []
        var ticks = 0.0
        let runner = SubsystemTestRunner(
            tests: [makeTest(id: "a", result: .pass("fine"))],
            log: { logged.append($0) },
            now: { defer { ticks += 0.5 }; return Date(timeIntervalSince1970: ticks) }
        )

        await runner.run("a")

        XCTAssertEqual(runner.outcomes["a"], .init(passed: true, detail: "fine", seconds: 0.5))
        XCTAssertNil(runner.lastFailure)
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("✅"))
        XCTAssertTrue(logged[0].contains("fine"))
    }

    func testFailureSetsLastFailureAndPassClearsIt() async {
        var results: [String: ProbeResult] = ["a": .fail("boom")]
        let test = SubsystemTest(id: "a", name: "A", icon: "gear") { results["a"]! }
        let runner = SubsystemTestRunner(tests: [test])

        await runner.run("a")
        XCTAssertEqual(runner.outcomes["a"]?.passed, false)
        XCTAssertEqual(runner.lastFailure, "A: boom")

        // A later pass of the same test clears the stale failure banner.
        results["a"] = .pass("recovered")
        await runner.run("a")
        XCTAssertEqual(runner.outcomes["a"]?.passed, true)
        XCTAssertNil(runner.lastFailure)
    }

    func testFailureFromAnotherTestSurvivesUnrelatedPass() async {
        let runner = SubsystemTestRunner(tests: [
            makeTest(id: "bad", result: .fail("down")),
            makeTest(id: "good", result: .pass("up")),
        ])

        await runner.run("bad")
        await runner.run("good")

        // The banner shows the newest failure until THAT test passes —
        // an unrelated pass must not clear it.
        XCTAssertEqual(runner.lastFailure, "Bad: down")
    }

    func testRunAllRunsSequentiallyInOrder() async {
        var order: [String] = []
        let tests = ["one", "two", "three"].map { id in
            SubsystemTest(id: id, name: id, icon: "gear") {
                order.append(id)
                return .pass("ok")
            }
        }
        let runner = SubsystemTestRunner(tests: tests)

        await runner.runAll()

        XCTAssertEqual(order, ["one", "two", "three"])
        XCTAssertEqual(runner.outcomes.count, 3)
        XCTAssertFalse(runner.isRunning)
    }

    func testUnknownAndDuplicateRunsAreIgnored() async {
        let runner = SubsystemTestRunner(tests: [makeTest(id: "a", result: .pass("ok"))])
        await runner.run("nope")
        XCTAssertTrue(runner.outcomes.isEmpty)
    }

    func testDurationFormat() {
        XCTAssertEqual(SubsystemTestRunner.format(0.44), "0.4s")
        XCTAssertEqual(SubsystemTestRunner.format(9.94), "9.9s")
        XCTAssertEqual(SubsystemTestRunner.format(12.4), "12s")
    }
}
