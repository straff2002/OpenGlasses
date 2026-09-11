import XCTest
import Combine
import UIKit
@testable import OpenGlasses

/// The browser-streaming relay is per-deployment: whoever runs one sees every room id and can read
/// every frame passing through it. So the app ships no relay address, and streaming stays off until
/// an operator enters their own (Settings → Field Assist). These pin that there is no fallback host
/// left to re-appear, and that the refusal says where to fix it.
final class BrowserStreamRelayTests: XCTestCase {

    private let keys = ["webRTCSignalingURL", "webRTCViewerBaseURL"]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    // MARK: - Config

    func testRelayURLsAreEmptyWhenUnset() {
        XCTAssertEqual(Config.webRTCSignalingURL, "")
        XCTAssertEqual(Config.webRTCViewerBaseURL, "")
    }

    func testRelayURLsRoundTripThroughTheirSetters() {
        Config.setWebRTCSignalingURL("wss://relay.example/ws")
        Config.setWebRTCViewerBaseURL("https://relay.example/view")

        XCTAssertEqual(Config.webRTCSignalingURL, "wss://relay.example/ws")
        XCTAssertEqual(Config.webRTCViewerBaseURL, "https://relay.example/view")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "webRTCSignalingURL"), "wss://relay.example/ws")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "webRTCViewerBaseURL"), "https://relay.example/view")
    }

    /// Clearing the field returns the property to empty rather than to a shipped default — the
    /// exact case the old fallback host silently handled.
    func testClearingTheSettingLeavesNoFallbackHost() {
        Config.setWebRTCSignalingURL("wss://relay.example/ws")
        Config.setWebRTCViewerBaseURL("https://relay.example/view")

        Config.setWebRTCSignalingURL("")
        Config.setWebRTCViewerBaseURL("")

        XCTAssertEqual(Config.webRTCSignalingURL, "")
        XCTAssertEqual(Config.webRTCViewerBaseURL, "")
    }

    // MARK: - Service refusal
    //
    // A fresh instance, never `.shared`: the shared service's camera path needs the glasses SDK,
    // which fatals headless. `startStreaming` only validates the endpoint, so nothing here opens a
    // socket.

    @MainActor
    func testStreamingRefusesToStartWithoutARelay() {
        let service = WebRTCStreamingService()

        let viewerURL = service.startStreaming(framePublisher: PassthroughSubject<UIImage, Never>())

        XCTAssertEqual(viewerURL, "")
        XCTAssertFalse(service.isStreaming)
        XCTAssertEqual(service.streamURL, "")
        XCTAssertEqual(service.errorMessage, WebRTCStreamingService.relayNotConfiguredMessage)
    }

    /// The refusal has to be actionable: it names the screen that sets a relay.
    func testRefusalMessageNamesWhereToFixIt() {
        XCTAssertTrue(WebRTCStreamingService.relayNotConfiguredMessage.contains("Settings"))
        XCTAssertTrue(WebRTCStreamingService.relayNotConfiguredMessage.contains("Field Assist"))
    }

    /// Half a relay is not a relay: the frame socket without a viewer page would produce a link
    /// with no page behind it, so that refuses too.
    @MainActor
    func testStreamingRefusesWithoutAViewerBaseURL() {
        Config.setWebRTCSignalingURL("wss://relay.example/ws")
        let service = WebRTCStreamingService()

        XCTAssertEqual(service.startStreaming(framePublisher: PassthroughSubject<UIImage, Never>()), "")
        XCTAssertFalse(service.isStreaming)
    }
}
