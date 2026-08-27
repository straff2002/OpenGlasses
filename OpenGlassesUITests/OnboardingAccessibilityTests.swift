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

    // MARK: - Reinstall welcome-back

    /// The page a delete-and-reinstall lands on. It exists because the flow used to be *skipped*
    /// here — credentials survive an app delete and preferences don't, and credentials alone read
    /// as "already set up" — so the returning user was dropped into a session with no statement of
    /// what had carried over and what had not.
    func testWelcomeBackPagePassesAccessibilityAudit() {
        let app = launch([.reinstall])

        awaitScreen(app.buttons["Restore my setup"], named: "The welcome-back page")
        audit(app, screen: "Onboarding — Welcome back",
              deferring: [.secondaryCopyContrast, .appBehindTheOverlay,
                          .decorativePageIndicator])
    }

    /// The reinstall gate is only correct if it shows the page at all: on this launch state the
    /// app must not go straight to the session, and the page must be the welcome-back variant
    /// rather than the ordinary introduction.
    func testReinstallShowsTheWelcomeBackVariantRatherThanSkippingOnboarding() {
        let app = launch([.reinstall])

        awaitScreen(app.staticTexts["Welcome back"], named: "The welcome-back page")
        XCTAssertFalse(app.buttons["Get Started"].exists,
                       "A reinstall got the first-run introduction instead of the welcome-back page")
        XCTAssertTrue(app.buttons["Restore my setup"].exists)
        XCTAssertTrue(app.buttons["Set up fresh"].exists)
    }

    /// Restore is the old silent path, chosen rather than assumed: it finishes onboarding and
    /// hands the user the app, keys intact. The tab bar is the discriminator — it is
    /// `accessibilityHidden` for as long as onboarding is over it.
    func testRestoreMySetupLeavesOnboardingForTheApp() {
        let app = launch([.reinstall])

        awaitScreen(app.buttons["Restore my setup"], named: "The welcome-back page")
        app.buttons["Restore my setup"].tap()

        awaitScreen(app.tabBars.buttons["Voice"], named: "The session surface after restoring")
        XCTAssertFalse(app.buttons["Restore my setup"].exists,
                       "Onboarding is still up after the user chose to restore")
    }

    /// Set up fresh walks the ordinary flow instead — the same provider page every first run
    /// reaches, with the reinstall's credentials left alone rather than deleted underneath it.
    func testSetUpFreshWalksTheNormalFlow() {
        let app = launch([.reinstall])

        awaitScreen(app.buttons["Set up fresh"], named: "The welcome-back page")
        app.buttons["Set up fresh"].tap()

        awaitScreen(app.staticTexts["Choose your AI"], named: "The provider page")
        XCTAssertTrue(app.buttons["Back"].exists,
                      "The welcome-back page has to stay reachable from the page after it")
    }
}
