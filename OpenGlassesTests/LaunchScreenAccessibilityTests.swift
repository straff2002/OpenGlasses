import XCTest
@testable import OpenGlasses

/// The launch screen is decorative, and it must not be in the accessibility tree.
///
/// This is a regression gate for a flake, not a style rule. `SessionSurfaceAccessibilityTests`
/// audits the captions overlay and had been failing intermittently with five
/// `sufficientElementDescription` findings that were never about captions at all: on a loaded CI
/// runner the two-second splash was still in the tree, and its `StaticText`s — a product name and a
/// tagline, with nothing for VoiceOver to say about either — were what the audit measured.
/// `RootView` already hides everything *under* the splash; the splash itself was the half missing.
final class LaunchScreenAccessibilityTests: XCTestCase {

    func testTheLaunchScreenIsHiddenFromAccessibility() throws {
        let source = try String(contentsOf: Self.sourceFile("App/LaunchScreen.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains(".accessibilityHidden(true)"),
                      "the decorative splash is back in the accessibility tree")
    }

    /// And the audit's launch helper no longer waits on the splash *existing*, which a hidden
    /// element never does — it waits on the app underneath having appeared.
    func testTheAuditWaitsForTheAppRatherThanForTheSplash() throws {
        let source = try String(contentsOf: Self.uiTestFile("AccessibilityAudit.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func waitForLaunchScreenToClear"))
        let body = source[start.lowerBound...].prefix(900)
        XCTAssertTrue(body.contains("app.tabBars.buttons.firstMatch.waitForExistence"), String(body))
    }

    private static func sourceFile(_ relative: String) -> URL {
        root().appendingPathComponent("OpenGlasses/Sources").appendingPathComponent(relative)
    }

    private static func uiTestFile(_ relative: String) -> URL {
        root().appendingPathComponent("OpenGlassesUITests").appendingPathComponent(relative)
    }

    private static func root() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
}
