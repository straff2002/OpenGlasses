import XCTest
@testable import OpenGlasses

/// A request made while another confirmation is on screen is `busy`, never `declined`: the wearer
/// was not asked, so nobody may be told they said no.
@MainActor
final class ToolConfirmationBusyTests: XCTestCase {

    private func waitForPending(_ coordinator: ToolConfirmationCoordinator) async {
        for _ in 0..<200 where coordinator.pending == nil {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNotNil(coordinator.pending)
    }

    func testASecondConfirmationWhileOneIsPendingIsBusyAndTheFirstStillResolves() async {
        let coordinator = ToolConfirmationCoordinator()
        var spoken: [String] = []
        coordinator.onSpeakPrompt = { spoken.append($0) }
        let first = Task { await coordinator.requestConfirmation(toolName: "send_message", summary: "first") }
        await waitForPending(coordinator)

        let second = await coordinator.requestConfirmation(toolName: "send_message", summary: "second")
        XCTAssertEqual(second, .busy)
        XCTAssertFalse(second.isApproved)
        XCTAssertEqual(coordinator.pending?.summary, "first", "the first prompt is left as it was")
        XCTAssertEqual(spoken.count, 1, "nothing is said for a request that was not asked")

        coordinator.resolve(true)
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .approved)
        XCTAssertNil(coordinator.pending)
    }

    func testADeniedConfirmationIsDeclinedNotBusy() async {
        let coordinator = ToolConfirmationCoordinator()
        let task = Task { await coordinator.requestConfirmation(toolName: "t", summary: "s") }
        await waitForPending(coordinator)
        coordinator.resolve(false)
        let outcome = await task.value
        XCTAssertEqual(outcome, .declined)
    }

    func testATextAskWhileAnApprovalIsPendingIsBusy() async {
        let coordinator = ToolConfirmationCoordinator()
        let first = Task { await coordinator.requestConfirmation(toolName: "t", summary: "s") }
        await waitForPending(coordinator)

        let text = await coordinator.requestTextAnswer(toolName: "code_agent", summary: "Which files?",
                                                       prefill: "all")
        XCTAssertEqual(text, .busy)

        coordinator.resolve(false)
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .declined)
    }

    func testAnApprovalWhileATextAskIsPendingIsBusyAndTheTextStillAnswers() async {
        let coordinator = ToolConfirmationCoordinator()
        let first = Task {
            await coordinator.requestTextAnswer(toolName: "code_agent", summary: "Which files?", prefill: "")
        }
        await waitForPending(coordinator)

        let second = await coordinator.requestConfirmation(toolName: "t", summary: "s")
        XCTAssertEqual(second, .busy)

        coordinator.resolveText("only the tests")
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .answered("only the tests"))
    }

    func testABoundApprovalOnABusySurfaceIssuesNoGrant() async {
        let coordinator = ToolConfirmationCoordinator()
        let first = Task { await coordinator.requestConfirmation(toolName: "t", summary: "s") }
        await waitForPending(coordinator)

        let binding = ApprovalBinding(seam: .native, toolName: "send_message", definitionDigest: "d",
                                      args: [:], sessionID: "s")
        let decision = await coordinator.requestApproval(toolName: "send_message", summary: "x",
                                                         binding: binding)
        XCTAssertEqual(decision, .busy)
        XCTAssertEqual(coordinator.approvalGrants.liveGrantCount, 0)

        coordinator.resolve(false)
        _ = await first.value
    }

    func testTheBusyLineNeverSaysDeclined() {
        let line = ConfirmationOutcome.busyToolResult
        XCTAssertFalse(line.localizedCaseInsensitiveContains("declin"))
        XCTAssertFalse(line.localizedCaseInsensitiveContains("denied"))
        XCTAssertTrue(line.localizedCaseInsensitiveContains("wasn't asked"))
    }
}
