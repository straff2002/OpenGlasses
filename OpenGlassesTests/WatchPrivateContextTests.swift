import XCTest
@testable import OpenGlasses

/// Plan LU P1b — the watch while a private conversation is open: the Private button's request, the
/// phone's reply, and what the wrist shows. No reply text reaches the idle summary while private;
/// a reply to a request made on the watch still does.
final class WatchPrivateContextTests: XCTestCase {

    override func tearDown() {
        PrivateConversationGate.setActive(false)
        super.tearDown()
    }

    // MARK: - The request

    func testEachButtonSendsItsAction() {
        for action in WatchPrivateWire.Action.allCases {
            XCTAssertEqual(WatchPrivateWire.action(from: WatchPrivateWire.message(action)), action)
        }
    }

    func testAnUnknownOrMissingActionIsRefused() {
        XCTAssertNil(WatchPrivateWire.action(from: ["command": WatchPrivateWire.command, "action": "pause"]))
        XCTAssertNil(WatchPrivateWire.action(from: ["command": WatchPrivateWire.command]))
        XCTAssertNil(WatchPrivateWire.action(from: ["command": "ask", "action": "start"]),
                     "another command's message is not a private request")
    }

    func testThePhoneRecognisesTheCommand() {
        XCTAssertNotNil(WatchConnectivityManager.commandToken(WatchPrivateWire.command))
    }

    // MARK: - The reply

    func testAStartThatTookSaysSo() {
        let reply = WatchPrivateWire.reply(isPrivate: true, refusal: nil)
        XCTAssertEqual(reply[WatchPrivateWire.contextKey] as? Bool, true)
        XCTAssertNil(reply[WatchPrivateWire.errorKey])
    }

    func testARefusalCarriesThePhonesReason() {
        let reason = PrivateStartRefusal.jobOpen.reason
        let reply = WatchPrivateWire.reply(isPrivate: false, refusal: reason)
        XCTAssertEqual(reply[WatchPrivateWire.contextKey] as? Bool, false)
        XCTAssertEqual(reply[WatchPrivateWire.errorKey] as? String, reason)
    }

    // MARK: - The idle summary

    func testTheContextCarriesNoReplyWhilePrivate() {
        PrivateConversationGate.setActive(true)
        for reply in ["You might want to see a GP about that mole.",
                      String(repeating: "A long private answer. ", count: 20), ""] {
            let payload = WatchConnectivityManager.lastResponsePayload(
                reply, placeholder: PrivateConversationGate.placeholder(for: .watchLastResponse))
            XCTAssertEqual(payload, PrivateConversationPolicy.placeholderText)
            if !reply.isEmpty { XCTAssertFalse(payload.contains("mole") || payload.contains("answer")) }
        }
    }

    func testTheWristShowsNoSummaryReplyWhilePrivate() {
        XCTAssertEqual(WatchPrivateWire.shownReply(lastResponse: PrivateConversationPolicy.placeholderText,
                                                   isPrivate: true, replyToWatchRequest: nil), "")
        XCTAssertEqual(WatchPrivateWire.shownReply(lastResponse: "An earlier answer.",
                                                   isPrivate: true, replyToWatchRequest: nil), "",
                       "not even the answer from before it started")
    }

    func testAReplyToARequestMadeOnTheWatchStillShows() {
        XCTAssertEqual(WatchPrivateWire.shownReply(lastResponse: PrivateConversationPolicy.placeholderText,
                                                   isPrivate: true, replyToWatchRequest: "Yes, see a GP."),
                       "Yes, see a GP.")
    }

    func testOrdinaryRepliesShowAsBefore() {
        XCTAssertEqual(WatchPrivateWire.shownReply(lastResponse: "Sunny.", isPrivate: false,
                                                   replyToWatchRequest: "a held private reply"),
                       "Sunny.", "a private reply held on the wrist is never shown once it ends")
    }

    /// The watch reads the badge from the key the phone writes.
    func testThePhoneWritesTheKeyTheWatchReads() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/WatchConnectivityManager.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("WatchPrivateWire.contextKey: PrivateConversationGate.isActive"))
        XCTAssertEqual(WatchPrivateWire.contextKey, "isPrivate")
    }
}
