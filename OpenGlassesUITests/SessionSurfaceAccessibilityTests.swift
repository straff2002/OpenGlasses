import XCTest

/// The main session surface and the captions overlay that sits on it (Plan DF P4, completed by
/// DG P4).
///
/// Ranks 2, 3 and 6 on the plan's checklist. This file used to gate only the half DF P2 landed —
/// names, values, traits — because the surface's type scale, colour pairs and metrics were the
/// design phase's to set. They are set, and the four deferrals that stood in for them are deleted.
///
/// What is left here is two filters, and neither is about the surface's quality: the audit cannot
/// measure contrast through translucent chrome (`contrastThroughGlass`, with the pixel
/// measurements that settle it), and it asks a pointer-target question of focusable text
/// (`focusableCaptionHistory`, scoped to non-buttons so the speaker chip is still held to the
/// floor). Dynamic Type, clipping, hit regions, traits and descriptions run unfiltered on the
/// busiest screen in the app.
final class SessionSurfaceAccessibilityTests: AccessibilityAuditCase {

    func testVoiceTabPassesAccessibilityAudit() {
        let app = launch([.configured])
        awaitScreen(app.tabBars.buttons["Voice"], named: "The tab bar")
        audit(app, screen: "Session surface — Voice tab",
              deferring: [.contrastThroughGlass])
    }

    func testTabBarDestinationsAreNamed() {
        let app = launch([.configured])
        awaitScreen(app.tabBars.buttons["Voice"], named: "The tab bar")

        for name in ["Voice", "Modes", "Chat", "Settings"] {
            XCTAssertTrue(app.tabBars.buttons[name].exists, "The \(name) tab is not named")
        }
    }

    /// The hero capsule's visible copy is an instruction to a finger — "Tap to talk", "Tap to
    /// stop" — which is the wrong gesture and the wrong grammar for VoiceOver. P2 gave it a spoken
    /// name instead; this fails if that name is ever dropped back to the drawn copy.
    func testSessionCapsuleDoesNotSpeakItsDrawnTapCopy() {
        let app = launch([.configured])
        awaitScreen(app.tabBars.buttons["Voice"], named: "The tab bar")

        for drawnCopy in ["Tap to talk", "Tap to stop"] {
            XCTAssertFalse(
                app.buttons[drawnCopy].exists,
                "The session capsule reaches VoiceOver as “\(drawnCopy)” — the drawn instruction, "
                + "not a spoken name. Its `spokenLabel` has been lost."
            )
        }

        // On a simulator with no glasses paired the capsule is in its disconnected state; the
        // spoken name is what the button is called either way.
        let capsule = app.buttons.matching(
            NSPredicate(format: "label IN %@",
                        ["Connect & Talk", "Start talking", "End voice session",
                         "Stop speaking", "Cancel"])
        ).firstMatch
        XCTAssertTrue(capsule.waitForExistence(timeout: 60),
                      "The session capsule is not reachable by any of its spoken names")
    }

    /// The quick-action grid that replaced the dock's scrolling band of prompts. Each tile is a
    /// named button, including the ones whose drawn caption is an arrow — a tile that reaches
    /// VoiceOver as its glyph name is a tile nobody can find.
    func testQuickActionGridTilesAreNamedButtons() {
        let app = launch([.configured])
        awaitScreen(app.tabBars.buttons["Voice"], named: "The tab bar")

        for name in ["Meetings", "Tasks", "Photo → Event", "Photo → Task"] {
            XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 60),
                          "The “\(name)” tile is not reachable by name on the home grid")
        }

        // The speed-dial actions the dock used to draw are still on the surface, and the live
        // recording tile still says what it is rather than reading out a duration.
        XCTAssertTrue(app.buttons["Record meeting"].exists,
                      "The record tile lost its spoken name in the move off the dock")
    }

    /// Rank 6: the captions overlay, seeded with the history and live line a real session would
    /// have produced — two of them diarized, so the speaker chip is on screen to be measured. Its
    /// ground and its chip's target were the two findings this surface carried; both are fixed —
    /// the panel is opaque now, and the chip has a real 44pt target.
    func testCaptionsOverlayPassesAccessibilityAudit() {
        let app = launch([.configured, .seedCaptions])
        awaitScreen(app.tabBars.buttons["Voice"], named: "The tab bar")

        let liveLine = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Now: '")).firstMatch
        XCTAssertTrue(liveLine.waitForExistence(timeout: 60),
                      "The live caption line does not name itself as the current line")

        XCTAssertFalse(
            app.staticTexts["Put what matters next here instead of an animation."].exists,
            "My Day is still occupying the conversation zone while live captions need its height"
        )

        XCTAssertFalse(
            app.buttons["Meetings"].exists,
            "The quick-action grid is still occupying the conversation zone while live captions "
            + "need its height"
        )

        audit(app, screen: "Session surface — captions overlay",
              deferring: [.contrastThroughGlass, .focusableCaptionHistory])
    }

    /// The speaker chip is the control the plan deferred twice for being about 20pt. It is on
    /// screen whenever a caption is diarized, and it is now a real target — which is only true
    /// while the seeded history actually carries a speaker, so this asserts the chip is there at
    /// all. Without it the audit above would pass by measuring a control that never rendered.
    func testTheSpeakerChipIsOnScreenToBeAudited() {
        let app = launch([.configured, .seedCaptions])
        awaitScreen(app.tabBars.buttons["Voice"], named: "The tab bar")

        let chip = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Speaker '")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 60),
                      "No speaker chip in the caption stack — the diarized seed has been lost, "
                      + "and with it the only coverage of that control's touch target")
    }

    /// Captions are speech that already happened in the room, so the history has to be swipeable
    /// rather than pushed — which means each past line is its own element, not one blob.
    func testCaptionHistoryLinesAreIndividuallyFocusable() {
        let app = launch([.configured, .seedCaptions])
        awaitScreen(app.tabBars.buttons["Voice"], named: "The tab bar")

        let aHistoryLine = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@",
                                  "We should be there by about half past.")).firstMatch
        XCTAssertTrue(aHistoryLine.waitForExistence(timeout: 60),
                      "A caption from the history is not reachable on its own — the overlay has "
                      + "collapsed into a single element, and the last few lines cannot be "
                      + "swiped back through")
    }
}
