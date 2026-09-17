import XCTest

/// The settings hub in both of its shapes, the accessibility category, and the model editor
/// (Plan DF P4) — ranks 4 and 5 on the plan's checklist, plus the one long-tail screen a user is
/// most likely to have to operate without sight: the editor for the model they talk to.
final class SettingsAccessibilityTests: AccessibilityAuditCase {

    // MARK: The hub, folded

    /// The first-run shape: Everyday categories as rows, everything else pitched as a Discover
    /// card. Folded is never locked, and the accessibility category is structurally incapable of
    /// being folded away — which is worth a gate of its own, below.
    func testSettingsHubFoldedPassesAccessibilityAudit() {
        let app = launch([.configured])
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub")
        awaitScreen(app.staticTexts["Discover"], named: "The Discover section")
        audit(app, screen: "Settings hub — folded",
              deferring: [.secondaryCopyContrast, .contentUnderTheTabBar(of: app)])
    }

    /// The whole surface at once, which is a different tree: every foldable category becomes a row
    /// and the Discover cards go away.
    func testSettingsHubShowingEverythingPassesAccessibilityAudit() {
        let app = launch([.configured, .showAllSettings])
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub")
        audit(app, screen: "Settings hub — showing everything",
              deferring: [.secondaryCopyContrast, .contentUnderTheTabBar(of: app)])
    }

    /// Pinned, in both shapes. The one category a user reaching for assistive features must be
    /// able to find is the one the journey must never be able to hide.
    func testAccessibilityCategoryIsAlwaysAReachableRow() {
        let app = launch([.configured])
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub")

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Accessibility'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60),
                      "The Accessibility category is not a row in the folded hub")
    }

    // MARK: The accessibility category

    func testAccessibilityCategoryPassesAccessibilityAudit() {
        let app = launch([.configured])
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub")
        tapRow(startingWith: "Accessibility", in: app)

        awaitScreen(app.navigationBars["Accessibility"], named: "The accessibility category")
        audit(app, screen: "Settings — Accessibility category",
              deferring: [.secondaryCopyContrast, .systemFormChrome])
    }

    /// The master switch reveals three whole sections below it. Nothing about flipping a switch
    /// says "and now there is more page", so P2 made it announce — and the sections it reveals
    /// have to survive an audit of their own.
    func testAccessibilityCategoryRevealedSectionsPassAccessibilityAudit() {
        let app = launch([.configured])
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub")
        tapRow(startingWith: "Accessibility", in: app)
        awaitScreen(app.navigationBars["Accessibility"], named: "The accessibility category")

        let master = app.switches["Enable Reading Accessibility"]
        XCTAssertTrue(master.waitForExistence(timeout: 60),
                      "The master switch is unnamed — a bare `Toggle(\"\")` reaches VoiceOver as "
                      + "an unnamed switch")
        // Drive it to a known state rather than assuming a tap flips it: the row is the target,
        // the switch is what carries the value, and a test that assumes the two agree fails for
        // a reason that has nothing to do with what it is measuring.
        if master.value as? String != "1" { master.switches.firstMatch.tap() }
        XCTAssertEqual(master.value as? String, "1",
                       "The master switch did not turn on when its row was tapped")

        // The revealed picker row, not the section header above it — a row is a control the user
        // can reach, and it is the thing whose arrival the announcement promises.
        let revealed = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Reading Level'")
        ).firstMatch
        XCTAssertTrue(revealed.waitForExistence(timeout: 20),
                      "Turning the master switch on revealed nothing")
        audit(app, screen: "Settings — Accessibility category, sections revealed",
              deferring: [.secondaryCopyContrast, .systemFormChrome, .singleLineTextEntry])
    }

    /// Plan FF P1/PR3 — the launch switch, and the sentence that has to come with it.
    ///
    /// A switch that decides whether opening the app claims the microphone and opens the camera is
    /// the one control in this app whose *consequence* a blind wearer cannot check by looking. So
    /// two things are asserted: the switch is named (a bare `Toggle("")` reaches VoiceOver as an
    /// unnamed switch), and turning it on reveals a status sentence plus the route to the iOS
    /// permission page — the recovery that has no in-app equivalent.
    func testStartOnLaunchSwitchIsNamedAndExplainsWhatWillHappen() {
        let app = launch([.configured])
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub")
        tapRow(startingWith: "Accessibility", in: app)
        awaitScreen(app.navigationBars["Accessibility"], named: "The accessibility category")

        let toggle = app.switches["Start Blind Assistant When I Open the App"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 60),
                      "The launch switch is unnamed or missing")

        if toggle.value as? String != "1" { toggle.switches.firstMatch.tap() }
        XCTAssertEqual(toggle.value as? String, "1",
                       "The launch switch did not turn on when its row was tapped")

        let settingsRoute = app.buttons["Open iOS Settings for OpenGlasses"]
        XCTAssertTrue(settingsRoute.waitForExistence(timeout: 20),
                      "Turning the switch on revealed no route to the iOS permission page, which "
                      + "is the only place a refused microphone can be granted")

        audit(app, screen: "Settings — Accessibility category, start-on-launch on",
              deferring: [.secondaryCopyContrast, .systemFormChrome, .singleLineTextEntry])

        // Leave the setting as it was found: it decides what the next launch does, and a UI test
        // must not hand the next case a session it did not ask for.
        toggle.switches.firstMatch.tap()
    }

    /// Plan FF P1/PR8 — the two new rows, and the processing summary screen itself.
    ///
    /// The readiness check is only asserted as a *reachable, named row*: tapping it would claim the
    /// glasses camera and speak a test line, and a UI test that starts hardware it cannot observe
    /// is a UI test that hangs. Its decisions are covered headlessly by
    /// `ReadinessWalkthroughTests`; what a UI test can prove is that a wearer can find it.
    func testTheReadinessAndProcessingRowsAreReachableAndTheSummaryPassesTheAudit() {
        let app = launch([.configured])
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub")
        tapRow(startingWith: "Accessibility", in: app)
        awaitScreen(app.navigationBars["Accessibility"], named: "The accessibility category")

        // The category is longer than a screen, and a `Form` only builds the rows it has reached,
        // so "does not exist yet" and "is not there" are the same query until it is scrolled.
        let readiness = scrollUntilFound(labelStartingWith: "Check the Assistant Is Ready", in: app)
        XCTAssertTrue(readiness.exists,
                      "The readiness check is not a reachable row in the accessibility category")

        let processing = scrollUntilFound(labelStartingWith: "How Your Requests Are Processed",
                                          in: app)
        XCTAssertTrue(processing.exists,
                      "The processing summary is not a reachable row in the accessibility category")
        processing.tap()

        awaitScreen(app.navigationBars["How Requests Are Processed"],
                    named: "The processing summary")
        // Every row is present, whatever this launch configuration routes them to.
        XCTAssertTrue(app.staticTexts["What you say"].waitForExistence(timeout: 20),
                      "The transcription row is missing from the processing summary")
        audit(app, screen: "Settings — How requests are processed",
              deferring: [.secondaryCopyContrast, .systemFormChrome])
    }

    /// Scroll a long settings category until a row exists, and return it. Returns the query either
    /// way, so the caller's assertion carries the failure message.
    private func scrollUntilFound(labelStartingWith prefix: String,
                                  in app: XCUIApplication,
                                  steps: Int = 10) -> XCUIElement {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
            .firstMatch
        if element.waitForExistence(timeout: 5) { return element }
        for _ in 0..<steps {
            app.swipeUp()
            if element.exists { return element }
        }
        return element
    }

    // MARK: The model editor

    /// Reached through a folded category, so the walk also exercises unfolding.
    func testModelEditorPassesAccessibilityAudit() {
        let app = launch([.configured, .showAllSettings])
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub")

        tapRow(startingWith: "AI & Personality", in: app)
        awaitScreen(app.navigationBars["AI & Personality"], named: "The AI & Personality category")

        // A model row is one combined element: name, provider, whether it holds a key, whether it
        // takes images. Addressed by its leading name for that reason.
        tapRow(startingWith: "Apple Intelligence", in: app)

        awaitScreen(app.navigationBars["Edit Model"], named: "The model editor")
        audit(app, screen: "Settings — Model editor",
              deferring: [.secondaryCopyContrast, .systemFormChrome, .singleLineTextEntry])
    }

    // MARK: Unfold, and where focus goes

    /// Unfolding a Discover card moves the category from the bottom of the page to a row near the
    /// top — the card the user is standing on disappears in the same beat.
    ///
    /// P2 deferred the focus question to a running UI, and this is it: what the test measures is
    /// whether the unfolded category is *reachable as a row* immediately afterwards, which is the
    /// precondition for handing focus to it. Where VoiceOver focus actually lands is not
    /// observable from XCUITest — it reports the accessibility tree, not the screen reader's
    /// cursor — so the plan records the measured limit rather than claiming a pass.
    func testUnfoldingADiscoverCardMovesTheCategoryIntoTheList() {
        let app = launch([.configured])
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub")
        awaitScreen(app.staticTexts["Discover"], named: "The Discover section")

        let unfold = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'AI & Personality'")
        ).firstMatch
        XCTAssertTrue(unfold.waitForExistence(timeout: 60),
                      "The AI & Personality Discover card is not reachable")
        unfold.tap()

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'AI & Personality'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "The unfolded category never appeared as a row — there is nothing for "
                      + "VoiceOver focus to be handed to")

        // Hold the hub still before measuring it.
        //
        // Unfolding is an animated replacement: the card animates out of Discover while the row
        // animates into the list above it. Two things follow from that, and both were measured
        // rather than guessed — this case failed on CI in 3 runs out of 5 on an unchanged tree.
        //
        // The card sits under the finger when it is replaced, so the same tap can land a second
        // time on the row that took its place, pushing the category screen. The audit then
        // measures that screen instead of the hub: the findings came back as 'AI Models',
        // 'Personality', 'How It Behaves' — the category's own copy, none of it this case's
        // subject. So assert the hub is still what is on screen.
        //
        // And the audit must not run while the list is still moving. Waiting for the card's pitch
        // to disappear was not enough, for two reasons. The old wait was guarded by
        // `if pitch.exists`, so when the pitch had already gone at that instant it did not wait
        // at all. And the pitch leaving only means the card has left the tree; the row taking its
        // place is still animating into the list. After #475 the case still failed twice in seven
        // main runs (6f08dfe2, 8de36b08 attempt 1), each time with the same 17 Dynamic Type
        // findings on the hub's own category titles and subtitles. The hub was on screen, the
        // runner image was the same as on the passes, and the failing runs were the slow ones
        // (55 s and 63 s against 32–44 s). The audit was measuring text in mid-animation.
        //
        // So: wait for the card to be gone unconditionally, then for the unfolded row to stop
        // moving, then for an anchor below both the list and Discover to stop moving. That
        // anchor's position depends on the row being added above it and the card being removed
        // above it, so it settles only when the whole page has.
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
                      "Unfolding left the settings hub, so the audit would measure the pushed "
                      + "category screen rather than the list the card moved into")

        let pitch = app.staticTexts["Choose the model and give it a character."]
        XCTAssertTrue(pitch.waitForNonExistence(timeout: 10),
                      "The AI & Personality Discover card never left the page")

        // With the card gone, this query can only resolve to the unfolded row.
        awaitStableFrame(of: row, named: "The unfolded AI & Personality row")
        awaitStableFrame(of: app.switches["Show everything"],
                         named: "The Show everything switch below Discover")

        XCTAssertTrue(app.navigationBars["Settings"].exists,
                      "The settings hub was replaced while waiting for it to settle")

        audit(app, screen: "Settings hub — after unfolding a category",
              deferring: [.secondaryCopyContrast, .contentUnderTheTabBar(of: app)])
    }
}
