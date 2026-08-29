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

        audit(app, screen: "Settings hub — after unfolding a category",
              deferring: [.secondaryCopyContrast, .contentUnderTheTabBar(of: app)])
    }
}
