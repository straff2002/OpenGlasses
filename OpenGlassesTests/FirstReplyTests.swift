import XCTest
@testable import OpenGlasses

/// How long a request may go unanswered, and the race that enforces it.
final class FirstReplyPolicyTests: XCTestCase {

    private func limits(enabled: Bool = true, bytes: Int = 1_000, thinks: Bool = false,
                        next: Bool = true, toolsRan: Bool = false) -> FirstReplyLimits {
        FirstReplyPolicy.limits(enabled: enabled, bodyBytes: bytes, thinksAtLength: thinks,
                                hasNextCandidate: next, toolsAlreadyRan: toolsRan)
    }

    func testOffMeansNoLimitsAtAll() {
        XCTAssertEqual(limits(enabled: false), .none)
    }

    func testAPlainTurnGetsBoth() {
        XCTAssertEqual(limits(), FirstReplyLimits(hedgeAfter: 6, giveUpAfter: 12))
    }

    func testWithNoModelLeftTheTimeoutStands() {
        XCTAssertNil(limits(next: false).giveUpAfter)
        XCTAssertEqual(limits(next: false).hedgeAfter, 6, "asking again is still worth it")
    }

    func testAfterToolsRanAHopWouldRunThemAgain() {
        XCTAssertNil(limits(toolsRan: true).giveUpAfter)
        XCTAssertEqual(limits(toolsRan: true).hedgeAfter, 6, "the same request runs nothing twice")
    }

    func testALargeBodyIsNotUploadedTwice() {
        let large = limits(bytes: FirstReplyPolicy.largeBodyBytes + 1)
        XCTAssertNil(large.hedgeAfter)
        XCTAssertEqual(large.giveUpAfter, 24, "and it may simply be slow")
        XCTAssertNotNil(limits(bytes: FirstReplyPolicy.largeBodyBytes).hedgeAfter)
    }

    func testAThinkingTurnGetsLonger() {
        XCTAssertEqual(limits(thinks: true), FirstReplyLimits(hedgeAfter: 12, giveUpAfter: 24))
    }

    func testWhatCountsAsThinkingAtLength() {
        XCTAssertTrue(FirstReplyPolicy.thinksAtLength(.geminiThinkingLevel(.medium)))
        XCTAssertTrue(FirstReplyPolicy.thinksAtLength(.geminiThinkingLevel(.high)))
        XCTAssertFalse(FirstReplyPolicy.thinksAtLength(.geminiThinkingLevel(.low)))
        XCTAssertFalse(FirstReplyPolicy.thinksAtLength(.geminiThinkingLevel(.minimal)))
        XCTAssertTrue(FirstReplyPolicy.thinksAtLength(.geminiThinkingBudget(8_192)))
        XCTAssertFalse(FirstReplyPolicy.thinksAtLength(.geminiThinkingBudget(1_024)))
        XCTAssertFalse(FirstReplyPolicy.thinksAtLength(.omit))
    }

    func testTheCascadeHopsOnASlowResponseAndTheHandoffIgnoresIt() {
        let slow = LLMError.slowResponse(provider: "Gemini")
        XCTAssertEqual(ModelFallbackChain.classify(slow), .retryOtherModel)
        XCTAssertTrue(LLMError.isSlowResponse(slow))
        XCTAssertFalse(LLMError.isSlowResponse(URLError(.timedOut)))
        XCTAssertFalse(ConnectivityFailure.isConnectivityFailure(slow))
    }

    func testASlowResponseDoesNotCountAsANetworkFailure() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/LLMService.swift"))
        let range = try XCTUnwrap(source.range(of: "LLMError.isSlowResponse(error) {"))
        XCTAssertTrue(source[range.upperBound...].prefix(300).contains("} else if isCloud {"))
    }
}

/// A hand-driven clock and hand-driven requests, so each case decides exactly what finishes first.
private actor RaceScript {
    private var sleepers: [(seconds: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = []
    private var requests: [Int: CheckedContinuation<String, Error>] = [:]
    private(set) var started: [Int] = []
    private(set) var cancelled: Set<Int> = []

    func sleep(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { sleepers.append((seconds, $0)) }
    }

    func fire(_ seconds: TimeInterval) {
        guard let index = sleepers.firstIndex(where: { $0.seconds == seconds }) else { return }
        sleepers.remove(at: index).continuation.resume()
    }

    func releaseTimers() {
        sleepers.forEach { $0.continuation.resume(throwing: CancellationError()) }
        sleepers = []
    }

    func request(_ index: Int) async throws -> String {
        started.append(index)
        return try await withCheckedThrowingContinuation { requests[index] = $0 }
    }

    func answer(_ index: Int, _ value: String) { requests.removeValue(forKey: index)?.resume(returning: value) }
    func fail(_ index: Int, _ error: Error) { requests.removeValue(forKey: index)?.resume(throwing: error) }
    func cancel(_ index: Int) {
        cancelled.insert(index)
        requests.removeValue(forKey: index)?.resume(throwing: CancellationError())
    }
    func cancelEverything() {
        for index in Array(requests.keys) { cancel(index) }
        releaseTimers()
    }

    var sleeperCount: Int { sleepers.count }
    var pending: Set<Int> { Set(requests.keys) }
}

final class FirstResponseRaceTests: XCTestCase {

    private let limits = FirstReplyLimits(hedgeAfter: 6, giveUpAfter: 12)

    private func race(_ script: RaceScript, limits: FirstReplyLimits,
                      hedges: HedgeCount = HedgeCount()) -> Task<String, Error> {
        Task {
            try await withTaskCancellationHandler {
                try await FirstResponseRace.run(
                    limits: limits, provider: "Gemini",
                    sleep: { try await script.sleep($0) },
                    onHedge: { hedges.add() },
                    attempt: { index in
                        try await withTaskCancellationHandler {
                            try await script.request(index)
                        } onCancel: { Task { await script.cancel(index) } }
                    })
            } onCancel: { Task { await script.cancelEverything() } }
        }
    }

    private func waitFor(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting")
    }

    /// Lets the group settle: a losing timer is not cancellable from the script's side otherwise.
    private func finish(_ script: RaceScript, _ task: Task<String, Error>) async -> Result<String, Error> {
        Task { try await Task.sleep(nanoseconds: 50_000_000); await script.releaseTimers() }
        return await task.result
    }

    func testNoLimitsIsJustTheRequest() async throws {
        let value = try await FirstResponseRace.run(limits: .none, provider: "Gemini") { index in "answer \(index)" }
        XCTAssertEqual(value, "answer 0")
    }

    func testAFastAnswerSendsNothingElse() async throws {
        let script = RaceScript()
        let hedges = HedgeCount()
        let task = race(script, limits: limits, hedges: hedges)
        try await waitFor { await script.pending == [0] }
        await script.answer(0, "first")
        let result = await finish(script, task)
        XCTAssertEqual(try result.get(), "first")
        let started = await script.started
        XCTAssertEqual(started, [0])
        XCTAssertEqual(hedges.value, 0)
    }

    func testTheSecondRequestCanWinAndTheFirstIsCancelled() async throws {
        let script = RaceScript()
        let hedges = HedgeCount()
        let task = race(script, limits: limits, hedges: hedges)
        try await waitFor { await script.sleeperCount == 2 }
        await script.fire(6)
        try await waitFor { await script.pending == [0, 1] }
        XCTAssertEqual(hedges.value, 1)
        await script.answer(1, "second")
        let result = await finish(script, task)
        XCTAssertEqual(try result.get(), "second")
        let cancelled = await script.cancelled
        XCTAssertEqual(cancelled, [0], "the loser does not keep running")
    }

    func testTheFirstCanStillWinAfterTheHedge() async throws {
        let script = RaceScript()
        let task = race(script, limits: limits)
        try await waitFor { await script.sleeperCount == 2 }
        await script.fire(6)
        try await waitFor { await script.pending == [0, 1] }
        await script.answer(0, "first")
        let result = await finish(script, task)
        XCTAssertEqual(try result.get(), "first")
        let cancelled = await script.cancelled
        XCTAssertEqual(cancelled, [1])
    }

    func testAnErrorWaitsForTheRequestStillRunning() async throws {
        let script = RaceScript()
        let task = race(script, limits: limits)
        try await waitFor { await script.sleeperCount == 2 }
        await script.fire(6)
        try await waitFor { await script.pending == [0, 1] }
        await script.fail(0, URLError(.networkConnectionLost))
        await script.answer(1, "second")
        let result = await finish(script, task)
        XCTAssertEqual(try result.get(), "second")
    }

    func testAnErrorWithNothingElseRunningIsThrownAtOnce() async throws {
        let script = RaceScript()
        let task = race(script, limits: limits)
        try await waitFor { await script.pending == [0] }
        await script.fail(0, URLError(.networkConnectionLost))
        let result = await finish(script, task)
        XCTAssertThrowsError(try result.get()) {
            XCTAssertEqual(($0 as? URLError)?.code, .networkConnectionLost)
        }
        let started = await script.started
        XCTAssertEqual(started, [0], "a real error is the cascade's to handle")
    }

    func testBothFailingThrows() async throws {
        let script = RaceScript()
        let task = race(script, limits: limits)
        try await waitFor { await script.sleeperCount == 2 }
        await script.fire(6)
        try await waitFor { await script.pending == [0, 1] }
        await script.fail(0, URLError(.timedOut))
        await script.fail(1, URLError(.cannotConnectToHost))
        let result = await finish(script, task)
        XCTAssertThrowsError(try result.get())
    }

    func testTheDeadlineGivesUpAndCancelsEverything() async throws {
        let script = RaceScript()
        let task = race(script, limits: limits)
        try await waitFor { await script.sleeperCount == 2 }
        await script.fire(6)
        try await waitFor { await script.pending == [0, 1] }
        await script.fire(12)
        let result = await finish(script, task)
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue(LLMError.isSlowResponse($0)) }
        let cancelled = await script.cancelled
        XCTAssertEqual(cancelled, [0, 1])
    }

    func testNoDeadlineMeansItKeepsWaiting() async throws {
        let script = RaceScript()
        let task = race(script, limits: FirstReplyLimits(hedgeAfter: 6, giveUpAfter: nil))
        try await waitFor { await script.sleeperCount == 1 }
        await script.fire(6)
        try await waitFor { await script.pending == [0, 1] }
        await script.answer(0, "late")
        let result = await task.result
        XCTAssertEqual(try result.get(), "late")
    }

    func testBargeInCancelsBothRequests() async throws {
        let script = RaceScript()
        let task = race(script, limits: limits)
        try await waitFor { await script.sleeperCount == 2 }
        await script.fire(6)
        try await waitFor { await script.pending == [0, 1] }
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get())
        let cancelled = await script.cancelled
        XCTAssertEqual(cancelled, [0, 1])
    }
}

private final class HedgeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
