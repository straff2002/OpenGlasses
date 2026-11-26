import XCTest
@testable import OpenGlasses

/// The dispatcher's status reports set `LLMService.toolCallStatus`, a published property SwiftUI
/// observes. A report set off the main thread made SwiftUI flush its view updates there, and UIKit
/// aborted when that built a sheet's navigation stack. Every report must arrive on the main thread,
/// whichever thread the dispatch was started from.
final class ToolDispatcherMainThreadTests: XCTestCase {

    /// Records each report and whether it arrived on the main thread. Locked, because the point of
    /// the test is that it may be called from anywhere.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(status: ToolCallStatus, onMain: Bool)] = []

        func record(_ status: ToolCallStatus) {
            let onMain = Thread.isMainThread
            lock.lock(); defer { lock.unlock() }
            entries.append((status, onMain))
        }

        var statuses: [ToolCallStatus] { lock.lock(); defer { lock.unlock() }; return entries.map(\.status) }
        var offMain: [ToolCallStatus] {
            lock.lock(); defer { lock.unlock() }
            return entries.filter { !$0.onMain }.map(\.status)
        }
    }

    private func dispatchFromBackground(outcome: ToolExecutionOutcome, arguments: [String: Any]? = [:])
        async -> Recorder {
        let recorder = Recorder()
        let dispatcher = ToolDispatcher(
            execute: { _, _, _, _ in outcome },
            onStatus: { recorder.record($0) })
        let invocation = ToolInvocation(id: "1", name: "show_page", arguments: arguments)
        await Task.detached(priority: .userInitiated) {
            XCTAssertFalse(Thread.isMainThread, "the dispatch must start off the main thread")
            _ = await dispatcher.dispatch(invocation)
        }.value
        return recorder
    }

    func testEveryStatusOfACompletedCallArrivesOnTheMainThread() async {
        let recorder = await dispatchFromBackground(outcome: .completed("shown"))
        XCTAssertEqual(recorder.statuses, [.executing("show_page"), .completed("show_page")])
        XCTAssertEqual(recorder.offMain, [], "a status report landed off the main thread")
    }

    func testTheFailedStatusArrivesOnTheMainThread() async {
        let recorder = await dispatchFromBackground(outcome: .failedBeforeExecution(reason: "no"))
        XCTAssertEqual(recorder.statuses, [.executing("show_page"), .failed("show_page", "Failed")])
        XCTAssertEqual(recorder.offMain, [])
    }

    func testTheUnknownStatusArrivesOnTheMainThread() async {
        let recorder = await dispatchFromBackground(
            outcome: .outcomeUnknown(operationID: "op-1", message: "may still land"))
        XCTAssertEqual(recorder.statuses, [.executing("show_page"), .outcomeUnknown("show_page")])
        XCTAssertEqual(recorder.offMain, [])
    }

    /// Malformed arguments never reach the executor; the reports still land on the main thread.
    func testAMalformedCallReportsOnTheMainThread() async {
        let recorder = await dispatchFromBackground(outcome: .completed("unused"), arguments: nil)
        XCTAssertEqual(recorder.statuses, [.executing("show_page"), .failed("show_page", "Failed")])
        XCTAssertEqual(recorder.offMain, [])
    }
}
