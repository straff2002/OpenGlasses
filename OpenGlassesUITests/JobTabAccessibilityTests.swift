import XCTest

/// The Job tab, audited in each of its three states — and, first, audited for not being there at
/// all (Plan FO P2).
///
/// The absence case is the one that matters most for everyone who is not a technician: a fifth tab
/// that appeared for consumers, or flashed in and out while an entitlement resolved, would be a
/// regression nobody using the app for its other features would ever think to report.
final class JobTabAccessibilityTests: AccessibilityAuditCase {

    /// Open the Job tab, waiting long enough for a cold first launch.
    ///
    /// `openTab` allows 60s, which is plenty once a run is warm. The first launch of a run
    /// installs a large Debug build and starts it cold, and on a loaded host the tab bar has been
    /// observed to take longer than that to settle — so this waits on the tab itself first, for
    /// the same reason `AccessibilityAuditCase.awaitScreen` is generous.
    private func openJobTab(in app: XCUIApplication,
                            file: StaticString = #filePath, line: UInt = #line) {
        let tab = app.tabBars.buttons["Job"]
        if !tab.waitForExistence(timeout: 90) {
            // Same infrastructure symptom `AccessibilityAuditCase.relaunchIfTheUINeverCameUp`
            // exists for, one screen further in: the first launch of a run installs a large Debug
            // build and starts it cold, and on a loaded host that launch occasionally produces a
            // process whose seeded state never lands. One clean restart, then believe it.
            app.terminate()
            app.launch()
            XCTAssertTrue(tab.waitForExistence(timeout: 120),
                          "The Job tab never appeared, even after a clean restart. Tab bar: "
                          + "\(app.tabBars.buttons.allElementsBoundByIndex.map(\.label))",
                          file: file, line: line)
        }
        tab.tap()
    }

    /// The audit's own deferrals, plus the two that apply to any `Form`-shaped screen in this app.
    private var formDeferrals: [AuditDeferral] {
        [.systemFormChrome, .secondaryCopyContrast, .singleLineTextEntry]
    }

    // MARK: - Not there for everybody else

    /// Without Field Assist the bar is the four tabs that shipped, in the order they shipped in.
    func testWithoutFieldAssistThereIsNoJobTab() {
        let app = launch([.configured])
        let settings = app.tabBars.buttons["Settings"]
        awaitScreen(settings, named: "The tab bar")

        XCTAssertFalse(app.tabBars.buttons["Job"].exists,
                       "a Job tab appeared for a device with no Field Assist entitlement")
        XCTAssertEqual(app.tabBars.buttons.count, 4,
                       "the tab bar grew for a device with no Field Assist entitlement")
    }

    // MARK: - The empty state

    func testJobTabWithNoJobOpen() {
        let app = launch([.configured, .fieldAssist])
        openJobTab(in: app)

        let start = app.buttons["Start job"]
        awaitScreen(start, named: "The Job tab's empty state")
        XCTAssertTrue(app.staticTexts["Vault in use"].exists,
                      "the empty state should say which vault a new job would run against")

        audit(app, screen: "Job tab — no job open",
              deferring: formDeferrals + [AuditDeferral.contentUnderTheTabBar(of: app)])
    }

    // MARK: - Past jobs

    func testJobTabPastJobsAndOnePastJobPage() {
        // The photos modifier is on so the past-job page's own Photos section — the selection as
        // it was sent, and "Share full-size photos" — is part of what this audit measures rather
        // than a screen nothing ever looks at.
        let app = launch([.configured, .seedFieldHistory, .seedFieldPhotos])
        openJobTab(in: app)

        let pastJob = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Job 1004")).firstMatch
        awaitScreen(pastJob, named: "A past job row")

        audit(app, screen: "Job tab — past jobs",
              deferring: formDeferrals + [AuditDeferral.contentUnderTheTabBar(of: app)])

        pastJob.tap()
        let record = app.staticTexts["Work record"]
        awaitScreen(record, named: "The past job page")

        audit(app, screen: "Job tab — one past job",
              deferring: formDeferrals + [AuditDeferral.contentUnderTheTabBar(of: app)])

        // The page grew a Photos section between the record and the actions, so "Send report…" is
        // now below the fold and a `List` has not built it yet. Same assertion, reached the same
        // way the open job's controls already are.
        let send = app.buttons["Send report…"]
        scrollUntilVisible(send, in: app, named: "Send report…")
        XCTAssertTrue(app.buttons["Share full-size photos"].exists,
                      "a past job must offer its full-size pictures again")

        audit(app, screen: "Job tab — a past job's photos and actions",
              deferring: formDeferrals + [AuditDeferral.contentUnderTheTabBar(of: app)])
    }

    // MARK: - A job in progress

    func testJobTabWithAJobOpen() {
        let app = launch([.configured, .seedFieldJob])
        openJobTab(in: app)

        // The number leads the screen, so it is what says the job is open. The controls are down
        // the page and a `List` does not build a row until it is near the viewport, so they are
        // asserted after scrolling rather than by existence alone.
        let number = app.staticTexts["Job 1005"]
        awaitScreen(number, named: "The open job")
        XCTAssertTrue(app.staticTexts["Time on the job"].exists)

        audit(app, screen: "Job tab — job in progress",
              deferring: formDeferrals + [AuditDeferral.contentUnderTheTabBar(of: app)])

        let close = app.buttons["Close job"]
        scrollUntilVisible(close, in: app, named: "Close job")
        XCTAssertTrue(app.buttons["Open conversation"].exists)
        XCTAssertTrue(app.buttons["Read back the job"].exists)

        audit(app, screen: "Job tab — a job's controls",
              deferring: formDeferrals + [AuditDeferral.contentUnderTheTabBar(of: app)])
    }

    /// Nothing on this screen may clip or become unreachable at the largest accessibility size —
    /// least of all the job number, which is the one thing the whole record is filed under.
    func testJobTabAtTheLargestAccessibilitySize() {
        let app = launch([.configured, .seedFieldJob], contentSizeCategory: Self.ax5)
        // Five tabs at AX5: the bar keeps every label, so the tab is still addressed by name.
        openJobTab(in: app)

        let number = app.staticTexts["Job 1005"]
        awaitScreen(number, named: "The open job at AX5")
        awaitStableFrame(of: number, named: "The job number at AX5")

        audit(app, screen: "Job tab — job in progress at AX5",
              deferring: formDeferrals + [AuditDeferral.contentUnderTheTabBar(of: app)])
    }

    // MARK: - The evidence review

    /// The photos section on an open job, and the review step that closing puts in front of the
    /// technician. Both carry pictures, which is exactly where a screen stops being readable by
    /// label alone — every thumbnail has to say what it is, whether it is going out, and whether
    /// its faces were blurred.
    func testTheJobPhotosSectionAndTheCloseReview() {
        let app = launch([.configured, .seedFieldJob, .seedFieldPhotos])
        openJobTab(in: app)

        let number = app.staticTexts["Job 1005"]
        awaitScreen(number, named: "The open job with photos")

        let share = app.buttons["Share full-size photos"]
        scrollUntilVisible(share, in: app, named: "Share full-size photos")
        XCTAssertTrue(app.buttons["Add from the photo library"].exists,
                      "an open job must offer to add a picture from the phone")

        audit(app, screen: "Job tab — photos on the job",
              deferring: formDeferrals + [AuditDeferral.contentUnderTheTabBar(of: app)])

        let close = app.buttons["Close job"]
        scrollUntilVisible(close, in: app, named: "Close job")
        close.tap()

        let review = app.navigationBars["Photos for the report"]
        awaitScreen(review, named: "The evidence review")

        audit(app, screen: "Job tab — evidence review at close", deferring: formDeferrals)

        // The four things the step offers are under the grid, so a `List` has not built them yet.
        let skip = app.buttons["Skip photos and close the job"]
        scrollUntilVisible(skip, in: app, named: "Skip photos and close the job")
        XCTAssertTrue(app.buttons["Include all"].exists,
                      "the review must offer to take every picture in one tap")
        XCTAssertTrue(app.buttons["Close job and send these"].exists)

        audit(app, screen: "Job tab — evidence review actions", deferring: formDeferrals)
    }

    /// The review at the largest accessibility size. A grid of thumbnails beside wrapping captions
    /// and two optional mark buttons is the shape most likely to clip, and the one a technician
    /// with low vision most needs to be able to read before a picture goes to a customer.
    func testTheCloseReviewAtTheLargestAccessibilitySize() {
        let app = launch([.configured, .seedFieldJob, .seedFieldPhotos], contentSizeCategory: Self.ax5)
        openJobTab(in: app)

        let number = app.staticTexts["Job 1005"]
        awaitScreen(number, named: "The open job with photos at AX5")

        let close = app.buttons["Close job"]
        scrollUntilVisible(close, in: app, named: "Close job at AX5")
        close.tap()

        let review = app.navigationBars["Photos for the report"]
        awaitScreen(review, named: "The evidence review at AX5")
        let includeAll = app.buttons["Include all"]
        scrollUntilVisible(includeAll, in: app, named: "Include all at AX5")
        awaitStableFrame(of: includeAll, named: "Include all at AX5")

        audit(app, screen: "Job tab — evidence review at AX5", deferring: formDeferrals)
    }

    private static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"

    /// Swipe the page up until `element` is in the tree, or fail saying it never arrived.
    ///
    /// A `List` builds its rows lazily, so a control below the fold is not merely off-screen — it
    /// does not exist yet. Existence alone would therefore assert nothing about a long screen at a
    /// large text size, which is the case this is here to cover.
    private func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication,
                                    named name: String, swipes: Int = 8,
                                    file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<swipes {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable,
                      "\(name) never came into reach after \(swipes) swipes", file: file, line: line)
    }
}
