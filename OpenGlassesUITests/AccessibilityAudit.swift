import XCTest

// MARK: - Launch state

/// The launch arguments that put the app into a known state (see `UITestSupport` in the app
/// target). They seed persisted state and nothing else — no screen behaves differently under
/// them, and none of this compiles into a Release build.
enum LaunchState: String {
    case freshInstall = "-OGUITestFreshInstall"
    case configured = "-OGUITestConfigured"
    case showAllSettings = "-OGUITestShowAllSettings"
    case seedCaptions = "-OGUITestSeedCaptions"
}

// MARK: - Deferrals

/// An audit finding this phase is deliberately not failing on, with the reason it isn't.
///
/// Never a blanket ignore: a deferral names the audit types it covers, the surface it covers them
/// on, and where the work actually lives. Anything outside that still fails, so a *new* problem on
/// a deferred screen is still caught.
struct AuditDeferral {
    let types: XCUIAccessibilityAuditType
    let reason: String
    /// Extra narrowing beyond the audit type — used where only some elements on a screen are
    /// deferred. Defaults to "every element of these types on this screen".
    let matches: (XCUIAccessibilityAuditIssue) -> Bool

    init(
        types: XCUIAccessibilityAuditType,
        reason: String,
        matches: @escaping (XCUIAccessibilityAuditIssue) -> Bool = { _ in true }
    ) {
        self.types = types
        self.reason = reason
        self.matches = matches
    }

    /// The session surface's type scale, colour pairs and metrics are set by the design phase
    /// that owns that screen; DF P2 took the half that is independent of the restyle (what the
    /// controls are called and what they announce) and left the visual criteria there. The plan's
    /// own checklist records the same division.
    static let sessionSurfaceVisuals = AuditDeferral(
        types: [.contrast, .dynamicType, .textClipped],
        reason: "Session-surface type scale, colour pairs and metrics are owned by the design "
            + "phase that restyles this screen (DF P3 recorded the same division). Semantics — "
            + "labels, values, traits, hit regions — are audited here and are not deferred."
    )

    /// The captions overlay's ground: history rows and translation legs sit directly on whatever
    /// is behind the overlay, so their contrast is unmeasurable rather than merely thin. Adding a
    /// scrim is a layout decision that belongs to the phase restyling this surface — and so does
    /// the ~20pt speaker chip, whose 44pt floor would reflow the caption stack.
    static let captionsOverlayGround = AuditDeferral(
        types: [.contrast, .hitRegion],
        reason: "Captions overlay contrast and the speaker chip's target need a scrim and a "
            + "reflow of the caption stack — both layout decisions owned by the phase that "
            + "restyles the session surface."
    )

    /// The status card's connection pills are drawn as ~33×25 capsules. Their accessibility
    /// element now *is* the capsule (it used to be the 13pt glyph inside it), but the drawn
    /// control is still under 44pt, and growing it pushes the card's footer row apart — a metric
    /// on the surface the design phase restyles.
    static let sessionSurfaceTargets = AuditDeferral(
        types: .hitRegion,
        reason: "Status-card connection pills are drawn at about 33×25; a 44pt floor grows the "
            + "card's footer row, which is a session-surface metric owned by the phase that "
            + "restyles it. Their accessibility element covers the drawn pill as of this phase."
    )

    /// Stock `Form` section headers and footers, rendered by the system in its own secondary
    /// grey, sitting on the OGDesign canvas rather than the system grouped background. Correcting
    /// them means styling every section header in the app — a component-level decision recorded
    /// in the plan rather than taken here.
    static let systemFormChrome = AuditDeferral(
        types: [.contrast, .dynamicType],
        reason: "System-rendered Form section headers/footers on the OGDesign canvas measure "
            + "under AA in the system's own secondary grey. Fixing it is an app-wide Form "
            + "styling change; catalogued in the plan for the phase that owns it."
    )

    /// `OGRow`'s subtitle and the quiet button style both use the system `.secondary` label at
    /// footnote size, which the audit reports as *nearly* passing — over AA for large text, under
    /// it for body text. An audited token for secondary copy would touch every screen in the app.
    static let secondaryCopyContrast = AuditDeferral(
        types: .contrast,
        reason: "System `.secondary` at footnote/subheadline size clears AA only as large text. "
            + "An audited secondary-copy token is an app-wide change; catalogued in the plan."
    )

    /// The hero card's capability chips are drawn in `caption2`, the smallest text style, whose
    /// scaling the system caps below the top of the accessibility range — so the audit reports
    /// them as only partially supporting Dynamic Type at *every* size. At AX5 there is a second
    /// problem on top: three chips cannot sit side by side, so each is squeezed into a narrow
    /// column. Both fixes are design decisions on a shipped component — a larger text style, and
    /// a chip row that wraps.
    static let heroCardChipRow = AuditDeferral(
        types: .dynamicType,
        reason: "The hero device card's chips use `caption2`, whose scaling the system caps "
            + "below the top of the accessibility range, and the row does not wrap. Both are "
            + "design changes to a shipped component; catalogued in the plan."
    )

    /// The tab bar is translucent, so an element scrolled underneath it is composited against a
    /// blur of itself. The audit samples the composited pixels and reports a contrast failure on
    /// text that is fully legible where the user actually reads it — `.primary` label copy, which
    /// cannot fail against the canvas. Scoped to the bottom strip by frame, so a genuine contrast
    /// failure anywhere else on the same screen still fails the test.
    static func contentUnderTheTabBar(of app: XCUIApplication) -> AuditDeferral {
        let screen = app.frame
        return AuditDeferral(
            types: .contrast,
            reason: "Element scrolled under the translucent tab bar; the audit measures the "
                + "composited pixels, not the colours the design specifies.",
            matches: { issue in
                guard let frame = issue.element?.frame else { return false }
                return frame.maxY > screen.maxY - 120
            }
        )
    }

    /// Onboarding is drawn *over* the tab view. Since this phase the tabs are
    /// `.accessibilityHidden` while it is up, so VoiceOver no longer walks into them — but the
    /// audit reads the **render** tree, not the VoiceOver tree, so it still measures a session
    /// surface that is behind a full-screen cover. Which is, in passing, why the bug survived
    /// three phases: the tool that would have caught it and the tool that reports it are looking
    /// at different trees.
    ///
    /// The findings themselves are the session surface's own — its type scale and its targets —
    /// and are deferred to the same phase, and audited for real on the Voice tab.
    static let appBehindTheOverlay = AuditDeferral(
        types: [.contrast, .dynamicType, .textClipped, .hitRegion],
        reason: "Session-surface elements rendered behind the full-screen onboarding cover. "
            + "They are hidden from VoiceOver as of this phase; the audit walks the render tree "
            + "and still sees them. Their own criteria are audited on the Voice tab and owned by "
            + "the phase that restyles that surface."
    )

    /// A one-line text field is a one-line text field. At accessibility sizes iOS scrolls the
    /// text inside it rather than growing the row, and the same is true of a `Picker`'s selected
    /// value in a `Form` — so the audit reports both as text that may clip, on every such row in
    /// the app, whatever the app does. Nothing here is the app's to fix; a multi-line API-key
    /// field would be a worse field.
    static let singleLineTextEntry = AuditDeferral(
        types: .textClipped,
        reason: "Single-line text entry and system picker values scroll rather than wrap at "
            + "accessibility sizes — platform behaviour for text fields, not an app decision."
    )

    /// An `OGRow` is a title, a subtitle and a value competing for one width, and at larger sizes
    /// they cannot all have it. Removing the value's line cap was tried here and rejected: the
    /// value's second line comes straight out of the subtitle, and then out of the title, so the
    /// audit reports a different clipped string rather than none. Which of the three yields —
    /// or whether the value belongs under the title instead of beside it — is a layout decision
    /// for the phase that owns this component, and is catalogued in the plan.
    static let rowValueWidth = AuditDeferral(
        types: .textClipped,
        reason: "`OGRow`'s title, subtitle and value share one width and cannot all keep it at "
            + "larger sizes. Rebalancing them is a layout change to a shipped component; "
            + "catalogued in the plan."
    )

    /// The onboarding page indicator: three-to-seven 4pt capsules. It is decoration and hidden
    /// from VoiceOver — where in the flow the user is rides on the page title's value — but it is
    /// still a node in the render tree the audit walks, and 4pt of drawn dots will never be a
    /// 44pt target. Growing it means growing the header on a screen whose look another plan owns,
    /// and at AX5 that is height taken directly off the hero the same phase is trying to fit.
    static let decorativePageIndicator = AuditDeferral(
        types: [.hitRegion, .sufficientElementDescription],
        reason: "The onboarding page dots are 4pt of decoration, hidden from VoiceOver, with the "
            + "page position moved onto the page title's value. They are not a control and have "
            + "no target to grow."
    )
}

// MARK: - Base case

/// Shared machinery for every audit in this target.
///
/// The gate is `XCUIApplication.performAccessibilityAudit()`: the same checks Xcode's Accessibility
/// Inspector runs, driven from a test so they run again on every change. It is not a substitute for
/// a person using the app with VoiceOver — it cannot judge whether a label reads *well* — but it
/// does catch the failures that regress silently: an unlabeled control, a missing trait, text that
/// clips at large sizes, a target under 44pt, a colour pair under AA.
class AccessibilityAuditCase: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: Launch

    /// Launch the app in a known state, and wait out the launch screen.
    ///
    /// - Parameter contentSizeCategory: a `UICTContentSizeCategory*` name to run the app at. The
    ///   AX5 sweep uses this; everything else runs at the system default.
    @discardableResult
    func launch(
        _ states: [LaunchState],
        contentSizeCategory: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-OGUITest"] + states.map(\.rawValue)
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        if let contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory]
        }
        app.launch()
        waitForLaunchScreenToClear(app)
        relaunchIfTheUINeverCameUp(app)
        return app
    }

    /// The first launch in a run installs a large Debug build and starts it cold, and that launch
    /// occasionally produces a process with no UI in it — the app is "running" and its tree is
    /// empty. Every launch after it in the same run comes up in a couple of seconds. Rather than
    /// let the first case of every run fail for a reason that has nothing to do with
    /// accessibility, give it one clean restart before believing it.
    private func relaunchIfTheUINeverCameUp(_ app: XCUIApplication) {
        guard !app.buttons.firstMatch.waitForExistence(timeout: 45) else { return }
        app.terminate()
        app.launch()
        waitForLaunchScreenToClear(app)
    }

    /// The launch screen covers the app for two seconds and would otherwise be what the first
    /// audit of a run measured.
    private func waitForLaunchScreenToClear(_ app: XCUIApplication) {
        let splash = app.staticTexts["Voice-Powered AI Assistant"]
        // It may already be gone by the time the query runs — only wait if it is up.
        if splash.waitForExistence(timeout: 5) {
            let gone = expectation(for: NSPredicate(format: "exists == false"),
                                   evaluatedWith: splash)
            wait(for: [gone], timeout: 20)
        }
    }

    // MARK: Audit

    /// Run the audit over whatever is on screen, failing on anything not explicitly deferred.
    ///
    /// - Parameters:
    ///   - screen: what is being audited, for the failure message and the activity name.
    ///   - deferrals: findings this phase is not failing on, each carrying its reason.
    ///   - types: the audit types to run. Defaults to everything.
    func audit(
        _ app: XCUIApplication,
        screen: String,
        deferring deferrals: [AuditDeferral] = [],
        types: XCUIAccessibilityAuditType = .all,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTContext.runActivity(named: "Accessibility audit — \(screen)") { activity in
            var failures: [String] = []
            var deferred: [String] = []

            do {
                try app.performAccessibilityAudit(for: types) { issue in
                    if let deferral = deferrals.first(where: {
                        $0.types.contains(issue.auditType) && $0.matches(issue)
                    }) {
                        deferred.append(Self.describe(issue, note: "deferred — \(deferral.reason)"))
                        return true
                    }
                    failures.append(Self.describe(issue))
                    return true  // collected and reported below, so one run lists every issue
                }
            } catch {
                XCTFail("\(screen): the audit itself failed to run — \(error)",
                        file: file, line: line)
                return
            }

            if !deferred.isEmpty {
                let text = deferred.joined(separator: "\n\n")
                activity.add(XCTAttachment(string: text))
                // Deferrals are printed, not silent: a filtered finding that nobody can see is a
                // blanket ignore wearing a comment.
                print("[a11y-audit] \(screen): \(deferred.count) deferred finding(s)\n\(text)")
            }

            if !failures.isEmpty {
                let text = failures.joined(separator: "\n\n")
                activity.add(XCTAttachment(string: text))
                XCTFail("""
                    \(screen): \(failures.count) accessibility audit issue(s).

                    \(text)
                    """, file: file, line: line)
            }
        }
    }

    private static func describe(_ issue: XCUIAccessibilityAuditIssue, note: String? = nil) -> String {
        // The first line of an element's debug description is the one that identifies it — type,
        // frame, label. The rest is the subtree and the path, which buries the finding.
        let element = issue.element
            .map { "\n  element: \($0.debugDescription.split(separator: "\n").first ?? "")" } ?? ""
        let suffix = note.map { "\n  note: \($0)" } ?? ""
        return """
            • [\(name(for: issue.auditType))] \(issue.compactDescription)
              \(issue.detailedDescription)\(element)\(suffix)
            """
    }

    private static func name(for type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .contrast: return "contrast"
        case .elementDetection: return "elementDetection"
        case .hitRegion: return "hitRegion"
        case .sufficientElementDescription: return "sufficientElementDescription"
        case .dynamicType: return "dynamicType"
        case .textClipped: return "textClipped"
        case .trait: return "trait"
        default: return "audit(\(type.rawValue))"
        }
    }

    // MARK: Navigation helpers

    /// The tab bar's four destinations, by their spoken names.
    func openTab(_ name: String, in app: XCUIApplication,
                 file: StaticString = #filePath, line: UInt = #line) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 60),
                      "The \(name) tab never appeared", file: file, line: line)
        tab.tap()
    }

    /// Tap the first element whose spoken label starts with `prefix` — how the OGDesign rows are
    /// addressed, since a value row combines title, subtitle and value into one label.
    @discardableResult
    func tapRow(startingWith prefix: String, in app: XCUIApplication,
                file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60),
                      "No element labelled “\(prefix)…” on screen", file: file, line: line)
        row.tap()
        return row
    }

    /// Wait for a screen to settle on a marker element before auditing it.
    ///
    /// The timeout is generous on purpose. The first case in a run installs a large app and
    /// launches it cold, and at accessibility text sizes the first layout pass is not cheap — a
    /// 20s ceiling failed there while every later case cleared it in two. A regression gate that
    /// cries wolf on the first case of every run is a gate people learn to ignore.
    func awaitScreen(_ element: XCUIElement, named name: String, timeout: TimeInterval = 60,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "\(name) never appeared", file: file, line: line)
    }
}
