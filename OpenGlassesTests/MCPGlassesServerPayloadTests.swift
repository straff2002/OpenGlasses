import XCTest
@testable import OpenGlasses

/// The pure halves of the LAN glasses server's answers: what `/glasses_status` says and where a
/// `mode: "display"` message is delivered. The socket, the camera and the HUD are live edges.
final class MCPGlassesServerPayloadTests: XCTestCase {

    @MainActor
    func testConnectedMeansTheLinkNotACachedFrame() {
        let payload = MCPGlassesServer.statusPayload(
            linkUp: true, streaming: false, hasFrame: false, permissionGranted: true,
            captureInProgress: false, lastServedFrameAt: nil, now: Date())
        XCTAssertEqual(payload["connected"] as? Bool, true,
                       "an idle stream has no frame; the worn pair is still connected")
        XCTAssertEqual(payload["streaming"] as? Bool, false)
        XCTAssertEqual(payload["has_frame"] as? Bool, false)
        XCTAssertEqual(payload["permission_granted"] as? Bool, true)
        XCTAssertEqual(payload["capture_in_progress"] as? Bool, false)
        XCTAssertNil(payload["frame_age_ms"], "nothing served yet")
        XCTAssertNil(payload["last_frame_iso"])
    }

    @MainActor
    func testServedFrameAgeIsReported() {
        let now = Date()
        let payload = MCPGlassesServer.statusPayload(
            linkUp: false, streaming: false, hasFrame: true, permissionGranted: false,
            captureInProgress: false, lastServedFrameAt: now.addingTimeInterval(-1.5), now: now)
        XCTAssertEqual(payload["connected"] as? Bool, false)
        XCTAssertEqual(payload["frame_age_ms"] as? Int, 1500)
        XCTAssertNotNil(payload["last_frame_iso"])
    }

    @MainActor
    func testDisplayMessagesGoToTheLensWhenThereIsOneAndToThePhoneOtherwise() {
        XCTAssertEqual(MCPGlassesServer.DisplayDelivery.route(hasDisplay: true), .hud)
        XCTAssertEqual(MCPGlassesServer.DisplayDelivery.route(hasDisplay: false), .phone)
    }
}
