import XCTest
@testable import OpenGlasses

/// Device-traced 2026-08-23: the camera button in a live session did nothing visible. It was
/// throwing, storing the reason on the app-level error — and the transcript overlay in live mode
/// returned the *session's* error only, so the one channel the button writes to was the one channel
/// never read. The button exists only in live mode, so its failures were invisible by construction.
final class SessionErrorCopyTests: XCTestCase {

    /// The regression: with no session error, a general error must still be shown.
    func testAnAppErrorIsShownWhenTheSessionHasNone() {
        XCTAssertEqual(
            SessionErrorCopy.text(sessionError: nil, appError: "Camera: Glasses not connected"),
            "Camera: Glasses not connected")
    }

    /// The session's error is more specific, so it wins when both exist.
    func testTheSessionErrorWinsWhenBothArePresent() {
        XCTAssertEqual(
            SessionErrorCopy.text(sessionError: "Connection closed (code 1007)",
                                  appError: "Camera: something else"),
            "Connection closed (code 1007)")
    }

    /// Blank is not an error — a whitespace-only session error must not suppress a real app error,
    /// which would recreate the invisible-failure bug with an empty string instead of a nil.
    func testABlankSessionErrorDoesNotSuppressARealOne() {
        XCTAssertEqual(SessionErrorCopy.text(sessionError: "   ", appError: "Camera: denied"),
                       "Camera: denied")
    }

    func testNothingToReportStaysNil() {
        XCTAssertNil(SessionErrorCopy.text(sessionError: nil, appError: nil))
        XCTAssertNil(SessionErrorCopy.text(sessionError: "", appError: "  "))
    }
}
