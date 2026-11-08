import XCTest

/// All content is invented and served by the same public fixture files as the core tests.
/// Screenshots are review artifacts; no customer account, key, email or API write is involved.
class WorkizAccessibilityCase: AccessibilityAuditCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = true // Collect every screen's findings in the same fixture walk.
        // Each case walks a fixture and audits several screens, so the 300 s per-test default is
        // too tight: on CI the AX5 dark testConnectionStates took 268 s, then 302 s, and was
        // stopped at the limit with every audit passed (run 42351988351).
        executionTimeAllowance = 600
    }
    private static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"
    private func launchWorkiz(_ state: String, dark: Bool, large: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-OGUITest", "-OGUITestConfigured", "-OGUITestFieldAssist", "-UITestWorkizFixture", "-UITestWorkizState", state, "-ApplePersistenceIgnoreState", "YES"]
        if dark { app.launchArguments += ["-OGUITestDarkAppearance"] }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", Self.ax5] }
        // Attach before termination so a simulator process left by another runner is killed too.
        app.activate(); app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["Jobs"].waitForExistence(timeout: 60))
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = app.screenshot()
        let attachment = XCTAttachment(screenshot: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["OG_SHOT_DIR"] {
            let folder = URL(fileURLWithPath: directory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? image.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
        }
        var deferrals: [AuditDeferral] = [.secondaryCopyContrast, .systemFormChrome, .contentUnderTheTabBar(of: app)]
        if name.hasSuffix("-default"), name.hasPrefix("jr-technician-") || name.hasPrefix("jr-writeback-") {
            // The default-size audit predicts clipping on native Form controls even after their
            // labels wrap. The same controls are audited WITHOUT this deferral at AX5, and the
            // jr-writeback-*-ax5 screenshots show both time-zone and remove-key text in full.
            // Keep this limited to those predictions; a labelled text node still fails normally.
            deferrals.append(AuditDeferral(types: .textClipped,
                reason: "Native Form control prediction at default size; verified by the unfiltered AX5 walk and screenshots.",
                matches: { $0.element == nil || $0.element?.identifier == "workiz.remove" }))
        }
        if name.hasPrefix("jr-jobs-offline-") || name.hasPrefix("jr-assigned-jobs-") {
            // The search field's placeholder ("Search by job number, customer or ma…") is the one
            // clipped text on these screens. The audit usually names the field, and occasionally
            // reports the same prediction with no element: run 42462704177 failed
            // jr-assigned-jobs-dark-default on an unattributed textClipped while its screenshot
            // showed every job row in full, and the screen passed on the rerun. A job row is an
            // element, so its clipping is never unattributed and still fails.
            deferrals.append(AuditDeferral(types: .textClipped,
                reason: "The existing UIKit search field scrolls its single-line text; job-row clipping remains checked.",
                matches: { $0.element == nil || $0.detailedDescription.contains("UISearchBarTextField") }))
        }
        if name.hasPrefix("jr-started-") {
            deferrals.append(AuditDeferral(types: .textClipped,
                reason: "The existing job-number text entry scrolls on one line; other started-job text remains checked.",
                matches: { $0.element?.elementType == .textField || $0.detailedDescription.contains("SwiftUI.UIKitTextField") }))
        }
        audit(app, screen: name, deferring: deferrals)
    }
    private func visible(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<18 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists)
    }
    func settings(_ state: String, dark: Bool, large: Bool) {
        let app = launchWorkiz(state, dark: dark, large: large)
        let row = app.buttons["workiz.settings"]
        for _ in 0..<3 {
            openTab("Settings", in: app)
            if app.navigationBars["Settings"].waitForExistence(timeout: 3) { break }
        }
        let field = app.scrollViews.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Field Assist' AND label != 'Field Assist settings'")).firstMatch
        visible(field, in: app); field.tap()
        XCTAssertTrue(app.navigationBars["Field Assist"].waitForExistence(timeout: 30))
        visible(row, in: app); row.tap()
        XCTAssertTrue(app.navigationBars["Workiz"].waitForExistence(timeout: 30))
        let suffix = "\(dark ? "dark" : "light")-\(large ? "ax5" : "default")"
        if state != "empty" {
            let test = app.buttons["workiz.test"]; visible(test, in: app)
            if test.isEnabled { test.tap() }
            if state != "testing" {
                let finished = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: test)
                wait(for: [finished], timeout: 30)
            }
        }
        if state == "empty" {
            visible(app.secureTextFields["workiz.key"], in: app)
        } else if state != "testing" {
            visible(app.staticTexts["workiz.message"], in: app)
        }
        capture(app, "jr-settings-\(state)-\(suffix)")
        if state == "connected" {
            let person = app.buttons["workiz.user.USR-jamie"]
            visible(person, in: app)
            capture(app, "jr-technician-\(suffix)")
            visible(app.buttons["workiz.remove"], in: app)
            capture(app, "jr-writeback-\(suffix)")
            app.terminate()
            let offline = launchWorkiz("offline", dark: dark, large: large)
            openTab("Jobs", in: offline)
            XCTAssertTrue(offline.navigationBars["Jobs"].waitForExistence(timeout: 60))
            capture(offline, "jr-jobs-offline-\(suffix)")
            let job = offline.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Job 1234'")).firstMatch
            visible(job, in: offline)
            capture(offline, "jr-assigned-jobs-\(suffix)")
            job.tap()
            XCTAssertTrue(offline.navigationBars["Job 1234"].waitForExistence(timeout: 30))
            capture(offline, "jr-brief-\(suffix)")
            let call = offline.descendants(matching: .any).matching(identifier: "workiz.callCustomer").firstMatch
            visible(call, in: offline)
            capture(offline, "jr-contact-\(suffix)")
        }
    }
    func visits(dark: Bool, large: Bool) {
        for state in ["started", "closed-sent", "closed-waiting", "closed-attention"] {
            let app = launchWorkiz(state, dark: dark, large: large)
            openTab("Jobs", in: app)
            let job = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Job 1234'")).firstMatch
            visible(job, in: app); job.tap()
            if state.hasPrefix("closed") {
                XCTAssertTrue(app.staticTexts["workiz.delivery"].waitForExistence(timeout: 60))
                awaitStableFrame(of: app.staticTexts["workiz.delivery"], named: "Workiz delivery status")
            } else {
                awaitStableFrame(of: app.textFields["Job number"], named: "Started job")
            }
            capture(app, "jr-\(state)-\(dark ? "dark" : "light")-\(large ? "ax5" : "default")")
        }
    }
}

final class WorkizLightAccessibilityTests: WorkizAccessibilityCase {
    func testConnectionAndOfflineJobs() { settings("connected", dark: false, large: false) }
    func testConnectionStates() {
        for state in ["empty", "wrong-key", "permission", "testing"] { settings(state, dark: false, large: false) }
    }
    func testVisitStates() { visits(dark: false, large: false) }
}

final class WorkizDarkAccessibilityTests: WorkizAccessibilityCase {
    func testConnectionAndOfflineJobs() { settings("connected", dark: true, large: false) }
    func testConnectionStates() {
        for state in ["empty", "wrong-key", "permission", "testing"] { settings(state, dark: true, large: false) }
    }
    func testVisitStates() { visits(dark: true, large: false) }
}

final class WorkizLargestLightAccessibilityTests: WorkizAccessibilityCase {
    func testConnectionAndOfflineJobs() { settings("connected", dark: false, large: true) }
    func testConnectionStates() {
        for state in ["empty", "wrong-key", "permission", "testing"] { settings(state, dark: false, large: true) }
    }
    func testVisitStates() { visits(dark: false, large: true) }
}

final class WorkizLargestDarkAccessibilityTests: WorkizAccessibilityCase {
    func testConnectionAndOfflineJobs() { settings("connected", dark: true, large: true) }
    func testConnectionStates() {
        for state in ["empty", "wrong-key", "permission", "testing"] { settings(state, dark: true, large: true) }
    }
    func testVisitStates() { visits(dark: true, large: true) }
}
