import XCTest
@testable import OpenGlasses

/// Legal-move coverage for the account sign-in state machine (Plan DD P1).
final class SignInFlowStateTests: XCTestCase {

    func testSeamlessPathRunsToConnected() {
        var state = SignInFlowState.idle
        XCTAssertTrue(state.apply(.present(listening: true)))
        XCTAssertEqual(state, .presenting(listening: true))
        XCTAssertTrue(state.isListening)
        XCTAssertTrue(state.isPresenting)

        XCTAssertTrue(state.apply(.capture))
        XCTAssertEqual(state, .captured)
        XCTAssertTrue(state.isBusy)

        XCTAssertTrue(state.apply(.beginExchange))
        XCTAssertEqual(state, .exchanging)
        XCTAssertFalse(state.isPresenting)

        XCTAssertTrue(state.apply(.succeed))
        XCTAssertEqual(state, .connected)
        XCTAssertTrue(state.isTerminal)
    }

    func testPastePathRunsToConnectedWithoutListening() {
        var state = SignInFlowState.idle
        XCTAssertTrue(state.apply(.present(listening: false)))
        XCTAssertFalse(state.isListening)

        XCTAssertTrue(state.apply(.beginExchange))
        XCTAssertTrue(state.apply(.succeed))
        XCTAssertEqual(state, .connected)
    }

    /// A flow that isn't listening has no listener to capture with.
    func testCaptureIsIllegalWhenNotListening() {
        var state = SignInFlowState.presenting(listening: false)
        XCTAssertFalse(state.apply(.capture))
        XCTAssertEqual(state, .presenting(listening: false))
    }

    func testDismissingTheSheetCancels() {
        var state = SignInFlowState.presenting(listening: true)
        XCTAssertTrue(state.apply(.cancel))
        XCTAssertEqual(state, .cancelled)
        XCTAssertTrue(state.isTerminal)
    }

    /// Programmatic dismissal after a capture must not knock an in-flight exchange over.
    func testCancelIsIgnoredOnceExchanging() {
        var state = SignInFlowState.exchanging
        XCTAssertFalse(state.apply(.cancel))
        XCTAssertEqual(state, .exchanging)
    }

    func testFailedExchangeCarriesItsReason() {
        var state = SignInFlowState.exchanging
        XCTAssertTrue(state.apply(.fail(reason: "no")))
        XCTAssertEqual(state, .failed(reason: "no"))
        XCTAssertEqual(state.failureReason, "no")
    }

    /// Every unhappy ending still lets a pasted code finish the job — never a dead end.
    func testPasteFallbackPicksUpAfterCancelOrFailure() {
        for terminal in [SignInFlowState.cancelled, .failed(reason: "boom")] {
            var state = terminal
            XCTAssertTrue(state.apply(.beginExchange), "\(terminal) should accept a pasted code")
            XCTAssertEqual(state, .exchanging)
        }
    }

    func testRetryRepresentsAFreshAttempt() {
        for terminal in [SignInFlowState.cancelled, .failed(reason: "boom")] {
            var state = terminal
            XCTAssertTrue(state.apply(.present(listening: true)))
            XCTAssertEqual(state, .presenting(listening: true))
        }
    }

    func testResetAlwaysReturnsToIdle() {
        for state in [SignInFlowState.idle, .presenting(listening: true), .captured,
                      .exchanging, .connected, .failed(reason: "x"), .cancelled] {
            var mutable = state
            XCTAssertTrue(mutable.apply(.reset))
            XCTAssertEqual(mutable, .idle)
        }
    }

    func testConnectedIsNotReenteredBySignInEvents() {
        var state = SignInFlowState.connected
        XCTAssertFalse(state.apply(.capture))
        XCTAssertFalse(state.apply(.beginExchange))
        XCTAssertFalse(state.apply(.cancel))
        XCTAssertEqual(state, .connected)
    }
}

/// The registered-redirect check that decides which providers get the zero-paste path (Plan DD).
final class OAuthRedirectTests: XCTestCase {

    func testLoopbackRedirectIsRecognised() throws {
        let redirect = try XCTUnwrap(OAuthRedirect("http://localhost:1455/auth/callback"))
        XCTAssertTrue(redirect.isLoopback)
        XCTAssertEqual(redirect.port, 1455)
        XCTAssertEqual(redirect.path, "/auth/callback")
    }

    func testNumericLoopbackIsRecognised() throws {
        let redirect = try XCTUnwrap(OAuthRedirect("http://127.0.0.1:8080/cb"))
        XCTAssertTrue(redirect.isLoopback)
        XCTAssertEqual(redirect.port, 8080)
    }

    func testHostedRedirectIsNotLoopback() throws {
        let redirect = try XCTUnwrap(OAuthRedirect("https://example.com/oauth/code/callback"))
        XCTAssertFalse(redirect.isLoopback)
        XCTAssertEqual(redirect.port, 443)
    }

    func testNonHTTPRedirectIsRejected() {
        XCTAssertNil(OAuthRedirect("myapp://callback"))
        XCTAssertNil(OAuthRedirect("not a url"))
    }

    /// The two shipping clients, checked against their actual constants: one can be answered
    /// locally, the other ends on a provider-hosted page and keeps its paste step.
    func testShippingClientsResolveToTheExpectedPaths() throws {
        let chatgpt = try XCTUnwrap(OAuthRedirect(ChatGPTOAuth.redirectURI))
        XCTAssertTrue(chatgpt.isLoopback)
        XCTAssertEqual(chatgpt.port, LoopbackCallbackServer.defaultPort)
        XCTAssertEqual(chatgpt.path, LoopbackCallbackServer.defaultCallbackPath)

        let claude = try XCTUnwrap(OAuthRedirect(ClaudeOAuth.redirectURI))
        XCTAssertFalse(claude.isLoopback)
    }
}
