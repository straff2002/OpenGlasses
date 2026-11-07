import XCTest

/// Exercises the actual Add Model flow without credentials or a network session.
final class RealtimeModelSetupUITests: AccessibilityAuditCase {
    func testChinaProvidersAreDiscoverableInBothModelFlows() {
        let app = launch([.configured])
        openTab("Settings", in: app)
        // The hub's Assistant row opens the models page, titled for the row it is reached by.
        tapRow(startingWith: "Assistant", in: app)
        awaitScreen(app.navigationBars["Assistant"], named: "The Assistant page")
        tapRow(startingWith: "Add Model", in: app)
        awaitScreen(app.navigationBars["Add Model"], named: "Add Model")

        let conversation = app.segmentedControls["model.conversationKind"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        conversation.buttons["Realtime"].tap()
        let realtimeProvider = app.buttons["realtime.provider"]
        XCTAssertTrue(realtimeProvider.waitForExistence(timeout: 10))
        realtimeProvider.tap()
        app.buttons["Qwen (Model Studio)"].tap()
        XCTAssertEqual(app.textFields["realtime.model"].value as? String, "qwen3.8-omni-flash-realtime")
        XCTAssertTrue((app.textFields["realtime.endpoint"].value as? String ?? "").contains("{workspace}"))

        realtimeProvider.tap()
        app.buttons["Qwen Audio (Model Studio)"].tap()
        XCTAssertEqual(app.textFields["realtime.model"].value as? String, "qwen-audio-3.1-realtime-plus")

        realtimeProvider.tap()
        app.buttons["Doubao"].tap()
        XCTAssertEqual(app.textFields["realtime.model"].value as? String, "1.2.6.1")
        XCTAssertTrue((app.textFields["realtime.endpoint"].value as? String ?? "").contains("/duplex/realtime/dialogue"))

        conversation.buttons["Chat"].tap()
        let chatProvider = app.buttons["chat.provider"]
        XCTAssertTrue(chatProvider.waitForExistence(timeout: 10))
        chatProvider.tap()
        XCTAssertTrue(app.buttons["Qwen (Model Studio)"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Doubao (Ark API)"].exists)
        app.buttons["Doubao (Ark API)"].tap()
        app.buttons["Cancel"].tap()
    }
}
