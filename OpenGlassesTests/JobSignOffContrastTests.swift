import SwiftUI
import XCTest
@testable import OpenGlasses

/// Plan FO P2c — the one new non-text indicator on the sign-off sheet, measured rather than
/// eyeballed.
///
/// The signature pad has no label of its own beyond its heading: what says *where to sign* is its
/// border against its own fill. The first draft drew that border in `Color.secondary.opacity(0.6)`,
/// which is what the rest of the app uses for a hairline between rows — and on this fill it
/// measures under the 3:1 floor a non-text indicator has to clear. Both numbers are asserted, the
/// rejected one included, so a revert to the faded border fails here rather than shipping.
///
/// The arithmetic is `ContrastRatio`, the same the palette audit and the vault-link warning use.
/// The system colours are stated as their published values rather than resolved at runtime,
/// because a headless test has no trait collection to resolve them against.
final class JobSignOffContrastTests: XCTestCase {

    private struct Appearance {
        let name: String
        /// The pad's own ground — `Color(.secondarySystemBackground)`.
        let padFill: SRGBColor
        /// `secondaryLabel`, before any `.opacity(_:)` the view adds, already composited over the
        /// pad: the system colour is itself translucent.
        let secondaryLabel: SRGBColor

        static let light = Appearance(
            name: "light",
            padFill: SRGBColor(hex: 0xF2F2F7),
            // secondaryLabel is #3C3C43 at 60% in light.
            secondaryLabel: SRGBColor(hex: 0x3C3C43)
                .composited(alpha: 0.6, over: SRGBColor(hex: 0xF2F2F7)))
        static let dark = Appearance(
            name: "dark",
            padFill: SRGBColor(hex: 0x1C1C1E),
            // …and #EBEBF5 at 60% in dark.
            secondaryLabel: SRGBColor(hex: 0xEBEBF5)
                .composited(alpha: 0.6, over: SRGBColor(hex: 0x1C1C1E)))
        static let both = [light, dark]

        /// What ships: the border at full strength.
        var border: SRGBColor { secondaryLabel }
        /// What was rejected: the same colour faded the way a row separator is.
        var fadedBorder: SRGBColor { secondaryLabel.composited(alpha: 0.6, over: padFill) }
    }

    /// WCAG's floor for a user-interface component's boundary.
    private let nonTextFloor = 3.0

    func testTheSignaturePadBorderClearsTheNonTextFloor() {
        for appearance in Appearance.both {
            let ratio = ContrastRatio.ratio(appearance.border, appearance.padFill)
            XCTAssertGreaterThanOrEqual(
                ratio, nonTextFloor,
                "the signature pad's border measures \(String(format: "%.2f", ratio)):1 in \(appearance.name)")
        }
    }

    /// The pairing this replaced, asserted as still failing, so a revert fails here.
    func testTheFadedBorderThisReplacedIsStillBelowTheFloor() {
        let ratio = ContrastRatio.ratio(Appearance.light.fadedBorder, Appearance.light.padFill)
        XCTAssertLessThan(
            ratio, nonTextFloor,
            "the faded border now measures \(String(format: "%.2f", ratio)):1 in light — if this "
            + "has genuinely changed, the view can go back to it")
    }

    /// The customer summary itself is the primary label on a grouped row, which is the strongest
    /// pairing the app has. Asserted anyway: it is the text somebody is being asked to agree to.
    func testTheCustomerSummaryIsThePrimaryLabelOnItsRow() {
        let pairs = [("light", SRGBColor.black, SRGBColor(hex: 0xFFFFFF)),
                     ("dark", SRGBColor.white, SRGBColor(hex: 0x1C1C1E))]
        for (name, label, row) in pairs {
            let ratio = ContrastRatio.ratio(label, row)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "the customer summary measures \(String(format: "%.2f", ratio)):1 in \(name)")
        }
    }

    /// Printed so the PR can quote real numbers rather than "it looked fine".
    func testTheMeasuredRatiosAreRecorded() {
        for appearance in Appearance.both {
            let border = ContrastRatio.ratio(appearance.border, appearance.padFill)
            let faded = ContrastRatio.ratio(appearance.fadedBorder, appearance.padFill)
            print("[FO-P2c-contrast] \(appearance.name): signature pad border "
                  + "\(String(format: "%.2f", border)):1, the faded border it replaced "
                  + "\(String(format: "%.2f", faded)):1")
            XCTAssertGreaterThan(border, faded)
        }
    }
}
