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
    case seedConversations = "-OGUITestSeedConversations"
    case reinstall = "-OGUITestReinstall"
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

    // The three session-surface deferrals this file used to carry — the surface's type scale and
    // colour pairs, the status card's ~33×25 connection pills, and the captions overlay's missing
    // ground plus its ~20pt speaker chip — are **gone rather than relaxed**. The phase they were
    // waiting for restyled that surface: the pills and the chip carry real 44pt targets around
    // their drawn artwork, the caption stack has an opaque media panel under it, and every colour on
    // the screen reads from an audited token. `SessionSurfaceAccessibilityTests` now runs Dynamic
    // Type, clipping, hit regions, traits and descriptions there unfiltered; contrast is the one
    // check that still needs a filter, for a reason that is about the tool — see
    // `contrastThroughGlass`.

    /// Contrast measured *through* Liquid Glass.
    ///
    /// The session surface is the one screen in the app built out of translucent chrome: the
    /// control dock, the hero capsule, the status card and its connection pills are all
    /// `glassEffect`. The audit reports text on them as failing contrast, and the rendered pixels
    /// say otherwise — measured rather than argued, by sampling the screenshot the simulator
    /// produces: the capsule's label ("Connect & Talk", `Color(.label)` on the capsule's glass)
    /// comes out at **20.5:1**, black on near-white.
    ///
    /// The mechanism is visible in what else trips it. A 0.8-alpha caption panel tripped it too,
    /// on a stack whose pixels measure 8.8–11.5:1, and went away when the panel became opaque —
    /// so the check is reading the *declared* background rather than the composite, and any
    /// translucent ground looks like no ground at all to it. It is the same property DF P4
    /// recorded for content scrolled under the translucent tab bar, and the reason that deferral
    /// exists too.
    ///
    /// Deliberately narrow. It covers `.contrast` on this surface and nothing else: Dynamic Type,
    /// clipping, hit regions, traits and descriptions all stay live here, which is where a real
    /// regression on this screen shows up. And the colour work itself is asserted twice over
    /// without this audit — every pair the palette paints is walked by `OGDesignContrastTests` in
    /// both schemes, and after DG P4 nothing on this surface is hand-painted, so there is no
    /// colour here that the headless suite does not already measure.
    static let contrastThroughGlass = AuditDeferral(
        types: .contrast,
        reason: "Text on the session surface's Liquid Glass chrome. The audit samples the declared "
            + "background rather than the composite, so any translucent ground reads as no ground: "
            + "the capsule's label measures 20.5:1 in the rendered pixels. Every other audit type "
            + "stays live on this screen, and the palette's own pairs are asserted headlessly."
    )

    /// A caption in the history is *readable text made focusable*, not a control.
    ///
    /// DF P2 decided this surface is a swipeable history rather than a live region, which means
    /// each past line is its own accessibility element so a VoiceOver user can go back through
    /// what was said. The audit sees an element and asks whether a finger could hit it — but there
    /// is nothing to hit: the line has no action, and the 44pt floor is a *pointer-target*
    /// criterion. Growing every caption row to 44pt would push the stack apart to satisfy a check
    /// on something that is not a target.
    ///
    /// Scoped to non-buttons for exactly that reason, and it is a real scope rather than a
    /// formality: the speaker chip beside these lines *is* a button, it is the control this phase
    /// grew to 44pt, and it still fails this audit if it ever shrinks back.
    static let focusableCaptionHistory = AuditDeferral(
        types: .hitRegion,
        reason: "A caption-history line is focusable text, not a control — it has no action, so "
            + "the 44pt pointer-target floor does not apply to it. Scoped to non-button elements, "
            + "so the speaker chip beside it is still held to the floor.",
        matches: { $0.element?.elementType != .button }
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
    /// This one survives the session-surface restyle, and for a reason that has nothing to do with
    /// the surface's own quality: contrast measured *through* a full-screen cover is contrast
    /// against the wrong ground. The elements behind onboarding are now audited properly on the
    /// Voice tab — which is the right place to measure them, and the reason this stays scoped to
    /// the cover rather than being widened.
    static let appBehindTheOverlay = AuditDeferral(
        types: [.contrast, .dynamicType, .textClipped, .hitRegion],
        reason: "Session-surface elements rendered behind the full-screen onboarding cover. They "
            + "are hidden from VoiceOver; the audit walks the render tree and still sees them, "
            + "compositing them against onboarding rather than against their own screen. Audited "
            + "for real, and undeferred, on the Voice tab."
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

    // `OGRow`'s value width was the fourth deferral here, and it is gone too. The three strings
    // were only competing because they were asked to share one line: above the accessibility
    // threshold the value now sits *under* the title with the row's full width and no line cap,
    // and below it the shipped side-by-side row is untouched. The settings audits no longer
    // filter it.

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
            var attempt = 1

            while true {
                do {
                    try app.performAccessibilityAudit(for: types) { issue in
                        if let deferral = deferrals.first(where: {
                            $0.types.contains(issue.auditType) && $0.matches(issue)
                        }) {
                            deferred.append(Self.describe(issue, note: "deferred — \(deferral.reason)"))
                            return true
                        }
                        failures.append(Self.describe(issue))
                        return true
                    }
                    break
                } catch where attempt == 1 && Self.isAuditTimeout(error) {
                    // Xcode's audit service occasionally times out before returning any findings
                    // on a cold, loaded CI simulator. Retry that infrastructure error once; an
                    // actual finding is delivered through the handler above and is never retried
                    // or filtered here. Clear partial output in case the service emitted anything
                    // before timing out, then ask it for one clean result.
                    print("[a11y-audit] \(screen): audit service timed out; retrying once")
                    failures.removeAll(keepingCapacity: true)
                    deferred.removeAll(keepingCapacity: true)
                    attempt += 1
                    app.activate()
                } catch {
                    XCTFail("\(screen): the audit itself failed to run — \(error)",
                            file: file, line: line)
                    return
                }
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

    /// The audit service has no public error constants, but its timeout is stable as Cocoa-style
    /// domain/code metadata. Keep the match exact so invalid targets, crashes, and every other
    /// infrastructure problem still fail on the first attempt.
    private static func isAuditTimeout(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "com.apple.xcode.xctest.accessibilityAudit" && error.code == -56
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
