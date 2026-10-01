import SwiftUI
import XCTest
@testable import OpenGlasses

/// The widgets paint the app's own surfaces and the brand accent, and nothing else.
///
/// The Home Screen widget once carried its own tinted gradient — brown in dark mode, cream in
/// light — and its accent buttons were an 85% wash of the orange over it, so the brand orange read
/// as brown. The widget targets cannot import OGDesign, so their colours live in `AccentColors`
/// (compiled by every target) and `OGTheme` reads the same constants. These checks hold that:
/// the values, the colour the widget actually renders, and the widget sources themselves.
final class WidgetSurfaceGuardTests: XCTestCase {

    // MARK: - Values

    /// The widget ground is the app's card surface, in both schemes, as rendered.
    func testTheWidgetSurfaceRendersTheAppsCard() {
        for scheme in OGColorScheme.allCases {
            let rendered = OGTheme.resolved(AccentColors.widgetSurface, for: scheme)
            XCTAssertEqual(rendered.hex, OGTheme.Token.card.value(for: scheme).hex,
                           "the widget surface left the app's card in \(scheme)")
            XCTAssertEqual(rendered.hex, OGTheme.widgetSurfaceToken.value(for: scheme).hex)
        }
    }

    /// The app's surfaces are read from `AccentColors`, so the widgets and the app share one value.
    func testTheAppSurfacesComeFromTheSharedConstants() {
        XCTAssertEqual(OGTheme.Token.canvas.light.hex, AccentColors.canvasLightHex)
        XCTAssertEqual(OGTheme.Token.canvas.dark.hex, AccentColors.canvasDarkHex)
        XCTAssertEqual(OGTheme.Token.card.light.hex, AccentColors.cardLightHex)
        XCTAssertEqual(OGTheme.Token.card.dark.hex, AccentColors.cardDarkHex)
    }

    /// No surface carries a tint: the spread between its channels stays within a few levels.
    /// The old widget gradient's tinted stops are the negative control — each fails this check.
    func testTheSurfacesAreNeutral() {
        let surfaces: [UInt32] = [AccentColors.canvasLightHex, AccentColors.canvasDarkHex,
                                  AccentColors.cardLightHex, AccentColors.cardDarkHex]
        for hex in surfaces {
            XCTAssertLessThanOrEqual(Self.channelSpread(hex), Self.neutralSpread,
                                     String(format: "surface #%06X is tinted", hex))
        }
        let oldBrownAndCream: [UInt32] = [0x241712, 0xFCF5ED, 0xF2E8DB]
        for hex in oldBrownAndCream {
            XCTAssertGreaterThan(Self.channelSpread(hex), Self.neutralSpread,
                                 String(format: "the neutrality check no longer catches #%06X", hex))
        }
    }

    // MARK: - Sources

    /// The widget views paint through `AccentColors`, never a literal colour or a gradient.
    func testTheWidgetSourcesPaintNoLiteralColours() throws {
        for file in try Self.widgetSources() where file.lastPathComponent != "AccentColors.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for banned in ["Color(red:", "UIColor(red:", "Color(hue:", "LinearGradient(", "RadialGradient("] {
                XCTAssertFalse(text.contains(banned),
                               "\(file.lastPathComponent) paints \(banned)…) — put the value in AccentColors.swift")
            }
        }
    }

    /// The Home Screen widget sits on the shared surface and fills its buttons with the solid
    /// accent, labelled by the app's rule.
    func testTheHomeScreenWidgetUsesTheSharedSurfaceAndSolidAccent() throws {
        let file = Self.repoRoot.appendingPathComponent("GlassesActivityWidget/HomeScreenWidget.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains(".containerBackground(AccentColors.widgetSurface, for: .widget)"))
        XCTAssertFalse(text.contains("accent.opacity("),
                       "a washed accent fill lets the ground bleed through; fill with the solid accent")
        XCTAssertFalse(text.contains(".foregroundStyle(.white)"),
                       "a label on the accent reads AccentColors.onAiCoral, not a fixed white")
    }

    // MARK: - Helpers

    /// At most this many 8-bit levels between a surface's brightest and dimmest channel.
    private static let neutralSpread: UInt32 = 8

    private static func channelSpread(_ hex: UInt32) -> UInt32 {
        let channels = [(hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF]
        return channels.max()! - channels.min()!
    }

    /// `#filePath` is the repo anchor: `<repo>/OpenGlassesTests/<thisfile>.swift`.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func widgetSources() throws -> [URL] {
        var files: [URL] = []
        for folder in ["GlassesActivityWidget", "OpenGlassesWatchWidget"] {
            let dir = repoRoot.appendingPathComponent(folder)
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            files += names.filter { $0.hasSuffix(".swift") }.map { dir.appendingPathComponent($0) }
        }
        XCTAssertGreaterThanOrEqual(files.count, 5, "found too few widget sources — is the repo anchor wrong?")
        return files
    }
}
