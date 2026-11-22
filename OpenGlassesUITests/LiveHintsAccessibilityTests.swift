import XCTest

/// Plan MO P2 — the live-hints sheet and its session screen, reached from the Home card. The
/// session is the demo: it plays its own conversation and never opens the microphone, so it runs
/// the same on a simulator as on a phone.
final class LiveHintsAccessibilityTests: AccessibilityAuditCase {

    /// The deferrals any `Form` screen in this app carries.
    private let formDeferrals: [AuditDeferral] = [.systemFormChrome, .secondaryCopyContrast, .singleLineTextEntry]

    /// The card is off Home by default (Edit Home › Cards places it); the argument domain places it.
    private static let cardOnHome = ["-liveHintsOnHome", "YES"]

    private func openSheet(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        awaitScreen(app.tabBars.buttons["Avenkin"], named: "The tab bar", file: file, line: line)
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Live hints'")).firstMatch
        for _ in 0..<6 where !card.isHittable { app.swipeUp() }
        XCTAssertTrue(card.waitForExistence(timeout: 30), "The live hints card is not on Home", file: file, line: line)
        card.tap()
        awaitScreen(app.navigationBars["Live hints"], named: "The live hints sheet", file: file, line: line)
    }

    func testTheSessionSheetPassesAccessibilityAudit() {
        executionTimeAllowance = 600
        let app = launch([.configured], extraArguments: Self.cardOnHome)
        openSheet(app)
        audit(app, screen: "Live hints — session sheet", deferring: formDeferrals)
    }

    func testTheDemoSessionScreenPassesAccessibilityAudit() {
        executionTimeAllowance = 600
        let app = launch([.configured], extraArguments: Self.cardOnHome)
        openSheet(app)
        let demo = app.buttons["Try a demo"]
        for _ in 0..<6 where !demo.isHittable { app.swipeUp() }
        demo.tap()
        awaitScreen(app.navigationBars["Live hints demo"], named: "The demo session screen")
        XCTAssertTrue(app.buttons["Stop the demo"].waitForExistence(timeout: 10), "The demo has no Stop")
        audit(app, screen: "Live hints — demo session screen")
        app.buttons["Stop the demo"].tap()
    }
}
