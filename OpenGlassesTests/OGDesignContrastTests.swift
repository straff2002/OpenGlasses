import SwiftUI
import XCTest
@testable import OpenGlasses

/// The OGDesign palette's contrast, asserted rather than eyeballed.
///
/// Every text-on-surface pair the components render is listed in
/// `OGTheme.contrastAudit`; a token edit that drops a pair below WCAG AA fails
/// here instead of shipping. Pure arithmetic — no views, no services.
final class OGDesignContrastTests: XCTestCase {

    // MARK: - The maths itself

    func testBlackOnWhiteIsTheMaximumRatio() {
        XCTAssertEqual(ContrastRatio.ratio(.black, .white), 21, accuracy: 0.001)
    }

    func testIdenticalColoursHaveNoContrast() {
        let coral = SRGBColor(hex: 0xF08A4B)
        XCTAssertEqual(ContrastRatio.ratio(coral, coral), 1, accuracy: 0.0001)
    }

    func testRatioIsSymmetric() {
        let a = SRGBColor(hex: 0x255E88)
        let b = SRGBColor(hex: 0xF5F3F0)
        XCTAssertEqual(ContrastRatio.ratio(a, b), ContrastRatio.ratio(b, a), accuracy: 0.0001)
    }

    /// Spot-check against the published WCAG figure for mid-grey on white.
    func testRelativeLuminanceMatchesTheWCAGFormula() {
        XCTAssertEqual(ContrastRatio.relativeLuminance(of: .white), 1, accuracy: 0.0001)
        XCTAssertEqual(ContrastRatio.relativeLuminance(of: .black), 0, accuracy: 0.0001)
        XCTAssertEqual(
            ContrastRatio.relativeLuminance(of: SRGBColor(hex: 0x808080)),
            0.2159, accuracy: 0.001
        )
    }

    func testHexRoundTrips() {
        for hex: UInt32 in [0x000000, 0xFFFFFF, 0xF08A4B, 0xB05426, 0x201E1C] {
            XCTAssertEqual(SRGBColor(hex: hex).hex, hex)
        }
    }

    func testCompositingHalfOpacityLandsHalfway() {
        let mid = SRGBColor.white.composited(alpha: 0.5, over: .black)
        XCTAssertEqual(mid.red, 0.5, accuracy: 0.0001)
        XCTAssertEqual(mid.hex, 0x808080)
    }

    func testFullyOpaqueCompositeIgnoresTheBackground() {
        let coral = SRGBColor(hex: 0xF08A4B)
        XCTAssertEqual(coral.composited(alpha: 1, over: .black).hex, coral.hex)
    }

    // MARK: - The palette

    func testEveryTextPairMeetsAAInBothSchemes() {
        for pair in OGTheme.contrastAudit {
            for scheme in OGColorScheme.allCases {
                let ratio = pair.ratio(in: scheme)
                XCTAssertTrue(
                    ContrastRatio.meetsAA(ratio, size: pair.textSize),
                    """
                    "\(pair.name)" measures \(String(format: "%.2f", ratio)):1 in \(scheme) — \
                    below the \(pair.textSize.minimumRatio):1 the pair needs.
                    """
                )
            }
        }
    }

    func testTheAuditCoversTheSurfacesComponentsActuallyPaint() {
        // A guard against the table quietly emptying out: the audit is only
        // worth anything while it names every surface OGDesign puts text on.
        let names = Set(OGTheme.contrastAudit.map(\.name))
        for expected in ["row title on card", "row subtitle on card",
                         "section header on canvas", "hero title on ink",
                         "hero status on ink", "hero unavailable chip",
                         "chip label on card", "notice on canvas"] {
            XCTAssertTrue(names.contains(expected), "audit lost the \"\(expected)\" pair")
        }
    }

    // MARK: - Derived accent colours

    /// The accent is the user's choice, so the guarantee has to hold for every
    /// preset — including White, which is invisible on a light card untreated.
    func testTintedAccentLabelClearsAAForEveryPreset() {
        for preset in AppAccent.presets {
            for scheme in OGColorScheme.allCases {
                let accent = OGTheme.resolved(preset.color, for: scheme)
                let label = OGTheme.tintedAccentLabelValue(accent, in: scheme)
                for surface in [OGTheme.Token.canvas, OGTheme.Token.card] {
                    let ground = accent.composited(
                        alpha: OGTheme.Opacity.accentFill,
                        over: surface.value(for: scheme)
                    )
                    let ratio = ContrastRatio.ratio(label, ground)
                    XCTAssertTrue(
                        ContrastRatio.meetsAA(ratio, size: .normal),
                        """
                        \(preset.name) in \(scheme) measures \
                        \(String(format: "%.2f", ratio)):1 on its own tint.
                        """
                    )
                }
            }
        }
    }

    func testInkAccentLabelClearsAAForEveryPreset() {
        for preset in AppAccent.presets {
            let accent = OGTheme.resolved(preset.color, for: .dark)
            let label = OGTheme.inkAccentLabelValue(accent)
            let ground = accent.composited(
                alpha: OGTheme.Opacity.accentInkFill,
                over: OGTheme.Token.ink.dark
            )
            XCTAssertTrue(
                ContrastRatio.meetsAA(ContrastRatio.ratio(label, ground), size: .normal),
                "\(preset.name) fails on the ink hero"
            )
            XCTAssertTrue(
                ContrastRatio.meetsAA(ContrastRatio.ratio(label, OGTheme.Token.ink.dark),
                                      size: .normal),
                "\(preset.name) fails against bare ink"
            )
        }
    }

    /// The correction has to be a nudge, not a repaint — the coral signature
    /// survives it. (Dark mode needs none at all.)
    func testTheShippedCoralIsBarelyMoved() {
        let dark = OGTheme.tintedAccentLabelValue(OGTheme.Token.accent.dark, in: .dark)
        XCTAssertEqual(dark.hex, OGTheme.Token.accent.dark.hex,
                       "dark-mode coral already clears AA and should be left alone")

        let light = OGTheme.tintedAccentLabelValue(OGTheme.Token.accent.light, in: .light)
        let shift = ContrastRatio.ratio(light, OGTheme.Token.accent.light)
        XCTAssertLessThan(shift, 1.3, "light-mode coral moved further than a nudge")
    }

    func testReadableLeavesAPassingColourAlone() {
        let onInk = OGTheme.Token.onInk.light
        XCTAssertEqual(
            ContrastRatio.readable(onInk, on: [OGTheme.Token.ink.dark]).hex,
            onInk.hex
        )
    }

    func testReadableMovesTowardTheReachablePole() {
        // Mid grey on mid grey can only be fixed by going one way or the other;
        // whichever it picks, the result has to clear.
        let grey = SRGBColor(hex: 0x808080)
        let fixed = ContrastRatio.readable(grey, on: [grey])
        XCTAssertTrue(ContrastRatio.meetsAA(ContrastRatio.ratio(fixed, grey), size: .normal))
    }

    func testLargeTextThresholdIsLowerThanNormal() {
        XCTAssertLessThan(
            ContrastRatio.TextSize.large.minimumRatio,
            ContrastRatio.TextSize.normal.minimumRatio
        )
        XCTAssertTrue(ContrastRatio.meetsAA(3.2, size: .large))
        XCTAssertFalse(ContrastRatio.meetsAA(3.2, size: .normal))
    }
}
