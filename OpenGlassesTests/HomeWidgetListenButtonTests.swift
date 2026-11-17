import AppIntents
import XCTest
@testable import OpenGlasses

/// The Home Screen widget's Listen button, and where the widget is shown.
///
/// The button used to run one toggle intent in the widget extension. The extension can only flip
/// the shared flag, and iOS refuses a microphone start from the background, so with the app
/// suspended "Listen" turned into "Stop" while nothing listened. Starting now opens the app and runs
/// there; stopping stays in the extension. The extension's views cannot be imported, so most of
/// these checks read its sources.
final class HomeWidgetListenButtonTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static let widget = "GlassesActivityWidget/HomeScreenWidget.swift"

    /// The app compiles the start intent, so iOS can launch the app and run it there.
    func testStartingOpensTheApp() {
        XCTAssertTrue(StartListeningFromWidgetIntent.supportedModes.contains(.foreground(.immediate)))
        XCTAssertFalse(StartListeningFromWidgetIntent.supportedModes.contains(.background),
                       "a background start leaves the button reading Stop with the microphone off")
        XCTAssertFalse(StartListeningFromWidgetIntent.isDiscoverable,
                       "Shortcuts and Siri already have Enable Listening")
    }

    /// Every copy of the app compiles the start intent; without it the press has nowhere to run.
    func testEveryAppSpecCompilesTheStartIntent() throws {
        for spec in ["project.base.yml", "project.phone-only.yml"] {
            XCTAssertTrue(try text(spec).contains("- path: GlassesActivityWidget/StartListeningFromWidgetIntent.swift"),
                          "\(spec) does not compile the widget's start intent into the app")
        }
    }

    func testTheButtonStartsInTheAppAndStopsInTheExtension() throws {
        let source = try text(Self.widget)
        XCTAssertTrue(source.contains("Button(intent: StartListeningFromWidgetIntent())"))
        XCTAssertTrue(source.contains("Button(intent: DisableListeningIntent())"))
        XCTAssertFalse(source.contains("ToggleListeningIntent"), "the extension-only toggle is back")
    }

    /// Tinted and clear Home Screens, HomeView, StandBy and night mode flatten colour; only full
    /// colour may paint the solid accent under its label.
    func testTheSolidAccentIsFullColourOnly() throws {
        let source = try text(Self.widget)
        XCTAssertTrue(source.contains("@Environment(\\.widgetRenderingMode)"))
        XCTAssertTrue(source.contains("if renderingMode == .fullColor {"))
        XCTAssertEqual(source.components(separatedBy: ".background(accent, in:").count - 1, 1,
                       "the solid accent fill belongs in listenFace's full-colour branch only")
    }

    /// iOS 26 drops a widget `Link`'s URL when an image inside it uses an accented rendering mode,
    /// and the quick actions are links.
    func testNoAccentedImageRenderingModeInTheWidget() throws {
        XCTAssertFalse(try text(Self.widget).contains(".widgetAccentedRenderingMode("))
    }

    /// CarPlay and Apple HomeView both show the small widget. WidgetKit has no HomeView location,
    /// so disfavouring CarPlay would likely take the widget off HomeView too.
    func testTheWidgetStaysOnCarPlayAndHomeView() throws {
        let source = try text(Self.widget)
        XCTAssertTrue(source.contains(".systemSmall"))
        XCTAssertFalse(source.contains(".disfavoredLocations("))
    }
}
