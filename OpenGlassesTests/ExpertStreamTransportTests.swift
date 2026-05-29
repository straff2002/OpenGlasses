import XCTest
import Combine
import UIKit
@testable import OpenGlasses

/// Tests the selectable expert stream transport (MJPEG vs WebRTC seam) and the bridge's selection
/// behavior. Real streaming/network paths are not exercised.
@MainActor
final class ExpertStreamTransportTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "expertStreamTransport")
        super.tearDown()
    }

    /// A fake transport so we don't open real sockets in tests.
    private final class FakeTransport: ExpertStreamTransport {
        let displayName: String
        let isAvailable: Bool
        private(set) var isStreaming = false
        private let url: String?
        init(displayName: String, isAvailable: Bool, url: String?) {
            self.displayName = displayName; self.isAvailable = isAvailable; self.url = url
        }
        func start(framePublisher: PassthroughSubject<UIImage, Never>) async throws -> String? {
            isStreaming = true; return url
        }
        func stop() async { isStreaming = false }
    }

    private func bridge(mjpegAvailable: Bool = true, webrtcAvailable: Bool = false)
        -> (ExpertStreamBridge, FakeTransport, FakeTransport) {
        let mjpeg = FakeTransport(displayName: "MJPEG", isAvailable: mjpegAvailable, url: "https://mjpeg/room")
        let webrtc = FakeTransport(displayName: "WebRTC", isAvailable: webrtcAvailable, url: "https://webrtc/room")
        let b = ExpertStreamBridge(transports: [.mjpeg: mjpeg, .webrtc: webrtc],
                                   framePublisher: PassthroughSubject<UIImage, Never>())
        return (b, mjpeg, webrtc)
    }

    func testConfigDefaultsToMJPEG() {
        XCTAssertEqual(Config.expertStreamTransport, .mjpeg)
    }

    func testConfigRoundTrips() {
        Config.setExpertStreamTransport(.webrtc)
        XCTAssertEqual(Config.expertStreamTransport, .webrtc)
        Config.setExpertStreamTransport(.mjpeg)
        XCTAssertEqual(Config.expertStreamTransport, .mjpeg)
    }

    func testBridgeUsesSelectedMJPEGTransport() async throws {
        Config.setExpertStreamTransport(.mjpeg)
        let (b, mjpeg, webrtc) = bridge()
        try await b.connect(sessionId: "s1", expertId: nil)
        XCTAssertEqual(b.roomURL, "https://mjpeg/room")
        XCTAssertTrue(b.isConnected)
        XCTAssertTrue(mjpeg.isStreaming)
        XCTAssertFalse(webrtc.isStreaming)
    }

    func testSelectingUnavailableWebRTCThrows() async {
        Config.setExpertStreamTransport(.webrtc)
        let (b, _, _) = bridge(webrtcAvailable: false)
        do {
            try await b.connect(sessionId: "s1", expertId: nil)
            XCTFail("Expected transportUnavailable")
        } catch ExpertStreamError.transportUnavailable {
            XCTAssertFalse(b.isConnected)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testWebRTCBecomesUsableWhenAvailable() async throws {
        // Simulates the drop-in: once a real WebRTC transport reports available, selecting it works.
        Config.setExpertStreamTransport(.webrtc)
        let (b, _, webrtc) = bridge(webrtcAvailable: true)
        try await b.connect(sessionId: "s1", expertId: nil)
        XCTAssertEqual(b.roomURL, "https://webrtc/room")
        XCTAssertTrue(webrtc.isStreaming)
        await b.disconnect()
        XCTAssertFalse(b.isConnected)
    }

    func testWebRTCAvailableButRequiresSignalingConfig() async {
        UserDefaults.standard.removeObject(forKey: "expertSignalingURL")
        let transport = WebRTCPeerTransport()
        XCTAssertTrue(transport.isAvailable, "WebRTC library is bundled, so the transport is available")
        do {
            _ = try await transport.start(framePublisher: PassthroughSubject<UIImage, Never>())
            XCTFail("Expected transportUnavailable without a signaling URL")
        } catch ExpertStreamError.transportUnavailable {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testSignalingMessageRoundTrips() throws {
        let msg = SignalingMessage(type: .candidate, room: "r1", sdp: nil,
                                   candidate: "candidate:1 1 udp ...", sdpMid: "0", sdpMLineIndex: 0)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(SignalingMessage.self, from: data)
        XCTAssertEqual(decoded, msg)
        XCTAssertEqual(decoded.type, .candidate)
    }
}
