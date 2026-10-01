import XCTest
@testable import OpenGlasses

/// Plan GS P1 — Home Assistant service data is an allowlist, not a pass-through.
final class HomeAssistantServiceDataTests: XCTestCase {

    func testAllowedMediaKeysPassThroughIntoTheBody() throws {
        let data = try HomeAssistantServiceData.validated([
            "media_content_id": "spotify:playlist:abc",
            "media_content_type": "playlist",
            "volume_level": 0.25,
            "source": "Spotify",
        ]).get()
        let body = data.body(entityId: "media_player.kitchen")
        XCTAssertEqual(body["entity_id"] as? String, "media_player.kitchen")
        XCTAssertEqual(body["media_content_id"] as? String, "spotify:playlist:abc")
        XCTAssertEqual(body["volume_level"] as? Double, 0.25)
        XCTAssertEqual(body.count, 5)
    }

    func testAnyOtherKeyIsRejected() {
        for key in ["message", "entity_id", "command", "script", "target"] {
            XCTAssertEqual(HomeAssistantServiceData.validated([key: "x"]), .failure(.keyNotAllowed(key)), key)
        }
    }

    func testVolumeMustBeANumberFromZeroToOne() {
        XCTAssertEqual(HomeAssistantServiceData.validated(["volume_level": 1.5]), .failure(.outOfRange("volume_level")))
        XCTAssertEqual(HomeAssistantServiceData.validated(["volume_level": -0.1]), .failure(.outOfRange("volume_level")))
        XCTAssertEqual(HomeAssistantServiceData.validated(["volume_level": true]), .failure(.wrongType("volume_level")))
        XCTAssertNoThrow(try HomeAssistantServiceData.validated(["volume_level": "0.5"]).get())
    }

    func testTextMustBeNonEmptyAndBounded() {
        XCTAssertEqual(HomeAssistantServiceData.validated(["source": "  "]), .failure(.outOfRange("source")))
        let long = String(repeating: "a", count: HomeAssistantServiceData.maxTextLength + 1)
        XCTAssertEqual(HomeAssistantServiceData.validated(["media_content_id": long]), .failure(.outOfRange("media_content_id")))
        XCTAssertEqual(HomeAssistantServiceData.validated(["source": 3]), .failure(.wrongType("source")))
    }

    func testRefusalNamesTheAllowedKeys() {
        let line = HomeAssistantServiceData.refusal(for: .keyNotAllowed("message"))
        XCTAssertTrue(line.contains("media_content_id, media_content_type, source, volume_level"), line)
    }

    func testEmptyDataIsJustTheEntity() {
        XCTAssertEqual(HomeAssistantServiceData.empty.body(entityId: "media_player.x").count, 1)
    }
}
