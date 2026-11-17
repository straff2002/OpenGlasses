import XCTest
@testable import OpenGlasses

/// The Action button and Control Center controls live in the widget extension, which the tests
/// cannot import, so these checks read its sources and assets.
///
/// A control renders out of process and draws its icon only from an SF Symbol name or a symbol
/// image in the extension's own asset catalog. The first control drew a SwiftUI view (`LogoIcon`)
/// and showed no icon at all; it was also an in-place toggle, so on a new phone the only control
/// on offer vibrated and did nothing visible.
final class ControlWidgetGuardTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static let controls = "GlassesActivityWidget/ListeningControlWidget.swift"

    func testBothControlsAreRegistered() throws {
        let bundle = try text("GlassesActivityWidget/GlassesActivityWidget.swift")
        XCTAssertTrue(bundle.contains("AskAvenkinControlWidget()"), "the Ask Avenkin control is not in the widget bundle")
        XCTAssertTrue(bundle.contains("ListeningControlWidget()"), "the listening control is not in the widget bundle")
    }

    /// A wearer's Action button assignment points at the kind; changing it drops the assignment.
    func testTheListeningControlKeepsItsStoredKind() throws {
        let source = try text(Self.controls)
        XCTAssertTrue(source.contains("\"com.openglasses.app.ListeningControl\""))
        XCTAssertTrue(source.contains("\"com.openglasses.app.AskControl\""))
        // The app reloads the listening control by this kind when listening changes.
        XCTAssertEqual(WidgetCenterReloader.listeningControlKind, "com.openglasses.app.ListeningControl")
    }

    func testTheControlsAreNamedForWhatTheyDo() throws {
        let source = try text(Self.controls)
        XCTAssertTrue(source.contains(".displayName(\"Ask Avenkin\")"))
        XCTAssertTrue(source.contains(".displayName(\"Avenkin Listening\")"),
                      "the toggle's name should read as an on/off, not as a launcher")
        XCTAssertFalse(source.contains("\"Avenkin Listen\""), "the old ambiguous name is back")
    }

    /// The listening toggle turns off from the background but opens the app to turn on: iOS refuses
    /// a background microphone start, so an "on" that stayed in the background read "On" while
    /// nothing listened.
    func testTheListeningToggleOpensTheAppOnlyToTurnOn() throws {
        XCTAssertTrue(SetListeningIntent.supportedModes.contains(.background), "turning off must not open the app")
        XCTAssertTrue(SetListeningIntent.supportedModes.contains(.foreground(.dynamic)))
        XCTAssertFalse(SetListeningIntent.supportedModes.contains(.foreground(.immediate)),
                       "an immediate foreground would open the app to turn listening off too")
        XCTAssertFalse(SetListeningIntent.isDiscoverable, "Shortcuts and Siri already have Enable/Disable Listening")

        let source = try text("GlassesActivityWidget/SetListeningIntent.swift")
        XCTAssertTrue(source.contains("if value {\n            // The press is the wearer's confirmation; no extra prompt.\n            try await continueInForeground(nil, alwaysConfirm: false)\n        }"),
                      "only an \"on\" press continues in the foreground, without a prompt")
        for spec in ["project.base.yml", "project.phone-only.yml"] {
            XCTAssertTrue(try text(spec).contains("- path: GlassesActivityWidget/SetListeningIntent.swift"),
                          "\(spec) does not compile the listening toggle's intent into the app")
        }
        XCTAssertFalse(try text("GlassesActivityWidget/ListeningToggleIntent.swift").contains("SetListeningIntent"),
                       "an extension-only copy of the toggle intent is back")
    }

    /// Icons a control can render: a system symbol or a symbol image. Never a SwiftUI view.
    func testTheControlIconsAreSymbolsTheExtensionShips() throws {
        let source = try text(Self.controls)
        let code = source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("LogoIcon("), "a control's icon cannot be a SwiftUI view")
        XCTAssertFalse(code.contains("\"AvenkinMark\""), "AvenkinMark is a plain image, not a symbol")

        for name in ["waveform", "waveform.slash"] {
            XCTAssertTrue(code.contains("\"\(name)\""))
            XCTAssertNotNil(UIImage(systemName: name), "\(name) is not a system symbol")
        }

        XCTAssertTrue(code.contains("image: \"AvenkinSymbol\""))
        let widgetSymbol = "GlassesActivityWidget/Assets.xcassets/AvenkinSymbol.symbolset/"
        let appSymbol = "OpenGlasses/Sources/Resources/Assets.xcassets/AvenkinSymbol.symbolset/"
        for file in ["Contents.json", "AvenkinSymbol.svg"] {
            XCTAssertEqual(try text(widgetSymbol + file), try text(appSymbol + file),
                           "the extension's AvenkinSymbol \(file) has drifted from the app's")
        }
        XCTAssertTrue(try text(widgetSymbol + "Contents.json").contains("\"symbols\""),
                      "the extension's AvenkinSymbol is not a symbol set")
    }
}
