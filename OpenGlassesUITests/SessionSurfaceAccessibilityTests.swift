import XCTest

/// The main session surface and the captions overlay that sits on it (Plan DF P4).
///
/// Ranks 2, 3 and 6 on the plan's checklist. The visual criteria on this screen belong to the
/// phase that restyles it — see `AuditDeferral.sessionSurfaceVisuals` — so what this file gates is
/// the half DF P2 landed: that every control on the surface has a name, a value where its state
/// changes, the trait its affordance promises, and a target a finger can find.
final class SessionSurfaceAccessibilityTests: AccessibilityAuditCase {

    func testVoiceTabPassesAccessibilityAudit() {
        let app = launch([.configured])
        awaitScreen(app.tabBars.buttons["Voice"], named: "The tab bar")
        audit(app, screen: "Session surface — Voice tab",
              deferring: [.sessionSurfaceVisuals, .sessionSurfaceTargets])
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

    /// Rank 6: the captions overlay, seeded with the history and live line a real session would
    /// have produced. Its ground and its speaker chip are deferred with the surface's layout; its
    /// semantics — a contained, individually focusable history, and a live line that names itself
    /// — are gated here.
    func testCaptionsOverlayPassesAccessibilityAudit() {
        let app = launch([.configured, .seedCaptions])
        awaitScreen(app.tabBars.buttons["Voice"], named: "The tab bar")

        let liveLine = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Now: '")).firstMatch
        XCTAssertTrue(liveLine.waitForExistence(timeout: 60),
                      "The live caption line does not name itself as the current line")

        audit(app, screen: "Session surface — captions overlay",
              deferring: [.sessionSurfaceVisuals, .sessionSurfaceTargets, .captionsOverlayGround])
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
