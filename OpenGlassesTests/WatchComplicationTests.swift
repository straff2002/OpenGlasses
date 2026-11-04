import XCTest
@testable import OpenGlasses

/// A tap on a watch complication reaches the phone, and the wrist hears how it went.
///
/// The complications were once buttons that ran an intent inside the widget extension, which then
/// tried to message the phone itself. Neither half could work: a complication on a watch face
/// cannot run a button — a tap opens the watch app and nothing else — and the widget extension has
/// no usable session with the phone. Pressing Listen did nothing. The path is now a link the
/// widget carries, the watch app reads it and sends the command, and the phone reports listening
/// back whoever started or ended it. These checks hold each joint of that path.
final class WatchComplicationTests: XCTestCase {

    // MARK: - The link

    func testEveryCommandSurvivesItsLink() {
        for command in WatchComplicationLink.Command.allCases {
            let url = WatchComplicationLink.url(for: command)
            XCTAssertEqual(WatchComplicationLink.command(from: url), command, url.absoluteString)
        }
    }

    /// A complication can only send what the phone already understands.
    func testEveryCommandIsInThePhonesVocabulary() {
        for command in WatchComplicationLink.Command.allCases {
            XCTAssertNotNil(WatchConnectivityManager.commandToken(command.rawValue),
                            "the phone would not recognise \(command.rawValue) from a complication")
        }
    }

    func testALinkThatIsNotOursNamesNoCommand() throws {
        let listen = WatchComplicationLink.url(for: .toggleListen).absoluteString
        let strangers = [
            "avenkin://listen/toggle",                       // the phone's own scheme
            "avenkin-watch://elsewhere/toggleListen",        // right scheme, wrong host
            "avenkin-watch://complication/",                 // no command
            "avenkin-watch://complication/startEverything",  // not a command
            listen + "/extra",                               // a command and something more
        ]
        for text in strangers {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertNil(WatchComplicationLink.command(from: url), text)
        }
    }

    // MARK: - How long a tap waits for the phone

    func testATapWaitsBrieflyForThePhoneAndNoLonger() {
        let tapped = Date(timeIntervalSince1970: 1_000)
        let pending = PendingComplicationCommand(command: .toggleListen, requestedAt: tapped)
        XCTAssertTrue(pending.isLive(at: tapped))
        XCTAssertTrue(pending.isLive(at: tapped.addingTimeInterval(PendingComplicationCommand.lifetime)))
        XCTAssertFalse(pending.isLive(at: tapped.addingTimeInterval(PendingComplicationCommand.lifetime + 0.1)),
                       "a stale tap must not open the microphone later")
        XCTAssertFalse(pending.isLive(at: tapped.addingTimeInterval(-1)),
                       "a clock that moved backwards is not a reason to send")
    }

    /// Short enough that a late send is still the tap the wearer remembers making.
    func testTheWaitIsSeconds() {
        XCTAssertLessThanOrEqual(PendingComplicationCommand.lifetime, 10)
        XCTAssertGreaterThanOrEqual(PendingComplicationCommand.lifetime, 3)
    }

    // MARK: - The widget

    /// The widget extension draws and links; it never tries to act.
    func testTheComplicationsAreLinksNotButtons() throws {
        var widgets = 0
        var links = 0
        for file in try Self.swiftSources(in: "OpenGlassesWatchWidget") {
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = Self.strippingComments(text)
            for banned in ["Button(intent:", "WCSession", "import WatchConnectivity", "transferUserInfo"] {
                XCTAssertFalse(code.contains(banned),
                               "\(file.lastPathComponent) uses \(banned) — a watch-face complication cannot "
                                   + "run a button, and the widget extension cannot reach the phone")
            }
            widgets += code.components(separatedBy: "AppIntentConfiguration(").count - 1
            links += code.components(separatedBy: ".widgetURL(WatchComplicationLink.url(for: .").count - 1
        }
        XCTAssertGreaterThanOrEqual(widgets, 3, "found too few complications — is the repo anchor wrong?")
        XCTAssertEqual(links, widgets, "every complication carries the link for its command")
    }

    // MARK: - The watch app

    func testTheWatchAppSendsWhatTheLinkNames() throws {
        let view = try Self.source("OpenGlassesWatch/WatchMainView.swift")
        let handler = try XCTUnwrap(view.range(of: ".onOpenURL { url in"),
                                    "a complication's tap arrives as a link and the watch app must read it")
        let body = view[handler.lowerBound...].prefix(600)
        XCTAssertTrue(body.contains("WatchComplicationLink.command(from: url)"), String(body))
        XCTAssertTrue(body.contains("connectivity.runComplicationCommand(command)"), String(body))

        // The session is the app's, not a view's: it has to be up for a launch that draws nothing.
        let app = try Self.source("OpenGlassesWatch/OpenGlassesWatchApp.swift")
        XCTAssertTrue(app.contains("@StateObject private var connectivity = WatchConnectivityService()"))

        // A command that waited is sent when the phone turns up, from both places that can say so.
        let service = try Self.source("OpenGlassesWatch/WatchConnectivityService.swift")
        XCTAssertEqual(service.components(separatedBy: "self.flushPendingComplication()").count - 1, 2,
                       "flush on activation and on a reachability change")
        XCTAssertTrue(service.contains("session.receivedApplicationContext"),
                      "a fresh launch reads the status the phone sent while the app was not running")
        XCTAssertFalse(Self.strippingComments(service).contains("transferUserInfo"),
                       "a command is sent now or not at all — never queued for later")
    }

    // MARK: - The phone

    /// The wrist is told when listening changes, including when its app is not on screen.
    func testThePhoneReportsListeningWhoeverChangedIt() throws {
        let manager = try Self.source("OpenGlasses/Sources/Services/WatchConnectivityManager.swift")
        XCTAssertTrue(manager.contains("appState.$isListening"),
                      "a turn that ends on the phone has to reach the watch")

        // Plan GM: the push itself moved into the surface publisher, so the status and the map
        // cards always travel in one context; `sendStatusUpdate()` hands over to it.
        XCTAssertTrue(manager.contains("surfacePublisher?.push()"))
        let publisher = try Self.source("OpenGlasses/Sources/Services/Glance/WatchSurfacePublisher.swift")
        let start = try XCTUnwrap(publisher.range(of: "func push() {"))
        let end = try XCTUnwrap(publisher.range(of: "try? session.updateApplicationContext(context)",
                                                range: start.upperBound..<publisher.endIndex))
        let body = Self.strippingComments(String(publisher[start.lowerBound..<end.upperBound]))
        XCTAssertFalse(body.contains("isReachable"),
                       "the watch is reachable only while its app is on screen; the application context "
                           + "is what reaches it when it is not")
        XCTAssertTrue(body.contains("session.isWatchAppInstalled"),
                      "a phone with no watch app gathers nothing")
    }

    // MARK: - Helpers

    /// `#filePath` is the repo anchor: `<repo>/OpenGlassesTests/<thisfile>.swift`.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static func swiftSources(in folder: String) throws -> [URL] {
        let dir = repoRoot.appendingPathComponent(folder)
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
            .map { dir.appendingPathComponent($0) }
    }

    /// The source with `//` comments removed, so a comment explaining what is banned does not trip
    /// the ban.
    private static func strippingComments(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line }
            .joined(separator: "\n")
    }
}
