import XCTest
@testable import OpenGlasses

/// Plan HP P2 item 11 — what the wearer is told about Social mode, from the policy's refusal.
final class SocialModeCopyTests: XCTestCase {

    func testAWorkPhoneSaysWhySocialModeIsNotAvailable() {
        XCTAssertEqual(SocialModeCopy.refusalLine(.organisationManaged),
                       "Social mode isn't available on a phone managed by an organisation.")
        XCTAssertEqual(SocialModeCopy.refusalLine(.fieldAssistEdition),
                       "Social mode isn't available in a Field Assist edition.")
    }

    /// The wearer's own switch, and the tier being off, show themselves; there is nothing to add.
    func testNothingIsAddedWhenSocialModeIsOfferedOrSwitchedOffByTheWearer() {
        XCTAssertNil(SocialModeCopy.refusalLine(nil))
        XCTAssertNil(SocialModeCopy.refusalLine(.turnedOff))
        XCTAssertNil(SocialModeCopy.refusalLine(.accessibilityTierOff))
    }

    func testTheSwitchIsLockedOnlyWhereSocialModeIsNeverOffered() {
        for refusal in AssistiveModePolicy.Refusal.allCases {
            let workplace = refusal == .organisationManaged || refusal == .fieldAssistEdition
            XCTAssertEqual(SocialModeCopy.switchIsEditable(refusal), !workplace, refusal.rawValue)
            XCTAssertEqual(SocialModeCopy.refusalLine(refusal) != nil, workplace, refusal.rawValue)
        }
        XCTAssertTrue(SocialModeCopy.switchIsEditable(nil))
    }

    /// The copy follows the policy end to end: a managed phone refuses, and says so.
    func testThePolicyAndTheCopyAgree() {
        let managed = AssistiveModePolicy.evaluate(.init(organisationManaged: true, fieldAssistEditionActive: true,
                                                          accessibilityTierOn: true, socialSwitchOn: true))
        XCTAssertEqual(SocialModeCopy.refusalLine(managed.refusal),
                       "Social mode isn't available on a phone managed by an organisation.",
                       "the managed refusal outranks the edition")
        let personal = AssistiveModePolicy.evaluate(.init(organisationManaged: false, fieldAssistEditionActive: false,
                                                           accessibilityTierOn: true, socialSwitchOn: true))
        XCTAssertNil(SocialModeCopy.refusalLine(personal.refusal))
    }

    /// Plan HR P2 item 5: the footer says what Social mode describes, and that it does not guess at
    /// feelings.
    func testTheStandingFooterSaysWhatItDescribesAndThatItDoesNotGuessFeelings() {
        XCTAssertEqual(SocialModeCopy.standingFooter,
                       "Social mode describes what you can see about the person in front of you: their expression, where they're looking and what they're doing. It doesn't guess how they feel.")
        XCTAssertFalse(SocialModeCopy.standingFooter.contains("seems to feel"))
        let all = [SocialModeCopy.standingFooter]
            + AssistiveModePolicy.Refusal.allCases.compactMap(SocialModeCopy.refusalLine)
        for line in all { XCTAssertFalse(line.contains("Plan"), line) }
    }
}
