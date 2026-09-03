import XCTest
@testable import OpenGlasses

/// The pure wire parsers and sanitizers behind the gateway clients. JSON via `JSONSerialization`
/// so number/bool bridging matches production.
final class GatewayWireTests: XCTestCase {

    private func json(_ string: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: string.data(using: .utf8)!)) as? [String: Any] ?? [:]
    }

    // MARK: - connect.challenge

    func testChallengeParsesNonceAndTimestamp() {
        let challenge = GatewayChallenge.parse(event: json(#"""
        {"type":"event","event":"connect.challenge","payload":{"nonce":"abc","ts":1737264000000}}
        """#))
        XCTAssertEqual(challenge, GatewayChallenge(nonce: "abc", timestampMs: 1_737_264_000_000))
    }

    func testChallengeWithoutTimestampStillCarriesNonce() {
        let challenge = GatewayChallenge.parse(event: json(#"""
        {"type":"event","event":"connect.challenge","payload":{"nonce":"abc"}}
        """#))
        XCTAssertEqual(challenge?.nonce, "abc")
        XCTAssertNil(challenge?.timestampMs)
    }

    func testChallengeRejectsOtherFrames() {
        XCTAssertNil(GatewayChallenge.parse(event: json(#"{"type":"event","event":"tick","payload":{}}"#)))
        XCTAssertNil(GatewayChallenge.parse(event: json(#"{"type":"res","id":"1","ok":true}"#)))
    }

    // MARK: - hello-ok

    static let helloOk = #"""
    {"type":"res","id":"c1","ok":true,"payload":{"type":"hello-ok","protocol":4,
      "server":{"version":"2026.8.2","connId":"conn-9"},
      "features":{"methods":["sessions.send","chat.send","tools.effective","memory.search"],
                  "events":["chat","agent","heartbeat","cron","question.requested"]},
      "snapshot":{},
      "auth":{"role":"operator","scopes":["operator.read","operator.write"],"deviceToken":"dev-tok"},
      "policy":{"maxPayload":26214400,"maxBufferedBytes":52428800,"tickIntervalMs":15000,
                "attachments":{"maxBytes":20971520,"maxImageBytes":6291456}}}}
    """#

    func testHelloOkParsesCatalogAuthAndPolicy() throws {
        let hello = try XCTUnwrap(GatewayHello.parse(response: json(Self.helloOk)))
        XCTAssertEqual(hello.protocolVersion, 4)
        XCTAssertEqual(hello.serverVersion, "2026.8.2")
        XCTAssertEqual(hello.connId, "conn-9")
        XCTAssertTrue(hello.supports("sessions.send"))
        XCTAssertFalse(hello.supports("tools.available"), "the pre-2.0 method is absent from the catalog")
        XCTAssertTrue(hello.emits("question.requested"))
        XCTAssertEqual(hello.role, "operator")
        XCTAssertEqual(hello.scopes, ["operator.read", "operator.write"])
        XCTAssertEqual(hello.deviceToken, "dev-tok")
        XCTAssertEqual(hello.attachmentMaxImageBytes, 6_291_456)
        XCTAssertEqual(hello.attachmentMaxBytes, 20_971_520)
        XCTAssertEqual(hello.maxPayloadBytes, 26_214_400)
    }

    func testBareOkIsNotAHello() {
        XCTAssertNil(GatewayHello.parse(response: json(#"{"type":"res","id":"1","ok":true}"#)),
                     "a pre-2.0 gateway answers without a hello-ok payload")
        XCTAssertNil(GatewayHello.parse(response: json(#"{"type":"res","id":"1","ok":false,"payload":{"type":"hello-ok"}}"#)))
    }

    // MARK: - attachments against policy

    func testAttachmentFitsUsesTheImageCeiling() throws {
        let hello = try XCTUnwrap(GatewayHello.parse(response: json(Self.helloOk)))
        let small = GatewayAttachment(mimeType: "image/jpeg", content: Data(count: 6_291_456))
        let big = GatewayAttachment(mimeType: "image/jpeg", content: Data(count: 6_291_457))
        XCTAssertTrue(small.fits(hello))
        XCTAssertFalse(big.fits(hello))
        XCTAssertTrue(big.fits(nil), "no policy known → let the gateway decide")
        var pdf = GatewayAttachment(mimeType: "application/pdf", content: Data(count: 7_000_000))
        pdf.type = "file"
        XCTAssertTrue(pdf.fits(hello), "non-image attachments use the general ceiling")
    }

    // MARK: - spoken-reply control line

    func testControlLineIsStrippedFromReplies() {
        XCTAssertEqual(GatewaySpokenReplyControl.strip("{\"voice\": \"nova\", \"once\": true}\nHello there."), "Hello there.")
        XCTAssertEqual(GatewaySpokenReplyControl.strip("{\"speed\": 1.2}\r\n  Two lines\nof text"), "Two lines\nof text")
        XCTAssertEqual(GatewaySpokenReplyControl.strip("{\"voice\": \"nova\"}"), "", "a control-only reply says nothing")
    }

    func testOrdinaryJSONAndProseSurvive() {
        let data = "{\"temperature\": 21, \"unit\": \"C\"}\nis the reading"
        XCTAssertEqual(GatewaySpokenReplyControl.strip(data), data, "JSON with non-control keys is content")
        XCTAssertEqual(GatewaySpokenReplyControl.strip("Plain answer."), "Plain answer.")
        XCTAssertEqual(GatewaySpokenReplyControl.strip("{not json\nreally}"), "{not json\nreally}")
    }

    func testUnfinishedControlLineDetection() {
        XCTAssertTrue(GatewaySpokenReplyControl.isPossiblyUnfinishedControlLine("{\"voi"))
        XCTAssertFalse(GatewaySpokenReplyControl.isPossiblyUnfinishedControlLine("{\"voice\":\"x\"}\nHi"))
        XCTAssertFalse(GatewaySpokenReplyControl.isPossiblyUnfinishedControlLine("Hi {there"))
    }

    // MARK: - result flatteners

    func testToolRowsFlattenGroupsAndSkipSessionDenied() {
        let rows = GatewayRequestCatalog.toolRows(from: json(#"""
        {"agentId":"main","profile":"full","groups":[
          {"id":"core","label":"Core","source":"core","tools":[
            {"id":"web_search","label":"Web","description":"Search the web","rawDescription":"..","source":"core"},
            {"id":"exec","label":"Exec","description":"Run","rawDescription":"..","source":"core","deniedBySession":true}]},
          {"id":"mcp","label":"MCP","source":"mcp","tools":[
            {"id":"notion_query","label":"Notion","description":"Query Notion","rawDescription":"..","source":"mcp"}]}]}
        """#))
        XCTAssertEqual(rows.map { $0["name"] }, ["web_search", "notion_query"])
        XCTAssertEqual(rows.first?["description"], "Search the web")
    }

    func testCronRowsDescribeEachSchedule() {
        let rows = GatewayRequestCatalog.cronRows(from: json(#"""
        {"jobs":[
          {"id":"j1","name":"Brief","enabled":true,"schedule":{"kind":"cron","expr":"0 7 * * *"},"payload":{"kind":"agentTurn","message":"Summarise"}},
          {"id":"j2","name":"Ping","enabled":false,"schedule":{"kind":"every","everyMs":60000},"payload":{"kind":"heartbeat"}}]}
        """#))
        XCTAssertEqual(rows, ["+ [j1] Brief (0 7 * * *): Summarise", "- [j2] Ping (every 60s)"])
    }

    func testMemoryTextsTolerateRowShapes() {
        let texts = GatewayRequestCatalog.memoryTexts(from: json(#"""
        {"results":[{"text":"likes tea"},{"snippet":"lives in Wellington"},{"path":"only-a-path.md"},{"content":""}]}
        """#))
        XCTAssertEqual(texts, ["likes tea", "lives in Wellington"])
    }
}
