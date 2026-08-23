import XCTest
@testable import OpenGlasses

/// Device-traced 2026-08-23: a Live session that could not start always said "Failed to connect to
/// Gemini". That is the fallback branch, reached whenever the connection state is not `.error` —
/// and a server-side *refusal* closes the socket instead of erroring it, so the close handler's
/// message (close code plus the server's own reason) was built, used for reconnect scheduling, and
/// never shown. The failure that most needed explaining was the one guaranteed not to get one.
final class GeminiLiveFailureCopyTests: XCTestCase {

    /// The regression that cost a device session: a close reason exists, so it must be shown.
    func testACloseReasonIsPreferredOverTheGenericFallback() {
        let message = GeminiLiveFailureCopy.message(
            errorStateMessage: nil,
            lastCloseReason: "Connection closed (code 1007: model not supported for bidiGenerateContent)")
        XCTAssertNotEqual(message, GeminiLiveFailureCopy.genericFallback)
        XCTAssertTrue(message.contains("bidiGenerateContent"),
                      "the server's own words are the whole point")
    }

    /// An explicit error state is more specific than a close, so it wins.
    func testAnErrorStateOutranksACloseReason() {
        XCTAssertEqual(
            GeminiLiveFailureCopy.message(errorStateMessage: "Connection timed out",
                                          lastCloseReason: "Connection closed (code 1000: no reason)"),
            "Connection timed out")
    }

    /// With nothing to report, say the honest generic thing rather than an empty alert.
    func testTheFallbackSurvivesWhenNothingIsKnown() {
        XCTAssertEqual(GeminiLiveFailureCopy.message(errorStateMessage: nil, lastCloseReason: nil),
                       GeminiLiveFailureCopy.genericFallback)
    }

    /// Empty and whitespace-only signals are not information — they must not beat the fallback,
    /// or the user gets a blank error where a sentence belongs.
    func testBlankSignalsDoNotDisplaceTheFallback() {
        XCTAssertEqual(GeminiLiveFailureCopy.message(errorStateMessage: "", lastCloseReason: "   "),
                       GeminiLiveFailureCopy.genericFallback)
        XCTAssertEqual(GeminiLiveFailureCopy.message(errorStateMessage: "  ",
                                                     lastCloseReason: "closed (code 1007)"),
                       "closed (code 1007)")
    }
}
