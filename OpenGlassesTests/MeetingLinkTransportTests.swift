import XCTest
import Combine
import UIKit
@testable import OpenGlasses

/// Tests the zero-infra Meeting-link connector transport (Zoom/Teams/Meet/Whereby).
@MainActor
final class MeetingLinkTransportTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "expertMeetingURL")
        UserDefaults.standard.removeObject(forKey: "expertStreamTransport")
        super.tearDown()
    }

    func testKindIncludesMeetingLink() {
        XCTAssertTrue(ExpertStreamKind.allCases.contains(.meetingLink))
        XCTAssertEqual(ExpertStreamKind(rawValue: "meeting_link"), .meetingLink)
    }

    func testUnavailableWithoutURL() {
        UserDefaults.standard.removeObject(forKey: "expertMeetingURL")
        XCTAssertFalse(MeetingLinkTransport().isAvailable)
    }

    func testAvailableWithURL() {
        Config.setExpertMeetingURL("https://zoom.us/j/123")
        XCTAssertTrue(MeetingLinkTransport().isAvailable)
    }

    func testStartOpensAndReturnsMeetingURL() async throws {
        Config.setExpertMeetingURL("https://meet.example/room42")
        let transport = MeetingLinkTransport()
        var opened: URL?
        transport.opener = { opened = $0 }

        let url = try await transport.start(framePublisher: PassthroughSubject<UIImage, Never>())
        XCTAssertEqual(url, "https://meet.example/room42")          // paged to the expert
        XCTAssertEqual(opened?.absoluteString, "https://meet.example/room42") // opened for the technician
        XCTAssertTrue(transport.isStreaming)

        await transport.stop()
        XCTAssertFalse(transport.isStreaming)
    }

    func testStartThrowsWithoutURL() async {
        UserDefaults.standard.removeObject(forKey: "expertMeetingURL")
        let transport = MeetingLinkTransport()
        transport.opener = { _ in XCTFail("should not open without a URL") }
        do {
            _ = try await transport.start(framePublisher: PassthroughSubject<UIImage, Never>())
            XCTFail("Expected transportUnavailable")
        } catch ExpertStreamError.transportUnavailable {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testBridgeRoutesToMeetingLink() async throws {
        Config.setExpertMeetingURL("https://wherebyexample/room")
        Config.setExpertStreamTransport(.meetingLink)
        let meeting = MeetingLinkTransport()
        var opened: URL?
        meeting.opener = { opened = $0 }
        let bridge = ExpertStreamBridge(transports: [.meetingLink: meeting],
                                        framePublisher: PassthroughSubject<UIImage, Never>())
        try await bridge.connect(sessionId: "s1", expertId: nil)
        XCTAssertEqual(bridge.roomURL, "https://wherebyexample/room")
        XCTAssertNotNil(opened)
        XCTAssertTrue(bridge.isConnected)
    }
}
