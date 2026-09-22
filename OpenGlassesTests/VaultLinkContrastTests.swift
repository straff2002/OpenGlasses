import SwiftUI
import XCTest
@testable import OpenGlasses

/// Plan FS PR2 — the unverified-source warning block, measured rather than eyeballed.
///
/// The block is the one thing on the review sheet that has to be read before somebody installs a
/// vault they cannot verify, so its contrast is asserted in both appearances rather than left to a
/// screenshot. The arithmetic is `ContrastRatio`, the same the palette audit uses.
final class VaultLinkContrastTests: XCTestCase {

    /// The two surfaces the block is drawn on: a grouped form row, light and dark.
    private struct Appearance {
        let name: String
        let scheme: OGColorScheme
        /// The row the block sits on.
        let row: SRGBColor
        /// The primary label on that row.
        let primaryLabel: SRGBColor

        static let light = Appearance(name: "light", scheme: .light,
                                      row: SRGBColor(hex: 0xFFFFFF), primaryLabel: .black)
        static let dark = Appearance(name: "dark", scheme: .dark,
                                     row: SRGBColor(hex: 0x1C1C1E), primaryLabel: .white)
        static let both = [light, dark]

        /// The ground the block paints for itself — the exact token the view fills with.
        var fill: SRGBColor { OGTheme.warnNoticeFillToken.value(for: scheme) }

        /// The heading, the glyph and the border, all one token.
        var noticeLabel: SRGBColor { OGTheme.warnNoticeLabelToken.value(for: scheme) }
    }

    /// 13-point and below is nowhere near WCAG's "large text", so the floor is the full 4.5:1.
    private let floor = 4.5

    func testTheWarningHeadingMeetsAAOnTheBlocksOwnFill() {
        for appearance in Appearance.both {
            let ratio = ContrastRatio.ratio(appearance.noticeLabel, appearance.fill)
            XCTAssertGreaterThanOrEqual(
                ratio, floor,
                "the unverified-source heading measures \(String(format: "%.2f", ratio)):1 in \(appearance.name)")
        }
    }

    func testTheWarningSentencesMeetAAOnTheBlocksOwnFill() {
        for appearance in Appearance.both {
            let ratio = ContrastRatio.ratio(appearance.primaryLabel, appearance.fill)
            XCTAssertGreaterThanOrEqual(
                ratio, floor,
                "the unverified-source sentences measure \(String(format: "%.2f", ratio)):1 in \(appearance.name)")
        }
    }

    /// The border is decoration, not text, so it only has to be visible against the row — the
    /// 3:1 non-text floor.
    func testTheWarningBorderIsVisibleAgainstTheRow() {
        for appearance in Appearance.both {
            let ratio = ContrastRatio.ratio(appearance.noticeLabel, appearance.row)
            XCTAssertGreaterThanOrEqual(
                ratio, 3,
                "the unverified-source border measures \(String(format: "%.2f", ratio)):1 in \(appearance.name)")
        }
    }

    /// Printed so the PR can quote real numbers rather than "it looked fine".
    func testTheMeasuredRatiosAreRecorded() {
        for appearance in Appearance.both {
            let heading = ContrastRatio.ratio(appearance.noticeLabel, appearance.fill)
            let body = ContrastRatio.ratio(appearance.primaryLabel, appearance.fill)
            let border = ContrastRatio.ratio(appearance.noticeLabel, appearance.row)
            print("[FS-contrast] \(appearance.name): heading \(String(format: "%.2f", heading)):1, "
                  + "body \(String(format: "%.2f", body)):1, border \(String(format: "%.2f", border)):1")
            XCTAssertGreaterThan(heading, 1)
            XCTAssertGreaterThan(body, 1)
            XCTAssertGreaterThan(border, 1)
        }
    }
}
