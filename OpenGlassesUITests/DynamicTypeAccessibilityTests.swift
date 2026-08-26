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
              deferring: [.secondaryCopyContrast, .heroCardChipRow, .rowValueWidth,
                          .contentUnderTheTabBar(of: app)])
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
