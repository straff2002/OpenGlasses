import XCTest
@testable import OpenGlasses

/// Tests for the pure SSE wire-format parser (Plan V) — the deterministic foundation the deferred
/// live SSE transport will build on. No sockets: framing and JSON-RPC correlation are exactly the
/// parts that can be unit-tested in isolation.
final class SSEEventParserTests: XCTestCase {

    func testParsesSingleMessageEvent() {
        let body = "event: message\ndata: hello\n\n"
        let events = SSEEventParser.parse(body)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.event, "message")
        XCTAssertEqual(events.first?.data, "hello")
    }

    func testParsesMultipleDataLinesJoinedWithNewline() {
        let body = "data: line1\ndata: line2\ndata: line3\n\n"
        let events = SSEEventParser.parse(body)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "line1\nline2\nline3")
        XCTAssertNil(events.first?.event)   // default type — no `event:` field
    }

    func testIgnoresCommentsAndBlankLinesWithinABlock() {
        let body = ": this is a heartbeat comment\ndata: payload\n\n"
        let events = SSEEventParser.parse(body)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "payload")
    }

    func testPureCommentBlockProducesNoEvent() {
        let events = SSEEventParser.parse(": keepalive\n\n")
        XCTAssertTrue(events.isEmpty)
    }

    func testParsesMultipleEventsInOneBody() {
        let body = "data: a\n\ndata: b\n\ndata: c\n\n"
        let events = SSEEventParser.parse(body)
        XCTAssertEqual(events.map(\.data), ["a", "b", "c"])
    }

    func testStripsExactlyOneLeadingSpaceAfterColon() {
        // First value has a single leading space (stripped); second has two (one preserved).
        let events = SSEEventParser.parse("data: one\n\ndata:  two\n\n")
        XCTAssertEqual(events[0].data, "one")
        XCTAssertEqual(events[1].data, " two")
    }

    func testNormalisesCRLFAndCR() {
        let events = SSEEventParser.parse("data: crlf\r\n\r\ndata: cr\r\rdata: more\r\r")
        XCTAssertEqual(events.first?.data, "crlf")
        // The CR-delimited blocks parse the same as LF.
        XCTAssertTrue(events.contains { $0.data == "cr" })
    }

    func testChunkedConsumeReassemblesAcrossBoundaries() {
        var parser = SSEEventParser()
        XCTAssertTrue(parser.consume("data: par").isEmpty)        // no terminator yet
        XCTAssertTrue(parser.consume("tial pay").isEmpty)
        let events = parser.consume("load\n\n")                   // terminator arrives
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "partial payload")
    }

    func testFlushEmitsTrailingEventWithoutBlankLine() {
        var parser = SSEEventParser()
        XCTAssertTrue(parser.consume("data: no trailing newline").isEmpty)
        let flushed = parser.flush()
        XCTAssertEqual(flushed.first?.data, "no trailing newline")
        XCTAssertTrue(parser.flush().isEmpty)   // buffer drained
    }

    func testJSONRPCResponseCorrelatesById() {
        let events = SSEEventParser.parse(
            #"data: {"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"# + "\n\n" +
            #"data: {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"ok"}]}}"# + "\n\n"
        )
        let match = SSEEventParser.jsonRPCResponse(in: events, id: 2)
        XCTAssertNotNil(match)
        let json = try? JSONSerialization.jsonObject(with: match!) as? [String: Any]
        XCTAssertEqual(json?["id"] as? Int, 2)
        let result = json?["result"] as? [String: Any]
        XCTAssertNotNil(result?["content"])
        // No event carries id 99.
        XCTAssertNil(SSEEventParser.jsonRPCResponse(in: events, id: 99))
    }

    func testJSONRPCResponseSkipsNonJSONData() {
        let events = SSEEventParser.parse("data: not json at all\n\n" + #"data: {"id":1}"# + "\n\n")
        XCTAssertNotNil(SSEEventParser.jsonRPCResponse(in: events, id: 1))
    }
}
