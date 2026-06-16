import Foundation

/// One decoded Server-Sent Event. `data` holds the (possibly multi-line) payload joined by `\n`;
/// for MCP-over-SSE this is a single JSON-RPC message.
struct SSEEvent: Equatable {
    /// The `event:` field, or `nil` when the event used the default type. Per the SSE spec a
    /// missing type means "message".
    var event: String?
    /// The concatenated `data:` lines (joined with `\n`), with no trailing newline.
    var data: String
    /// The `id:` field, if present.
    var id: String?
}

/// Pure, streaming parser for the Server-Sent Events wire format (`text/event-stream`).
///
/// This is the deterministic heart of the deferred SSE transport: framing the byte stream into
/// events, and correlating a JSON-RPC response to its request `id`, are exactly the parts that can
/// — and should — be unit-tested without a live socket. The transport that opens the connection and
/// performs the initialize handshake is deferred (Plan V); when it lands it feeds chunks here.
///
/// The format (WHATWG): events are separated by a blank line; each line is `field: value` (a single
/// leading space after the colon is stripped); `data` lines accumulate; lines beginning with `:`
/// are comments; `\r\n`, `\r`, and `\n` all delimit lines. The parser is stateful so a `data:`
/// payload split across network chunks is reassembled before the event is emitted.
struct SSEEventParser {

    /// Holds the not-yet-terminated tail of the stream between `consume` calls.
    private var buffer = ""

    /// Feed the next chunk of the stream. Returns every event *completed* by this chunk (i.e. ones
    /// whose terminating blank line has now arrived); an unterminated trailing event is retained for
    /// the next call. Newlines are normalised to `\n` so chunk boundaries can fall anywhere.
    mutating func consume(_ chunk: String) -> [SSEEvent] {
        buffer += chunk
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var events: [SSEEvent] = []
        while let separator = buffer.range(of: "\n\n") {
            let block = String(buffer[buffer.startIndex..<separator.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<separator.upperBound)
            if let event = Self.parseBlock(block) {
                events.append(event)
            }
        }
        return events
    }

    /// Emit any buffered, blank-line-less trailing event (e.g. a stream that ended without a final
    /// blank line). Leaves the parser empty.
    mutating func flush() -> [SSEEvent] {
        let block = buffer
        buffer = ""
        if let event = Self.parseBlock(block) {
            return [event]
        }
        return []
    }

    /// Parse a complete SSE body in one shot (convenience for non-streaming callers and tests).
    static func parse(_ body: String) -> [SSEEvent] {
        var parser = SSEEventParser()
        var events = parser.consume(body)
        events += parser.flush()
        return events
    }

    // MARK: - Block parsing

    /// Turn one event block (the lines between blank lines) into an `SSEEvent`, or `nil` if it held
    /// no fields (e.g. a run of comments).
    private static func parseBlock(_ block: String) -> SSEEvent? {
        var eventType: String?
        var dataLines: [String] = []
        var id: String?
        var sawField = false

        for rawLine in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty { continue }
            if line.hasPrefix(":") { continue }    // comment line

            let (field, value) = splitField(line)
            sawField = true
            switch field {
            case "event": eventType = value
            case "data":  dataLines.append(value)
            case "id":    id = value
            default:      break                    // `retry` and unknown fields are ignored
            }
        }

        guard sawField else { return nil }
        return SSEEvent(event: eventType, data: dataLines.joined(separator: "\n"), id: id)
    }

    /// Split a line into `(field, value)`, stripping a single optional space after the colon. A line
    /// with no colon is a field name with an empty value (per spec).
    private static func splitField(_ line: String) -> (field: String, value: String) {
        guard let colon = line.firstIndex(of: ":") else {
            return (line, "")
        }
        let field = String(line[line.startIndex..<colon])
        var valueStart = line.index(after: colon)
        if valueStart < line.endIndex, line[valueStart] == " " {
            valueStart = line.index(after: valueStart)
        }
        return (field, String(line[valueStart..<line.endIndex]))
    }

    // MARK: - JSON-RPC correlation

    /// Pull the raw bytes of the JSON-RPC message whose `id` matches `rpcID` out of a list of events.
    /// MCP-over-SSE delivers each JSON-RPC response as the `data` of an event; returning the raw
    /// `data` bytes means the existing `MCPClient` JSON handling is reused verbatim. Events whose
    /// data isn't a JSON object, or whose id doesn't match, are skipped.
    static func jsonRPCResponse(in events: [SSEEvent], id rpcID: Int) -> Data? {
        for event in events {
            guard let data = event.data.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let responseID = object["id"] as? Int, responseID == rpcID {
                return data
            }
        }
        return nil
    }
}
