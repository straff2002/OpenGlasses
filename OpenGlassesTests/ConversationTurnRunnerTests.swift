import XCTest
@testable import OpenGlasses

/// Plan BG P2 — the execution skeleton of one LLM turn. These are the main state machine's first
/// regression tests: stage ordering (send → post-process → accept → speak → finish), error mid-flow
/// still reaching `finish` (the July 2026 audit's stuck-listening scenario), and a cancelled turn
/// never speaking its stale reply.
@MainActor
final class ConversationTurnRunnerTests: XCTestCase {

    private struct TestError: Error {}

    /// Builds Deps where every stage appends to `log`, with per-stage overrides.
    private func recordingDeps(
        into log: Box<[String]>,
        send: (@MainActor () async throws -> String)? = nil,
        postProcess: (@MainActor (String) async -> String)? = nil,
        accept: (@MainActor (String) async -> Void)? = nil
    ) -> ConversationTurnRunner.Deps {
        ConversationTurnRunner.Deps(
            send: {
                log.value.append("send")
                guard let send else { return "raw" }
                return try await send()
            },
            postProcess: { raw in
                log.value.append("postProcess(\(raw))")
                guard let postProcess else { return raw }
                return await postProcess(raw)
            },
            accept: {
                log.value.append("accept(\($0))")
                if let accept { await accept($0) }
            },
            speak: { log.value.append("speak(\($0))") },
            onCancelled: { log.value.append("onCancelled") },
            onError: { log.value.append("onError(\(type(of: $0)))") },
            finish: { log.value.append("finish") }
        )
    }

    func testHappyPathRunsStagesInOrder() async {
        let log = Box<[String]>([])
        await ConversationTurnRunner.run(recordingDeps(into: log))
        XCTAssertEqual(log.value, ["send", "postProcess(raw)", "accept(raw)", "speak(raw)", "finish"])
    }

    func testPostProcessedResponseIsWhatGetsAcceptedAndSpoken() async {
        let log = Box<[String]>([])
        let deps = recordingDeps(into: log, postProcess: { _ in "cooked" })
        await ConversationTurnRunner.run(deps)
        XCTAssertEqual(log.value, ["send", "postProcess(raw)", "accept(cooked)", "speak(cooked)", "finish"])
    }

    /// The audit's stuck-listening scenario: an error mid-flow must not strand the app in the
    /// processing state — `finish` (which resumes listening / returns to wake word) always runs.
    func testSendErrorSkipsAcceptAndSpeakButStillFinishes() async {
        let log = Box<[String]>([])
        let deps = recordingDeps(into: log, send: { throw TestError() })
        await ConversationTurnRunner.run(deps)
        XCTAssertEqual(log.value, ["send", "onError(TestError)", "finish"])
    }

    /// Barge-in / stop cancel the tracked turn task; a stale response must not run
    /// post-processing side effects (memory persistence), be accepted, or be spoken — but must
    /// still finish.
    func testCancellationDuringSendNeverSpeaksStaleReplyButStillFinishes() async {
        let log = Box<[String]>([])
        // Cancel the surrounding task from inside `send`, as a barge-in would while the LLM call
        // is in flight. `send` still returns a (now-stale) response.
        let deps = recordingDeps(into: log, send: {
            withUnsafeCurrentTask { $0?.cancel() }
            return "stale"
        })
        // Run inside a child task (mirroring `currentLLMTask`) so the cancellation stays scoped
        // to the turn, not the test's own task.
        await Task { await ConversationTurnRunner.run(deps) }.value
        XCTAssertEqual(log.value, ["send", "onCancelled", "finish"])
    }

    /// A `send` that surfaces cancellation by throwing (e.g. a cancelled URLSession call) is
    /// reported as a cancellation, not an error — no apology is spoken for a user interruption.
    func testCancellationErrorFromSendReportsCancelledNotError() async {
        let log = Box<[String]>([])
        let deps = recordingDeps(into: log, send: { throw CancellationError() })
        await ConversationTurnRunner.run(deps)
        XCTAssertEqual(log.value, ["send", "onCancelled", "finish"])
    }

    /// Provider SDKs can throw their own error type after the parent task was already cancelled
    /// (a barge-in mid-request). The interruption wins: no error is spoken.
    func testCancelledTaskWithProviderErrorReportsCancelledNotError() async {
        let log = Box<[String]>([])
        let deps = recordingDeps(into: log, send: {
            withUnsafeCurrentTask { $0?.cancel() }
            throw TestError()
        })
        await Task { await ConversationTurnRunner.run(deps) }.value
        XCTAssertEqual(log.value, ["send", "onCancelled", "finish"])
    }

    /// A barge-in that lands while `accept` is persisting/mirroring the response must still stop
    /// the reply from being spoken.
    func testCancellationAfterAcceptNeverSpeaks() async {
        let log = Box<[String]>([])
        let deps = recordingDeps(into: log, accept: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        })
        await Task { await ConversationTurnRunner.run(deps) }.value
        XCTAssertEqual(log.value, ["send", "postProcess(raw)", "accept(raw)", "onCancelled", "finish"])
    }
}
