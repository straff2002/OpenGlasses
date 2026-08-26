import XCTest

/// The first-run flow, audited page by page in the order a user meets them (Plan DF P4).
///
/// Onboarding is rank 1 on the plan's checklist for a reason: it is the door. A blind user who
/// cannot get through it never reaches the assistive features the app exists for. It also had no
/// end-to-end coverage of any kind before this target — walking the flow to audit it retires that
/// gap as a side effect.
final class OnboardingAccessibilityTests: AccessibilityAuditCase {

    /// Walks the flow with no credentials — the path a user takes when they want to look before
    /// they commit — auditing each page as it arrives. See the note at the end of the walk for
    /// where it stops and why.
    func testOnboardingPagesPassAccessibilityAudit() {
        let app = launch([.freshInstall])

        // Page 1 — Welcome
        awaitScreen(app.buttons["Get Started"], named: "The welcome page")
        audit(app, screen: "Onboarding 1/5 — Welcome",
              deferring: [.secondaryCopyContrast, .appBehindTheOverlay,
                          .decorativePageIndicator])
        app.buttons["Get Started"].tap()

        // Page 2 — Choose your AI
        awaitScreen(app.staticTexts["Choose your AI"], named: "The provider page")
        audit(app, screen: "Onboarding 2/5 — Choose your AI",
              deferring: [.secondaryCopyContrast, .systemFormChrome, .singleLineTextEntry,
                          .appBehindTheOverlay, .decorativePageIndicator])
        // Anthropic rather than the keyless on-device option: Apple Intelligence is hidden on
        // hardware that can't run it, and a page that may not be there is not a route a
        // regression gate can walk.
        tapRow(startingWith: "Anthropic", in: app)
        app.buttons["Continue"].tap()

        // Page 3 — Connect Claude. Audited with the key field empty, which is the state the page
        // is in for as long as it takes to read it.
        awaitScreen(app.staticTexts["Connect Claude"], named: "The access-key page")
        audit(app, screen: "Onboarding 3/5 — Access key",
              deferring: [.secondaryCopyContrast, .systemFormChrome, .singleLineTextEntry,
                          .appBehindTheOverlay, .decorativePageIndicator])
        app.buttons["I'll add it later"].tap()

        // Page 4 — Optional services
        awaitScreen(app.staticTexts["Enhance your experience"], named: "The services page")
        audit(app, screen: "Onboarding 4/5 — Services",
              deferring: [.secondaryCopyContrast, .systemFormChrome, .singleLineTextEntry,
                          .appBehindTheOverlay, .decorativePageIndicator])
        app.buttons["Continue"].tap()

        // Page 5 — Permissions. Audited without granting anything: tapping Grant raises a system
        // alert, and the ungranted state is the one every first-run user reads first.
        awaitScreen(app.staticTexts["Permissions"], named: "The permissions page")
        audit(app, screen: "Onboarding 5/5 — Permissions",
              deferring: [.secondaryCopyContrast, .systemFormChrome, .singleLineTextEntry,
                          .appBehindTheOverlay, .decorativePageIndicator])

        // The walk stops here, and on purpose. Page 6 is where onboarding starts talking to the
        // glasses — camera permission and registration with the companion app — and a simulator
        // has no glasses to register with. Driving into it produced a page that sometimes never
        // arrived, which is a gate that fails for a reason unrelated to what it measures. Pages 6
        // and 7 are built from the same components as the five above (`OGCard`/`OGRow` and the
        // permission rows audited on page 5, over the same `centeredScroll` the AX5 test drives),
        // so what is unaudited here is their composition, not their parts.
    }

    /// Where in the flow the user is has to be *said*, since the dots that draw it are 4pt of
    /// decoration. It rides on the page title as a value — the element focus is moved to on every
    /// page change. Back has to be reachable too, because the flow only ever incremented until
    /// P1 fixed it.
    func testOnboardingHeaderNamesThePageAndOffersBack() {
        let app = launch([.freshInstall])
        awaitScreen(app.buttons["Get Started"], named: "The welcome page")

        let welcomeTitle = app.staticTexts["OpenGlasses"].firstMatch
        XCTAssertEqual(welcomeTitle.value as? String, "Page 1 of 7",
                       "The welcome page's title does not say where in the flow it sits")
        XCTAssertFalse(app.buttons["Back"].exists,
                       "There is nothing behind the first page to go back to")

        app.buttons["Get Started"].tap()
        let providerTitle = app.staticTexts["Choose your AI"]
        awaitScreen(providerTitle, named: "The provider page")

        XCTAssertEqual(providerTitle.value as? String, "Page 2 of 7",
                       "The page position did not follow the page change")
        XCTAssertTrue(app.buttons["Back"].exists, "Back is not reachable from page 2")

        app.buttons["Back"].tap()
        awaitScreen(app.buttons["Get Started"], named: "The welcome page, on the way back")
    }
}
