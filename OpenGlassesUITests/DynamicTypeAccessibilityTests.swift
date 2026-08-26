import XCTest

/// The largest accessibility text size, on the two screens whose composition is most likely to
/// lose to it (Plan DF P4).
///
/// P3 swept fixed point sizes out of the app but could only read the result in a preview; the
/// onboarding hero was the one screen it recorded as *unconfirmed*, because it could not drive the
/// scroll. This is that measurement, run every time.
final class DynamicTypeAccessibilityTests: AccessibilityAuditCase {

    /// `UIPreferredContentSizeCategoryName` is honoured as a launch argument; AX5 is the top of
    /// the accessibility range.
    private static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"

    /// The carry-over: at AX5 the welcome page's subtitle has to be able to reach a position where
    /// it is fully readable above the pinned action button, rather than running underneath it.
    func testOnboardingHeroSubtitleClearsTheActionButtonAtAX5() {
        let app = launch([.freshInstall], contentSizeCategory: Self.ax5)

        let getStarted = app.buttons["Get Started"]
        awaitScreen(getStarted, named: "The welcome page at AX5")

        let subtitle = app.staticTexts["AI assistant for your smart glasses"]
        XCTAssertTrue(subtitle.waitForExistence(timeout: 60),
                      "The welcome subtitle is not in the accessibility tree at AX5 — it has "
                      + "been truncated away entirely")

        XCTAssertTrue(
            scrollUntilClear(subtitle, of: getStarted, in: app),
            """
            At AX5 the welcome subtitle never reaches a position where it is fully visible above \
            the “Get Started” button. At rest: \(atRest). Last measured: \(subtitle.frame). \
            Button \(getStarted.frame), screen \(app.frame).
            """
        )
    }

    // The ready page is the other hero built on the same `centeredScroll`, and an earlier draft
    // walked all seven pages at AX5 to measure it too. That walk is deliberately not here: it is
    // the same measurement on a shorter hero block, it was the slowest case in the suite by a
    // wide margin, and a seven-page drive at AX5 is exactly the shape of test that starts failing
    // for reasons that have nothing to do with accessibility. The welcome page is the harder of
    // the two and the one P3 recorded as unconfirmed, so it is the one that is gated.

    /// The settings hub at AX5 — the screen with the most rows, and the one where a 52pt row floor
    /// that did not scale would start clipping.
    func testSettingsHubPassesAccessibilityAuditAtAX5() {
        let app = launch([.configured], contentSizeCategory: Self.ax5)
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub at AX5")
        audit(app, screen: "Settings hub — AX5",
              deferring: [.secondaryCopyContrast, .heroCardChipRow,
                          .contentUnderTheTabBar(of: app)])
    }

    /// The session surface at AX5 — the screen the checklist recorded as "Dynamic Type: deferred
    /// to DG P4" for three of its rows, now that the phase that owed the numbers has set them.
    ///
    /// It earns its place beside the settings hub for the opposite reason: settings is a long
    /// scroll of one row shape, and this is a three-zone composition — status card, waveline,
    /// control dock — that used not to scroll at all. That is what this case caught the first time
    /// it was run: at AX5 the card ran off the top of the screen and the dock off the bottom, with
    /// no way to reach either, because the shipped layout only ever fitted while its text was a
    /// fixed size. So this measures the adaptation as much as the palette — and the Dynamic Type
    /// and clipping checks, which are the ones that caught it, run here unfiltered.
    func testSessionSurfacePassesAccessibilityAuditAtAX5() {
        let app = launch([.configured], contentSizeCategory: Self.ax5)

        // Open the tab rather than merely waiting for it, even though it is the tab the app starts
        // on. Waiting alone was tried twice and the audit refused to run at all — "invalid target
        // app", an infrastructure error rather than a finding — while the settings sweep below,
        // which is identical except that it *taps* its way to the screen, has never seen it. A tap
        // makes the automation session attach to the process the audit is about to walk; a
        // successful query apparently does not. The tap is a no-op for the app: the Voice tab is
        // already selected.
        openTab("Voice", in: app)

        // And wait for the *surface*, not just the shell around it: at AX5 this screen's first
        // layout pass is not cheap, and the capsule is the last part of it to resolve.
        let capsule = app.buttons.matching(
            NSPredicate(format: "label IN %@",
                        ["Connect & Talk", "Start talking", "End voice session",
                         "Stop speaking", "Cancel"])
        ).firstMatch
        awaitScreen(capsule, named: "The session capsule at AX5")

        audit(app, screen: "Session surface — AX5",
              deferring: [.contrastThroughGlass])
    }

    // MARK: - Helpers

    /// Whether `element` can be brought to a position where it is wholly on screen and wholly
    /// above `pinned`.
    ///
    /// Deliberately not `swipeUp()`: a stock swipe travels most of the screen, which on a page
    /// whose hero block only just outgrows the scroll viewport jumps straight past the one
    /// position that reads. This drags a fixed, small distance instead, so what is measured is
    /// whether the layout *has* a readable position — not whether a coarse gesture happens to
    /// land on it.
    private func scrollUntilClear(
        _ element: XCUIElement,
        of pinned: XCUIElement,
        in app: XCUIApplication,
        steps: Int = 12
    ) -> Bool {
        let screen = app.frame
        let pinnedTop = pinned.frame.minY

        func isClear() -> Bool {
            let frame = element.frame
            guard frame.height > 0 else { return false }
            return frame.minY >= screen.minY && frame.maxY <= pinnedTop
        }

        atRest = element.frame
        if isClear() { return true }

        // A short, slow drag upward: content moves up by roughly the drag distance.
        for _ in 0..<steps {
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: screen.midX, dy: pinnedTop - 40))
            let end = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: screen.midX, dy: pinnedTop - 140))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow,
                        thenHoldForDuration: 0.1)
            if isClear() { return true }
            // Once the element's top has gone above the screen, further scrolling only makes it
            // worse — the layout has no position that reads.
            if element.frame.maxY < screen.minY { return false }
        }
        return false
    }

    /// Where the measured element sat before any scrolling — the position the page opens at, and
    /// the one a reader meets first. Reported in the failure message.
    private var atRest: CGRect = .zero
}
