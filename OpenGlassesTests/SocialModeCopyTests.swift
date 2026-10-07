import XCTest
@testable import OpenGlasses

/// Plan HP P2 item 11 — what the wearer is told about Social mode. Plan HS P1 item 2 lifted the
/// managed-phone and Field Assist refusals, and their copy went with them; the standing footer is
/// what is left.
final class SocialModeCopyTests: XCTestCase {

    /// Plan HR P2 item 5: the footer says what Social mode describes, and that it does not guess at
    /// feelings.
    func testTheStandingFooterSaysWhatItDescribesAndThatItDoesNotGuessFeelings() {
        XCTAssertEqual(SocialModeCopy.standingFooter,
                       "Social mode describes what you can see about the person in front of you: their expression, where they're looking and what they're doing. It doesn't guess how they feel.")
        XCTAssertFalse(SocialModeCopy.standingFooter.contains("seems to feel"))
        XCTAssertFalse(SocialModeCopy.standingFooter.contains("Plan"))
    }

    /// Plan HS P1 item 2: nothing the wearer reads says Social mode is unavailable on a work phone.
    func testNoCopySaysSocialModeIsUnavailableOnAWorkPhone() {
        for line in [SocialModeCopy.standingFooter] {
            XCTAssertFalse(line.contains("managed by an organisation"), line)
            XCTAssertFalse(line.contains("Field Assist"), line)
            XCTAssertFalse(line.contains("isn't available"), line)
        }
    }
}
