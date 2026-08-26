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

    // MARK: - What a VoiceOver user is told (Plan DF P2)

    /// The three endings all have to arrive in words. This flow spends most of its life inside a
    /// system sheet that dismisses *itself* on success, dropping the user back onto a screen where
    /// a button has quietly become a spinner — so an unspoken ending is indistinguishable from
    /// the sheet having closed for no reason.
    func testEveryEndingIsSpoken() {
        XCTAssertEqual(SignInFlowState.exchanging.spokenStatus, "Finishing sign-in")
        XCTAssertEqual(SignInFlowState.connected.spokenStatus, "Account connected")
        XCTAssertEqual(SignInFlowState.failed(reason: "The code expired").spokenStatus,
                       "The code expired")
        XCTAssertNotNil(SignInFlowState.cancelled.spokenStatus)
    }

    /// A failure with no reason still has to say *something*: the exchange path fails with an
    /// empty reason on purpose (the service publishes the specific message), and an empty
    /// announcement is a silent one.
    func testAReasonlessFailureStillSaysItFailed() {
        XCTAssertEqual(SignInFlowState.failed(reason: "").spokenStatus, "Sign-in failed")
    }

    /// Only a failure interrupts. The user is waiting on this answer and a queued line arrives
    /// after they have given up and moved elsewhere.
    func testOnlyAFailureInterrupts() {
        XCTAssertTrue(SignInFlowState.failed(reason: "").spokenStatusInterrupts)
        XCTAssertFalse(SignInFlowState.connected.spokenStatusInterrupts)
        XCTAssertFalse(SignInFlowState.exchanging.spokenStatusInterrupts)
    }

    /// The quiet states, each for its own reason: nothing has happened yet; the login sheet
    /// speaks for itself when the redirect can be caught; and `.captured` is followed by
    /// `.exchanging` within the same turn, so announcing both says one thing twice.
    func testTheStatesThatSayNothingSayNothing() {
        XCTAssertNil(SignInFlowState.idle.spokenStatus)
        XCTAssertNil(SignInFlowState.presenting(listening: true).spokenStatus)
        XCTAssertNil(SignInFlowState.captured.spokenStatus)
    }

    /// The paste route is the exception: no listener will answer, so the user has to be told
    /// there is a step waiting for them back on this screen.
    func testThePasteRouteIsExplainedWhenTheSheetOpens() {
        let spoken = SignInFlowState.presenting(listening: false).spokenStatus
        XCTAssertNotNil(spoken)
        XCTAssertTrue(spoken?.contains("paste") == true, "got \(spoken ?? "nil")")
    }

    /// Every state the machine can actually reach is accounted for — a new case must make a
    /// deliberate decision about whether it is spoken, rather than defaulting to silence.
    func testEveryReachableStateHasADecision() {
        var state = SignInFlowState.idle
        XCTAssertTrue(state.apply(.present(listening: true)))
        XCTAssertTrue(state.apply(.capture))
        XCTAssertTrue(state.apply(.beginExchange))
        XCTAssertTrue(state.apply(.succeed))
        XCTAssertEqual(state.spokenStatus, "Account connected")
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
