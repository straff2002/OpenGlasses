import XCTest
@testable import OpenGlasses

/// Tests for ProcedureRunner branching, navigation, prompt context, JSONL logging, and the
/// stack-snapshot used for crash recovery.
@MainActor
final class ProcedureRunnerTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcedureRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// a --(x)--> b --> d(terminal:resolved)
    ///   --(y)--> c(terminal:escalated)
    private func makeProcedure() -> Procedure {
        Procedure(
            id: "p", title: "Test Procedure", version: "1.0.0",
            steps: [
                .init(id: "a", title: "Step A", instruction: "Observe and report.",
                      branches: [
                        .init(id: "x", condition: "looks like x", next: "b"),
                        .init(id: "y", condition: "looks like y", next: "c")
                      ],
                      defaultNext: "b"),
                .init(id: "b", title: "Step B", instruction: "Continue.", defaultNext: "d"),
                .init(id: "c", title: "Step C", instruction: "Escalate.", terminal: true, outcome: "escalated"),
                .init(id: "d", title: "Step D", instruction: "Done.", terminal: true, outcome: "resolved")
            ]
        )
    }

    private func makeLogger() -> SessionLogger {
        let session = FieldSession(
            id: UUID().uuidString, vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
            startedAt: Date(), endedAt: nil, pausedAt: nil, resumedAt: nil, outcome: .inProgress,
            startLocation: nil, endLocation: nil, escalations: [], billableSeconds: 0
        )
        return SessionLogger(session: session, root: tempRoot.appendingPathComponent(session.id, isDirectory: true))
    }

    // MARK: - Navigation

    func testStartsAtEntryStep() throws {
        let runner = try ProcedureRunner(starting: makeProcedure(), logger: makeLogger())
        XCTAssertEqual(runner.currentStepId, "a")
        XCTAssertEqual(runner.visited, ["a"])
    }

    func testAdvanceWithChoiceFollowsBranch() throws {
        let runner = try ProcedureRunner(starting: makeProcedure(), logger: makeLogger())
        guard case .moved(let step) = try runner.advance(choice: "x") else {
            return XCTFail("Expected to move to step b")
        }
        XCTAssertEqual(step.id, "b")
        XCTAssertEqual(runner.visited, ["a", "b"])
    }

    func testAdvanceWithoutChoiceFollowsDefault() throws {
        let runner = try ProcedureRunner(starting: makeProcedure(), logger: makeLogger())
        guard case .moved(let step) = try runner.advance(choice: nil) else {
            return XCTFail("Expected default_next to step b")
        }
        XCTAssertEqual(step.id, "b")
    }

    func testAdvanceIntoTerminalStepCompletes() throws {
        let runner = try ProcedureRunner(starting: makeProcedure(), logger: makeLogger())
        guard case .completed(let outcome) = try runner.advance(choice: "y") else {
            return XCTFail("Expected completion at terminal step c")
        }
        XCTAssertEqual(outcome, "escalated")
    }

    func testReachingResolvedTerminalAfterDefaultPath() throws {
        let runner = try ProcedureRunner(starting: makeProcedure(), logger: makeLogger())
        _ = try runner.advance(choice: "x") // a -> b
        guard case .completed(let outcome) = try runner.advance(choice: nil) else {
            return XCTFail("Expected completion at terminal step d")
        }
        XCTAssertEqual(outcome, "resolved")
    }

    func testGoBackPopsTheStack() throws {
        let runner = try ProcedureRunner(starting: makeProcedure(), logger: makeLogger())
        _ = try runner.advance(choice: "x") // a -> b
        let back = try runner.goBack()
        XCTAssertEqual(back.id, "a")
        XCTAssertEqual(runner.visited, ["a"])
    }

    func testGoBackAtStartThrows() throws {
        let runner = try ProcedureRunner(starting: makeProcedure(), logger: makeLogger())
        XCTAssertThrowsError(try runner.goBack()) { error in
            guard case ProcedureRunner.RunnerError.atStart = error else {
                return XCTFail("Expected .atStart, got \(error)")
            }
        }
    }

    func testRepeatDoesNotChangePosition() throws {
        let runner = try ProcedureRunner(starting: makeProcedure(), logger: makeLogger())
        let step = try runner.repeatStep()
        XCTAssertEqual(step.id, "a")
        XCTAssertEqual(runner.visited, ["a"])
    }

    // MARK: - Prompt context

    func testPromptContextListsBranchChoices() throws {
        let runner = try ProcedureRunner(starting: makeProcedure(), logger: makeLogger())
        let context = runner.promptContext()
        XCTAssertTrue(context.contains("ACTIVE PROCEDURE — Test Procedure"))
        XCTAssertTrue(context.contains("choice \"x\""))
        XCTAssertTrue(context.contains("choice \"y\""))
    }

    func testPromptContextOnTerminalStepAsksToComplete() throws {
        let runner = try ProcedureRunner(starting: makeProcedure(), logger: makeLogger())
        _ = try runner.advance(choice: "x") // -> b
        _ = try? runner.advance(choice: nil) // -> d terminal; completed, but runner still points at d
        // After completion the service clears the runner; here we assert the terminal prompt directly.
        let restored = ProcedureRunner(restoring: makeProcedure(), visited: ["d"], logger: makeLogger())
        XCTAssertTrue(restored.promptContext().contains("terminal step"))
    }

    // MARK: - Logging & recovery

    func testTransitionsAreLoggedWithStackSnapshot() throws {
        let logger = makeLogger()
        let runner = try ProcedureRunner(starting: makeProcedure(), logger: logger)
        _ = try runner.advance(choice: "x") // a -> b

        let events = logger.readEvents()
        XCTAssertTrue(events.contains { $0.kind == .procedureStarted })
        let stepEvents = events.filter { $0.kind == .procedureStep }
        XCTAssertEqual(stepEvents.count, 2) // entry (a) + advance (b)

        // The last step event carries the full visited stack — the basis for crash recovery.
        let lastStack = stepEvents.last?.payload?["stack"]?.value as? [Any]
        XCTAssertEqual(lastStack?.compactMap { $0 as? String }, ["a", "b"])
    }

    func testRestoringRunnerResumesAtRecoveredStep() {
        let restored = ProcedureRunner(restoring: makeProcedure(), visited: ["a", "b"], logger: makeLogger())
        XCTAssertEqual(restored.currentStepId, "b")
        XCTAssertEqual(restored.currentStep?.title, "Step B")
    }

    func testCompleteLogsCompletionEvent() throws {
        let logger = makeLogger()
        let runner = try ProcedureRunner(starting: makeProcedure(), logger: logger)
        _ = runner.complete(outcome: "deferred")
        let events = logger.readEvents()
        let completion = events.first { $0.kind == .procedureCompleted }
        XCTAssertNotNil(completion)
        XCTAssertEqual(completion?.payload?["outcome"]?.value as? String, "deferred")
    }
}
