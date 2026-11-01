import XCTest
@testable import OpenGlasses

/// Plan JE — the store copy shows no glasses. The rule lives in `GlassesSupportPolicy`; this pins
/// that each surface the plan names still consults it, so a refactor cannot quietly bring a
/// glasses row back for store users. A scrape of the sources, like `OutboundFrameConsumerTests`.
final class GlassesSurfaceGateTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every file that draws or starts something glasses-only, with the symbol it must consult.
    private let gatedSurfaces: [(path: String, consults: String)] = [
        // The SDK is never configured on a copy without glasses: no Bluetooth prompt, no call to Meta.
        ("OpenGlasses/Sources/Services/WearablesBootstrap.swift", "GlassesSupportPolicy.isSupported"),
        // `glassesAdded` feeds the session card's pill and headline, and the widget's phase.
        ("OpenGlasses/Sources/App/OpenGlassesApp.swift", "GlassesSupportPolicy.isSupported && ("),
        // The onboarding device step asks about no glasses, and the permissions page asks for no Bluetooth.
        ("OpenGlasses/Sources/App/Views/OnboardingView.swift", "if GlassesSupportPolicy.isSupported {"),
        // Devices & Privacy › Glasses.
        ("OpenGlasses/Sources/App/Views/SettingsScreens.swift", "glasses.isShown && GlassesSupportPolicy.isSupported"),
        // The Siri intents' spoken results name glasses only where there are any.
        ("OpenGlasses/Sources/App/Intents/ConnectionIntents.swift", "GlassesSupportPolicy.isSupported"),
        // The Home Screen widget draws its glasses line only when the app said it offers glasses.
        ("GlassesActivityWidget/HomeScreenWidget.swift", "WidgetGlassesSupport.read("),
    ]

    func testEveryGlassesSurfaceConsultsThePolicy() throws {
        for surface in gatedSurfaces {
            XCTAssertTrue(try source(surface.path).contains(surface.consults),
                          "\(surface.path) no longer consults `\(surface.consults)`: a store copy would show "
                              + "or start something glasses-only it cannot explain (Plan JE).")
        }
    }

    /// The app writes the widget's flag where its services start, so the widget can read it before
    /// the first glasses snapshot is ever written.
    func testTheAppWritesTheWidgetsSupportFlag() throws {
        XCTAssertTrue(try source("OpenGlasses/Sources/App/OpenGlassesApp.swift")
            .contains("WidgetGlassesSupport.write(GlassesSupportPolicy.isSupported, to: SharedAppState.defaults)"))
    }

    /// The onboarding page used to read `Wearables.shared` behind its own "configured" flag, which
    /// is set after a configure() that may have failed — and an unconfigured `Wearables.shared`
    /// is a fatalError. On a store copy configure() never runs, so that read must be behind the
    /// bootstrap's own truth.
    func testOnboardingReadsRegistrationOnlyBehindTheBootstrap() throws {
        let text = try source("OpenGlasses/Sources/App/Views/OnboardingView.swift")
        XCTAssertFalse(text.contains("bluetoothConfigured && Wearables.shared"))
        XCTAssertTrue(text.contains("WearablesBootstrap.isConfigured && WearablesBootstrap.registrationSnapshot"))
    }
}
