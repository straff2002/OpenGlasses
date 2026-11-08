import XCTest

/// Rotation must reflow the existing conversation and action arrangement, not create a new one.
final class AdaptiveWorkspaceUITests: AccessibilityAuditCase {
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testPersonalWorkspaceStartsWithConversationAndCanShowMyDay() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch([.configured, .seedConversations, .seedMyDay])
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForOrientation(app, landscape: true)

        let context = app.otherElements["adaptive-workspace-context"]
        let conversation = context.otherElements["adaptive-workspace-conversation"]
        awaitScreen(conversation, named: "Personal conversation")
        XCTAssertTrue(context.buttons["Conversation"].isSelected)
        XCTAssertFalse(context.buttons["Job"].exists)
        XCTAssertFalse(context.buttons["Reference"].exists)
        XCTAssertFalse(context.buttons["Evidence"].exists)
        XCTAssertFalse(context.buttons["adaptive-workspace-open-job"].exists)

        tap(context.buttons["My Day"], until: context.scrollViews["adaptive-workspace-my-day"],
            named: "Personal My Day")
        XCTAssertTrue(context.buttons["My Day"].isSelected)

        tap(context.buttons["Conversation"], until: conversation,
            named: "Return to personal conversation")
        XCTAssertTrue(context.buttons["Conversation"].isSelected)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "adaptive-personal-conversation-and-my-day"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTurningFieldAssistOffKeepsTheOpenJobOutOfThePersonalWorkspace() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch([.configured, .seedFieldJob, .seedFieldPhotos, .seedConversations])
        openTab("Jobs", in: app)
        let jobRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Job 1005,")).firstMatch
        awaitScreen(jobRow, named: "The unfinished job row")
        jobRow.tap()
        awaitScreen(app.textFields["Job number"], named: "Seeded unfinished job")
        let recordedReference = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", "Job number 1005. Tap to change it.")).firstMatch
        awaitScreen(recordedReference, named: "The job's recorded reference before switching off")

        openTab("Settings", in: app)
        let row = app.scrollViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Field Assist")).firstMatch
        for _ in 0..<8 {
            if row.exists && row.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(row.exists && row.isHittable, "Field Assist settings is unreachable")
        row.tap()
        let enabled = app.switches["Enable Field Assist"]
        awaitScreen(enabled, named: "Field Assist switch")
        XCTAssertEqual(enabled.value as? String, "1")
        enabled.switches.firstMatch.tap()
        XCTAssertEqual(enabled.value as? String, "0")

        openTab("Avenkin", in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForOrientation(app, landscape: true)
        let context = app.otherElements["adaptive-workspace-context"]
        awaitScreen(context.otherElements["adaptive-workspace-conversation"], named: "Personal workspace after switching off")
        XCTAssertFalse(context.buttons["Job"].exists)
        XCTAssertFalse(context.buttons["Reference"].exists)
        XCTAssertFalse(context.buttons["Evidence"].exists)

        let openJob = context.buttons["adaptive-workspace-open-job"]
        awaitScreen(openJob, named: "Unfinished job recovery")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "adaptive-personal-with-unfinished-job"
        attachment.lifetime = .keepAlways
        add(attachment)
        openJob.tap()
        awaitScreen(app.textFields["Job number"], named: "The unfinished job is still accessible")
        awaitScreen(recordedReference, named: "The same recorded job reference after recovery")
    }

    func testRotationPreservesTheDockPageAndConversation() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch([.configured, .seedConversations])
        // The panel opens on its conversation page while things to try are waiting there, so the
        // page the wearer picks is the actions; rotation must keep it.
        showTheDockActions(in: app)
        let onActions = app.buttons["Show conversation"]

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForOrientation(app, landscape: true)
        awaitScreen(app.otherElements["adaptive-workspace-context"], named: "Landscape context")
        XCTAssertTrue(onActions.waitForExistence(timeout: 10), "Rotation reset the selected dock page")
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "adaptive-conversation-landscape"
        landscape.lifetime = .keepAlways
        add(landscape)

        XCUIDevice.shared.orientation = .portrait
        waitForOrientation(app, landscape: false)
        XCTAssertTrue(onActions.waitForExistence(timeout: 10), "Returning to portrait reset the dock")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "adaptive-portrait"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFieldJobAndEvidenceStayBesideTheVoiceControls() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch([.configured, .fieldAssist, .seedFieldJob, .seedFieldPhotos])
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForOrientation(app, landscape: true)
        awaitScreen(app.otherElements["adaptive-workspace-context"], named: "Field Assist context")
        let context = app.otherElements["adaptive-workspace-context"]
        let number = context.textFields["Job number"]
        awaitScreen(number, named: "Job number in context")
        XCTAssertLessThanOrEqual(context.frame.maxX - number.frame.maxX, 64,
                                 "The job form reserves the outer navigation inset again inside its pane")
        let job = XCTAttachment(screenshot: app.screenshot())
        job.name = "adaptive-job-landscape"
        job.lifetime = .keepAlways
        add(job)
        let evidence = context.buttons["Evidence"]
        awaitScreen(evidence, named: "Evidence context control")
        evidence.tap()
        waitForEvidence(app)
        XCTAssertTrue(app.buttons["Show conversation"].exists || app.buttons["Show actions"].exists,
                      "Opening evidence removed the voice dock")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "adaptive-field-landscape"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCUIDevice.shared.orientation = .portrait
        waitForOrientation(app, landscape: false)
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForOrientation(app, landscape: true)
        awaitScreen(evidence, named: "Restored evidence context control")
        XCTAssertTrue(evidence.isSelected, "Rotation changed the selected job context")
        waitForEvidence(app)
    }

    func testTypedDraftSurvivesBothLandscapeDirections() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch([.configured])
        showTheDockActions(in: app)
        awaitScreen(app.buttons["Type"], named: "Type action")
        app.buttons["Type"].tap()
        let field = app.descendants(matching: .any)["chat-message-composer"]
        awaitScreen(field, named: "Message composer")
        field.tap()
        field.typeText("Keep this unsent draft")
        for direction in [UIDeviceOrientation.landscapeLeft, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = direction
            waitForOrientation(app, landscape: direction != .portrait)
            let retained = NSPredicate(format: "value == %@", "Keep this unsent draft")
            let expectation = XCTNSPredicateExpectation(predicate: retained, object: field)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed,
                           "Resizing discarded the unsent message")
        }
    }

    private func waitForOrientation(_ app: XCUIApplication, landscape: Bool) {
        let predicate = NSPredicate { _, _ in
            let frame = app.frame
            return landscape ? frame.width > frame.height : frame.height > frame.width
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed,
                       "The app did not finish changing orientation")
    }

    private func waitForEvidence(_ app: XCUIApplication) {
        // The section heading can scroll beneath the navigation bar while its photos are
        // visible. Check a real evidence control, scoped away from the standalone Job tab.
        let photoChoice = app.otherElements["adaptive-workspace-context"]
            .buttons["Leave out of the report"].firstMatch
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: photoChoice)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 15), .completed,
                       "Evidence did not scroll the job to its photos")
    }
}
