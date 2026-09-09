import XCTest
@testable import OpenGlasses

/// Plan BH — remote speech names its source. Pure: one string in, one string out, no services.
final class RemoteSpeechAttributionTests: XCTestCase {

    func testGatewaySpeechNamesTheGateway() {
        XCTAssertEqual(RemoteSpeechAttribution.spoken("your ride is here", from: .gateway),
                       "Message from the gateway: your ride is here")
    }

    func testPeerSpeechNamesThePeer() {
        XCTAssertEqual(RemoteSpeechAttribution.spoken("hello", from: .mcpPeer(id: "ops")),
                       "Message from Peer ops: hello")
    }

    func testAnonymousPeerFallsBackToTheGenericPeerName() {
        XCTAssertEqual(RemoteSpeechAttribution.spoken("hello", from: .mcpPeer(id: "")),
                       "Message from MCP peer: hello")
    }

    func testSurroundingWhitespaceIsTrimmedFromTheBody() {
        XCTAssertEqual(RemoteSpeechAttribution.spoken("  \n hello \t ", from: .gateway),
                       "Message from the gateway: hello")
    }

    func testEmptyBodySpeaksTheAttributionAloneWithNoDanglingColon() {
        XCTAssertEqual(RemoteSpeechAttribution.spoken("   ", from: .gateway),
                       "Message from the gateway")
        XCTAssertEqual(RemoteSpeechAttribution.spoken("", from: .mcpPeer(id: "ops")),
                       "Message from Peer ops")
    }

    /// The whole point of building one string: the wearer can never hear the body without the
    /// prefix, whatever a barge-in interrupts.
    func testAttributionAndBodyAreASingleUtterance() {
        let utterance = RemoteSpeechAttribution.spoken("take the next left", from: .gateway)
        XCTAssertTrue(utterance.hasPrefix("Message from the gateway: "))
        XCTAssertTrue(utterance.hasSuffix("take the next left"))
    }
}
