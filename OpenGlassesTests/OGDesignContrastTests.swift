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
                         "chip label on card", "notice on canvas",
                         "filled button label on accent",
                         "success label on card", "error label on canvas",
                         "media label on black", "media secondary on black",
                         "media tertiary on black", "media attention label on black",
                         "media error label on black", "badge label on badge"] {
            XCTAssertTrue(names.contains(expected), "audit lost the \"\(expected)\" pair")
        }
    }

    // MARK: - Media chrome

    /// The camera preview, the HUD mirror and the caption scrim put chrome on
    /// black rather than on the canvas, so they carry their own corrected hues.
    func testMediaChromeClearsAAOnTheMediaGround() {
        let black = OGTheme.Token.media.dark
        for opacity in [1.0, OGTheme.Opacity.onMediaSecondary, OGTheme.Opacity.onMediaTertiary] {
            let text = OGTheme.Token.onInk.dark.composited(alpha: opacity, over: black)
            let ratio = ContrastRatio.ratio(text, black)
            XCTAssertTrue(
                ContrastRatio.meetsAA(ratio, size: .normal),
                "media chrome at \(opacity) measures \(String(format: "%.2f", ratio)):1 on black"
            )
        }
        for token in [OGTheme.mediaOkLabelToken,
                      OGTheme.mediaWarnLabelToken,
                      OGTheme.mediaErrorLabelToken] {
            let ratio = ContrastRatio.ratio(token.dark, black)
            XCTAssertTrue(
                ContrastRatio.meetsAA(ratio, size: .normal),
                "a media status label measures \(String(format: "%.2f", ratio)):1 on black"
            )
        }
    }

    /// The correction is per-*surface*, which is the whole reason the media
    /// family exists: the failure hue needs lightening to read on a dark card
    /// and needs nothing at all on black, so the two tokens must not be equal.
    func testMediaStatusLabelsAreCorrectedForBlackRatherThanForACard() {
        XCTAssertEqual(
            OGTheme.mediaErrorLabelToken.dark.hex, OGTheme.Token.error.dark.hex,
            "the failure hue already clears on black and should be left alone there"
        )
        XCTAssertNotEqual(
            OGTheme.mediaErrorLabelToken.dark.hex, OGTheme.errorLabelToken.dark.hex,
            "if the two corrections agree, one of the surfaces is being measured wrongly"
        )
        // Media tokens don't adapt — a video frame looks the same in both schemes.
        for token in [OGTheme.mediaOkLabelToken,
                      OGTheme.mediaWarnLabelToken,
                      OGTheme.mediaErrorLabelToken] {
            XCTAssertEqual(token.light.hex, token.dark.hex)
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

    /// A filled accent button paints the accent as *ground*, so the guarantee
    /// is about the label on top of it — and it has to hold for every preset,
    /// light and dark (the shipped coral wants white in one and near-black in
    /// the other).
    func testFilledButtonLabelClearsAAForEveryPreset() {
        for preset in AppAccent.presets {
            for scheme in OGColorScheme.allCases {
                let accent = OGTheme.resolved(preset.color, for: scheme)
                let label = OGTheme.onAccentLabelValue(accent)
                let ratio = ContrastRatio.ratio(label, accent)
                XCTAssertTrue(
                    ContrastRatio.meetsAA(ratio, size: .normal),
                    """
                    \(preset.name) in \(scheme) measures \
                    \(String(format: "%.2f", ratio)):1 as a filled button label.
                    """
                )
            }
        }
        // The choice is one pole or the other, never a tint of the accent.
        for preset in AppAccent.presets {
            let label = OGTheme.onAccentLabelValue(OGTheme.resolved(preset.color, for: .light))
            XCTAssertTrue(label == .white || label == .black)
        }
    }

    /// The status hues stay what a 7pt dot needs; the *labels* beside them are
    /// the corrected version — the raw green is unreadable as text on a card.
    func testStatusLabelsAreCorrectedWhileTheDotsAreNot() {
        XCTAssertEqual(OGTheme.Token.ok.light.hex, 0x34C759, "the success dot must not move")
        XCTAssertFalse(
            ContrastRatio.meetsAA(
                ContrastRatio.ratio(OGTheme.Token.ok.light, OGTheme.Token.card.light),
                size: .normal
            ),
            "if the raw green ever passes as text, the correction has stopped being needed"
        )
        for token in [OGTheme.okLabelToken, OGTheme.warnLabelToken, OGTheme.errorLabelToken] {
            for scheme in OGColorScheme.allCases {
                for surface in [OGTheme.Token.card, OGTheme.Token.canvas] {
                    XCTAssertTrue(
                        ContrastRatio.meetsAA(
                            ContrastRatio.ratio(token.value(for: scheme), surface.value(for: scheme)),
                            size: .normal
                        )
                    )
                }
            }
        }
    }

    /// `OGStatusLabel` is the one component that paints a status hue as text, so
    /// the thing worth asserting is its *mapping*: each kind must reach for the
    /// corrected label token, not the raw dot colour it sits next to.
    func testStatusLabelKindsPaintTheAuditedTokens() {
        XCTAssertEqual(OGStatusLabel.Kind.ok.token.light.hex, OGTheme.okLabelToken.light.hex)
        XCTAssertEqual(OGStatusLabel.Kind.ok.token.dark.hex, OGTheme.okLabelToken.dark.hex)
        XCTAssertEqual(OGStatusLabel.Kind.warn.token.light.hex, OGTheme.warnLabelToken.light.hex)
        XCTAssertEqual(OGStatusLabel.Kind.warn.token.dark.hex, OGTheme.warnLabelToken.dark.hex)
        XCTAssertEqual(OGStatusLabel.Kind.error.token.light.hex, OGTheme.errorLabelToken.light.hex)
        XCTAssertEqual(OGStatusLabel.Kind.error.token.dark.hex, OGTheme.errorLabelToken.dark.hex)

        // A kind reaching for the dot colour by mistake would still be a valid
        // token, so measure the consequence too.
        for kind in [OGStatusLabel.Kind.ok, .warn, .error] {
            for scheme in OGColorScheme.allCases {
                for surface in [OGTheme.Token.card, OGTheme.Token.canvas] {
                    let ratio = ContrastRatio.ratio(
                        kind.token.value(for: scheme),
                        surface.value(for: scheme)
                    )
                    XCTAssertTrue(
                        ContrastRatio.meetsAA(ratio, size: .normal),
                        """
                        \(kind) measures \(String(format: "%.2f", ratio)):1 in \(scheme) — \
                        a status label has to be readable, not just tinted.
                        """
                    )
                }
            }
        }
    }

    /// The three kinds differ in shape as well as hue, so the state survives a
    /// monochrome reading.
    func testStatusLabelKindsUseDistinctGlyphs() {
        let glyphs = [OGStatusLabel.Kind.ok, .warn, .error].map(\.systemImage)
        XCTAssertEqual(Set(glyphs).count, glyphs.count, "two status kinds share a glyph")
    }

    /// The badge exists because the convention it inherits fails: white on the
    /// system notification red measures ~3.6:1, which is under AA at the size a
    /// count badge is drawn in. Assert the gap, so the deepened red can't quietly
    /// drift back toward the colour that didn't work.
    func testTheBadgeGroundIsDeeperThanTheSystemRedItReplaces() {
        let systemRed = SRGBColor(hex: 0xFF3B30)
        XCTAssertFalse(
            ContrastRatio.meetsAA(ContrastRatio.ratio(.white, systemRed), size: .normal),
            "if the system red ever clears AA under white, the badge token is unnecessary"
        )
        XCTAssertTrue(
            ContrastRatio.meetsAA(
                ContrastRatio.ratio(OGTheme.Token.onInk.dark, OGTheme.Token.badge.dark),
                size: .normal
            )
        )
    }

    /// The safety report paints its own status vocabulary, and it is the one
    /// place outside OGDesign with a shared hue-per-state mapping. It has to
    /// reach the audited label tokens rather than the raw hues it draws boxes in.
    func testSafetyControlLabelsPaintTheAuditedTokens() {
        let expected: [(ControlStatus, OGColorToken)] = [
            (.direct, OGTheme.okLabelToken),
            (.indirect, OGTheme.warnLabelToken),
            (ControlStatus.none, OGTheme.errorLabelToken),
        ]
        for (status, token) in expected {
            for scheme in OGColorScheme.allCases {
                XCTAssertEqual(
                    OGTheme.resolved(SafetyControlColor.labelColor(for: status), for: scheme).hex,
                    token.value(for: scheme).hex,
                    "\(status) label drifted off the audited token in \(scheme)"
                )
            }
        }
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
