import XCTest
@testable import OpenGlasses

/// Tests for the Gemini Live session-resumption wire shapes (Plan CJ item 7).
final class GeminiSessionResumptionTests: XCTestCase {

    func testSetupValueWithoutHandleRequestsUpdates() {
        XCTAssertTrue(GeminiSessionResumption.setupValue(handle: nil).isEmpty)
        XCTAssertTrue(GeminiSessionResumption.setupValue(handle: "").isEmpty)
    }

    func testSetupValueWithHandleResumes() {
        let value = GeminiSessionResumption.setupValue(handle: "abc123")
        XCTAssertEqual(value["handle"] as? String, "abc123")
    }

    func testUpdateParsing() {
        let update = GeminiSessionResumption.update(from: [
            "sessionResumptionUpdate": ["newHandle": "h1", "resumable": true]
        ])
        XCTAssertEqual(update, .init(newHandle: "h1", resumable: true))
    }

    func testNonUpdateMessagesAreNil() {
        XCTAssertNil(GeminiSessionResumption.update(from: ["serverContent": ["turnComplete": true]]))
        XCTAssertNil(GeminiSessionResumption.update(from: [:]))
    }

    func testMissingFieldsDefaultSafely() {
        let update = GeminiSessionResumption.update(from: ["sessionResumptionUpdate": [:] as [String: Any]])
        XCTAssertEqual(update, .init(newHandle: nil, resumable: false))
    }

    func testApplyStoresOnlyResumableNonEmptyHandles() {
        XCTAssertEqual(GeminiSessionResumption.apply(.init(newHandle: "h2", resumable: true), to: "h1"), "h2")
        // Not yet valid → keep the last good handle.
        XCTAssertEqual(GeminiSessionResumption.apply(.init(newHandle: "h3", resumable: false), to: "h1"), "h1")
        XCTAssertEqual(GeminiSessionResumption.apply(.init(newHandle: nil, resumable: true), to: "h1"), "h1")
        XCTAssertEqual(GeminiSessionResumption.apply(.init(newHandle: "", resumable: true), to: "h1"), "h1")
        XCTAssertNil(GeminiSessionResumption.apply(.init(newHandle: nil, resumable: false), to: nil))
    }
}
