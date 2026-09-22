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

    /// A job that recorded a clip as well as photographs (Plan FO P2b).
    ///
    /// The clip is the case a label-only screen most easily gets wrong: what tells a sighted
    /// technician it is a video rather than a still is a badge and a play glyph, and both are
    /// pixels. So this walks the section and the review with one on the job, and asserts the
    /// spoken half exists — the tile announces itself as a clip, and the record row says how long
    /// it runs and that it travels as a file of its own.
    func testTheJobPhotosSectionAndReviewWithAClipOnTheJob() {
        let app = launch([.configured, .seedFieldJob, .seedFieldPhotos, .seedFieldClips])
        openJobTab(in: app)

        let number = app.staticTexts["Job 1005"]
        awaitScreen(number, named: "The open job with a clip")

        let record = app.buttons["Record a clip"]
        scrollUntilVisible(record, in: app, named: "Record a clip")
        // The share button says what it actually hands out once a clip is on the job.
        XCTAssertTrue(app.buttons["Share full-size photos and clips"].exists,
                      "a job with a clip must not offer to share only its photographs")
        XCTAssertFalse(app.buttons["Share full-size photos"].exists)

        audit(app, screen: "Job tab — photos and clips on the job",
              deferring: formDeferrals + [AuditDeferral.contentUnderTheTabBar(of: app)])

        let close = app.buttons["Close job"]
        scrollUntilVisible(close, in: app, named: "Close job")
        close.tap()

        // The heading changes once the job carries something that is not a photograph — a title
        // promising only photos would be describing a different report.
        let review = app.navigationBars["Evidence for the report"]
        awaitScreen(review, named: "The evidence review with a clip")

        audit(app, screen: "Job tab — evidence review with a clip", deferring: formDeferrals)

        let skip = app.buttons["Skip photos and close the job"]
        scrollUntilVisible(skip, in: app, named: "Skip photos and close the job")
        audit(app, screen: "Job tab — evidence review with a clip, actions",
              deferring: formDeferrals)
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

    // MARK: - Customer sign-off

    /// The step the close flow now puts in front of the technician, and the customer-facing sheet
    /// behind its one button (Plan FO P2c).
    ///
    /// The hand-over sheet is the screen in this app most likely to be read by somebody who has
    /// never seen it before, standing up, holding a phone that is not theirs — so its labels,
    /// its touch targets and its one non-text indicator (the signature pad's border) are audited
    /// rather than assumed.
    func testTheSignOffStepAndTheHandOverSheet() {
        let app = launch([.configured, .seedFieldJob])
        openJobTab(in: app)
        awaitScreen(app.staticTexts["Job 1005"], named: "The open job")

        let close = app.buttons["Close job"]
        scrollUntilVisible(close, in: app, named: "Close job")
        close.tap()
        confirmClose(app)

        let step = app.navigationBars["Customer sign-off"]
        awaitScreen(step, named: "The sign-off step")
        XCTAssertTrue(app.buttons["Hand to customer"].exists)
        XCTAssertTrue(app.buttons["Close without a signature"].exists,
                      "sign-off is optional, so skipping it has to be one tap")
        XCTAssertTrue(app.buttons["The customer declined to sign"].exists)

        audit(app, screen: "Job tab — customer sign-off step", deferring: formDeferrals)

        app.buttons["Hand to customer"].tap()
        let sheet = app.navigationBars["Please sign"]
        awaitScreen(sheet, named: "The hand-over sheet")
        XCTAssertTrue(signaturePad(in: app).waitForExistence(timeout: 20),
                      "the customer needs somewhere to sign that says what it is")
        XCTAssertTrue(app.textFields["Your name"].exists)

        audit(app, screen: "Job tab — the customer's hand-over sheet", deferring: formDeferrals)
    }

    /// The same sheet at the largest accessibility size. A summary, two fields and a signature pad
    /// in one scroll view is the shape most likely to clip, and this is the screen a customer is
    /// asked to agree to.
    func testTheHandOverSheetAtTheLargestAccessibilitySize() {
        let app = launch([.configured, .seedFieldJob], contentSizeCategory: Self.ax5)
        openJobTab(in: app)
        awaitScreen(app.staticTexts["Job 1005"], named: "The open job at AX5")

        let close = app.buttons["Close job"]
        scrollUntilVisible(close, in: app, named: "Close job at AX5")
        close.tap()
        confirmClose(app)

        awaitScreen(app.navigationBars["Customer sign-off"], named: "The sign-off step at AX5")
        let handOver = app.buttons["Hand to customer"]
        scrollUntilVisible(handOver, in: app, named: "Hand to customer at AX5")
        handOver.tap()

        awaitScreen(app.navigationBars["Please sign"], named: "The hand-over sheet at AX5")
        let pad = signaturePad(in: app)
        scrollUntilVisible(pad, in: app, named: "The signature pad at AX5")
        awaitStableFrame(of: pad, named: "The signature pad at AX5")

        audit(app, screen: "Job tab — the hand-over sheet at AX5", deferring: formDeferrals)
    }

    /// A finished job that was signed: the acceptance block, with the summary that was agreed to,
    /// the attribution line and the signature picture — which is pixels, so the line above it has
    /// to carry the whole fact in words.
    func testAPastJobsCustomerAcceptanceBlock() {
        let app = launch([.configured, .seedFieldHistory, .seedFieldSignOff])
        openJobTab(in: app)

        let row = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Job 1004")).firstMatch
        awaitScreen(row, named: "A past job row")
        row.tap()

        let block = app.staticTexts["Customer acceptance"]
        awaitScreen(block, named: "The acceptance block")
        scrollUntilVisible(app.staticTexts["Signed on the technician's phone"], in: app,
                           named: "The acceptance line")

        audit(app, screen: "Job tab — a past job's customer acceptance",
              deferring: formDeferrals + [AuditDeferral.contentUnderTheTabBar(of: app)])
    }

    /// The signature pad, however the tree happens to expose a `PKCanvasView` wrapped in SwiftUI.
    private func signaturePad(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Signature pad")).firstMatch
    }

    /// Confirm the "Close this job?" dialog. The destructive button carries the same words as the
    /// row that raised it, so it is reached through the presented dialog rather than by label
    /// alone — and a `confirmationDialog` surfaces as a sheet on the phone and as an alert in some
    /// presentations, so both are tried.
    private func confirmClose(_ app: XCUIApplication, file: StaticString = #filePath,
                              line: UInt = #line) {
        let inSheet = app.sheets.buttons["Close job"]
        if inSheet.waitForExistence(timeout: 10) {
            inSheet.tap()
            return
        }
        let inAlert = app.alerts.buttons["Close job"]
        if inAlert.waitForExistence(timeout: 10) {
            inAlert.tap()
            return
        }
        XCTFail("the close confirmation never appeared", file: file, line: line)
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
