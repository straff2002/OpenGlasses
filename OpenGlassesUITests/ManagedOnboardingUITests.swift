import XCTest

/// Plan ND P2 — the first run on a phone a company manages, from a fresh install to Ready.
///
/// The company (`-OGUITestManagedOnboarding`) offers ChatGPT and the on-device model and pins no
/// model. No enrolment is faked — a profile is signed by a key this build cannot hold — so only the
/// route's inputs are the fixture's; every page drawn is the shipping one. The walk checks what the
/// person is asked, and what they are not: no services page and no assistant-name page.
final class ManagedOnboardingUITests: AccessibilityAuditCase {

    func testAManagedPhoneWalksTheShortFirstRunToReady() {
        executionTimeAllowance = 600
        let app = launch([.freshInstall, .managedOnboarding])

        // Welcome — the company is named, and the company route is not offered again.
        awaitScreen(app.buttons["Get Started"], named: "The welcome page")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Northbridge Mechanical")).firstMatch.exists,
                      "The welcome page does not name the company that manages the phone")
        XCTAssertFalse(app.buttons["Set up with my company"].exists,
                       "A managed phone is offered the company route again")

        // Assistant — only the company's choices.
        let choicesTitle = app.staticTexts["Choose your assistant"]
        tap(app.buttons["Get Started"], until: choicesTitle, named: "The company's assistant choices")
        XCTAssertFalse(app.staticTexts["Choose your AI"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Anthropic")).firstMatch.exists,
                       "A provider the company does not offer is listed")
        audit(app, screen: "Managed onboarding — Choose your assistant",
              deferring: [.secondaryCopyContrast, .systemFormChrome, .appBehindTheOverlay,
                          .decorativePageIndicator])
        tapRow(startingWith: "ChatGPT", in: app)

        // Connect ChatGPT — later is a real answer.
        tap(app.buttons["Continue"], until: app.staticTexts["Connect ChatGPT"], named: "The ChatGPT page")

        // Permissions — straight after the assistant: the services page is the company's.
        tap(app.buttons["I'll sign in later"], until: app.staticTexts["Permissions"], named: "The permissions page")

        // Language — one line, Continue.
        let languageTitle = app.staticTexts["Language"]
        tap(app.buttons["Continue"], until: languageTitle, named: "The language page")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Avenkin speaks")).firstMatch.exists,
                      "The language page does not say which language the app speaks")
        XCTAssertTrue(app.buttons["Change"].exists, "The language cannot be changed from the line")
        audit(app, screen: "Managed onboarding — Language",
              deferring: [.secondaryCopyContrast, .systemFormChrome, .appBehindTheOverlay,
                          .decorativePageIndicator])

        // Glasses, when this copy offers them; then Ready. Never the assistant-name page.
        let ready = app.staticTexts["You're ready"]
        let useThisPhone = app.buttons["Use this phone"]
        app.buttons["Continue"].tap()
        if useThisPhone.waitForExistence(timeout: 15) {
            XCTAssertFalse(app.staticTexts["Name Your Assistant"].exists)
            tap(useThisPhone, until: ready, named: "The Ready page")
        }
        awaitScreen(ready, named: "The Ready page")
        XCTAssertFalse(app.staticTexts["Enhance your experience"].exists)
        XCTAssertFalse(app.staticTexts["Name Your Assistant"].exists)
    }
}
