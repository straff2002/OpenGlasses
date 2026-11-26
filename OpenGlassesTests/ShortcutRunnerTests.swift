import XCTest
@testable import OpenGlasses

/// `run_shortcut` and the custom Shortcut tools share one round trip (`ShortcutRunner`). Outside
/// the foreground iOS won't open Shortcuts for the app, so nothing is opened and the reply says so,
/// instead of the old "Running shortcut…" for a run that never started.
@MainActor
final class ShortcutRunnerTests: XCTestCase {

    // MARK: - The background refusal

    func testRunShortcutInTheBackgroundOpensNothingAndSaysSo() async throws {
        let tool = SiriShortcutsTool(isAppActive: { false })
        let reply = try await tool.execute(args: ["shortcut_name": "Check Messages"])
        XCTAssertEqual(reply, ShortcutRunner.notInForegroundMessage)
        XCTAssertTrue(reply.contains("only be run while Avenkin is open"))
        XCTAssertFalse(reply.lowercased().contains("running"))
    }

    func testCustomShortcutToolInTheBackgroundOpensNothing() async throws {
        let tool = CustomToolWrapper(
            definition: CustomToolDefinition(id: "t", name: "inbox", description: "Inbox", parameters: [],
                                             actionType: .shortcut, shortcutName: "Inbox", urlTemplate: nil),
            isAppActive: { false })
        let reply = try await tool.execute(args: [:])
        XCTAssertEqual(reply, ShortcutRunner.notInForegroundMessage)
    }

    func testAMissingNameIsRefusedBeforeAnything() async throws {
        let reply = try await SiriShortcutsTool(isAppActive: { true }).execute(args: ["shortcut_name": "  "])
        XCTAssertEqual(reply, "No shortcut name provided.")
    }

    func testNoReplyNeverClaimsTheShortcutFinished() {
        let line = ShortcutRunner.noReplyMessage(shortcutName: "Inbox")
        XCTAssertTrue(line.contains("may still be running"))
        XCTAssertFalse(line.contains("completed"))
    }

    // MARK: - The link

    func testRunURLCarriesTheTokenOnAllThreeReturnLegs() throws {
        let token = ShortcutCallbackManager.makeCallbackToken()
        let url = try XCTUnwrap(ShortcutRunner.runURL(shortcutName: "Check Messages", input: nil,
                                                      callbackToken: token))
        let text = url.absoluteString
        XCTAssertTrue(text.hasPrefix("shortcuts://x-callback-url/run-shortcut?name=Check%20Messages"))
        for leg in ["shortcut-result", "shortcut-cancel", "shortcut-error"] {
            XCTAssertTrue(text.contains("openglasses://\(leg)?cb=\(token)"), leg)
        }
        XCTAssertFalse(text.contains("&input="))
    }

    /// A name or input holding a delimiter stays one value: it can't add a query item of its own,
    /// such as a forged `x-success`.
    func testDelimitersInANameOrInputCannotBreakOutOfTheirValue() throws {
        let token = ShortcutCallbackManager.makeCallbackToken()
        let url = try XCTUnwrap(ShortcutRunner.runURL(
            shortcutName: "A&x-success=evil://", input: "1+1=2 & more?#", callbackToken: token))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "name" }?.value, "A&x-success=evil://")
        XCTAssertEqual(items.first { $0.name == "text" }?.value, "1+1=2 & more?#")
        XCTAssertEqual(items.filter { $0.name == "x-success" }.count, 1)
    }

    func testAnEmptyNameBuildsNoLink() {
        XCTAssertNil(ShortcutRunner.runURL(shortcutName: "", input: nil, callbackToken: "t"))
    }

    // MARK: - One pending call at a time

    /// A newer call replaces the older one's token, so the older one can never be answered. Its
    /// wait ends at once with nothing, rather than hanging unresumed.
    func testASupersededWaitEndsWithNothingAndTheNewerOneIsAnswered() async throws {
        let manager = ShortcutCallbackManager()
        manager.setPending(toolName: "run_shortcut", callbackToken: "first")
        let first = Task { await manager.waitForResult(timeout: 5) }
        for _ in 0..<5 { await Task.yield() }

        manager.setPending(toolName: "run_shortcut", callbackToken: "second")
        let second = Task { await manager.waitForResult(timeout: 5) }
        let firstResult = await first.value
        XCTAssertNil(firstResult)

        manager.handleCallback(url: URL(string: "openglasses://shortcut-result?cb=first&output=stale")!)
        manager.handleCallback(url: URL(string: "openglasses://shortcut-result?cb=second&output=fresh")!)
        let secondResult = await second.value
        XCTAssertEqual(secondResult, "fresh")
    }

    func testCancelPendingEndsOnlyItsOwnWait() async {
        let manager = ShortcutCallbackManager()
        manager.setPending(toolName: "run_shortcut", callbackToken: "mine")
        let wait = Task { await manager.waitForResult(timeout: 5) }
        for _ in 0..<5 { await Task.yield() }
        manager.cancelPending(callbackToken: "someone-else")
        manager.cancelPending(callbackToken: "mine")
        let result = await wait.value
        XCTAssertNil(result)
    }
}
