import Foundation

// MARK: - Wire facts

/// What the OpenClaw gateway wire looks like, verified against the gateway's own protocol
/// schemas (`packages/gateway-protocol/src/schema`, OpenClaw 2026.8.x) rather than release prose.
///
/// The load-bearing fact: every request schema there is a **closed** object. An unknown key is
/// a rejected frame, not an ignored one — so this file is the single place the client's
/// vocabulary lives, and `GatewaySchemaPinTests` pins every builder's output keys against a
/// checked-in copy of the schema shape. Adding a key here without updating the pin is a wire
/// break the test reports before the gateway does.
enum GatewayWire {
    /// Wire protocol the gateway exports; general operator clients must speak exactly this.
    static let protocolVersion = 4
    /// Authenticated node clients get an N-1 window.
    static let nodeMinProtocol = 3
    /// The gateway version the schema pins were taken from. Re-record on each minor we support.
    static let pinnedGatewayVersion = "2026.8.2"

    /// One of the gateway's closed set of client ids (`GATEWAY_CLIENT_IDS`).
    static let clientId = "gateway-client"
    /// One of the gateway's closed set of client modes (`GATEWAY_CLIENT_MODES`).
    static let clientMode = "node"
    static let platform = "ios"

    enum Role: String, Equatable {
        case `operator`
        case node

        var defaultScopes: [String] {
            switch self {
            case .operator: return ["operator.read", "operator.write"]
            case .node: return []
            }
        }

        var protocolWindow: (min: Int, max: Int) {
            switch self {
            case .operator: return (GatewayWire.protocolVersion, GatewayWire.protocolVersion)
            case .node: return (GatewayWire.nodeMinProtocol, GatewayWire.protocolVersion)
            }
        }
    }

    /// Methods this client used to call that the 2.0 gateway does not advertise. Listed so the
    /// catalog can refuse to build them and a test can assert none is ever emitted.
    static let removedMethods: Set<String> = [
        "tools.available",          // → tools.catalog / tools.effective
        "cron.create", "cron.delete",  // → cron.add / cron.remove
        "memory.query", "memory.store", // → memory.search (read-only)
        "channels.send", "channels.list",
        "agent.start", "agent.status", "agent.cancel", "agent.respond",
    ]

    /// Methods whose response carries a `runId` — the reply arrives later as `chat` events, so
    /// the run has to be tracked the moment its response is routed.
    static let runStartingMethods: Set<String> = ["sessions.send", "chat.send"]
}

// MARK: - connect.challenge

/// The pre-connect challenge the gateway sends first. Device-auth clients sign the challenge's
/// own `ts` as `signedAt` — the gateway allows ±2 minutes against *its* clock, so a phone with a
/// skewed clock that signed its own time would be rejected as stale.
struct GatewayChallenge: Equatable {
    let nonce: String
    let timestampMs: Int?

    static func parse(event json: [String: Any]) -> GatewayChallenge? {
        guard (json["type"] as? String) == "event",
              (json["event"] as? String) == "connect.challenge",
              let payload = json["payload"] as? [String: Any],
              let nonce = payload["nonce"] as? String, !nonce.isEmpty else { return nil }
        let ts = (payload["ts"] as? Int) ?? (payload["ts"] as? Double).map { Int($0) }
        return GatewayChallenge(nonce: nonce, timestampMs: ts)
    }
}

// MARK: - hello-ok

/// The successful connect response. `features.methods`/`events` is the capability catalog this
/// client gates on: a method absent from it is reported as unsupported, never attempted, so the
/// next protocol move degrades honestly instead of failing mid-turn.
struct GatewayHello: Equatable {
    let protocolVersion: Int
    let serverVersion: String
    let connId: String
    let methods: Set<String>
    let events: Set<String>
    let role: String
    let scopes: [String]
    /// Per-device token issued after pairing approval; the caller persists it.
    let deviceToken: String?
    let maxPayloadBytes: Int?
    let attachmentMaxBytes: Int?
    let attachmentMaxImageBytes: Int?

    func supports(_ method: String) -> Bool { methods.contains(method) }
    func emits(_ event: String) -> Bool { events.contains(event) }

    /// Parse a connect `res` frame. Returns nil for anything but an `ok` hello-ok payload —
    /// including a pre-2.0 gateway's bare `{ok:true}`, which callers treat as "connected, catalog
    /// unknown".
    static func parse(response json: [String: Any]) -> GatewayHello? {
        guard (json["ok"] as? Bool) == true,
              let payload = json["payload"] as? [String: Any],
              (payload["type"] as? String) == "hello-ok" else { return nil }
        let server = payload["server"] as? [String: Any] ?? [:]
        let features = payload["features"] as? [String: Any] ?? [:]
        let auth = payload["auth"] as? [String: Any] ?? [:]
        let policy = payload["policy"] as? [String: Any] ?? [:]
        let attachments = policy["attachments"] as? [String: Any] ?? [:]
        let token = (auth["deviceToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return GatewayHello(
            protocolVersion: payload["protocol"] as? Int ?? 0,
            serverVersion: server["version"] as? String ?? "",
            connId: server["connId"] as? String ?? "",
            methods: Set(features["methods"] as? [String] ?? []),
            events: Set(features["events"] as? [String] ?? []),
            role: auth["role"] as? String ?? "",
            scopes: auth["scopes"] as? [String] ?? [],
            deviceToken: token,
            maxPayloadBytes: policy["maxPayload"] as? Int,
            attachmentMaxBytes: attachments["maxBytes"] as? Int,
            attachmentMaxImageBytes: attachments["maxImageBytes"] as? Int
        )
    }
}

// MARK: - Attachments

/// One chat attachment (`ChatAttachmentSchema`). `content` travels as base64; the gateway also
/// accepts the Anthropic-style `source` block but this is the documented primary shape.
struct GatewayAttachment: Equatable {
    var type: String = "image"
    let mimeType: String
    var fileName: String? = nil
    let content: Data

    var wire: [String: Any] {
        var out: [String: Any] = [
            "type": type,
            "mimeType": mimeType,
            "content": content.base64EncodedString(),
            "sizeBytes": content.count,
        ]
        if let fileName { out["fileName"] = fileName }
        return out
    }

    /// Whether the gateway's advertised per-attachment ceiling admits this attachment. An
    /// unknown policy (pre-2.0 gateway) admits — the server still enforces its own limit.
    func fits(_ hello: GatewayHello?) -> Bool {
        guard let hello else { return true }
        let ceiling = type == "image" ? (hello.attachmentMaxImageBytes ?? hello.attachmentMaxBytes)
                                      : hello.attachmentMaxBytes
        guard let ceiling else { return true }
        return content.count <= ceiling
    }
}

// MARK: - Request catalog

/// One outbound RPC: the method name and the params exactly as the gateway's closed schema
/// admits them.
struct GatewayRequest {
    let method: String
    let params: [String: Any]
}

/// Cron schedule union (`CronScheduleSchema`).
enum GatewayCronSchedule: Equatable {
    case cron(expr: String, tz: String? = nil)
    case every(ms: Int)
    case at(iso8601: String)

    var wire: [String: Any] {
        switch self {
        case .cron(let expr, let tz):
            var out: [String: Any] = ["kind": "cron", "expr": expr]
            if let tz, !tz.isEmpty { out["tz"] = tz }
            return out
        case .every(let ms):
            return ["kind": "every", "everyMs": ms]
        case .at(let iso):
            return ["kind": "at", "at": iso]
        }
    }
}

/// Partial cron job update (`CronJobPatchSchema` subset this client needs).
struct GatewayCronPatch: Equatable {
    var name: String? = nil
    var schedule: GatewayCronSchedule? = nil
    var message: String? = nil
    var enabled: Bool? = nil

    var wire: [String: Any] {
        var out: [String: Any] = [:]
        if let name { out["name"] = name }
        if let schedule { out["schedule"] = schedule.wire }
        if let message { out["payload"] = ["kind": "agentTurn", "message": message] }
        if let enabled { out["enabled"] = enabled }
        return out
    }
}

/// The only place the client spells a gateway method name or a params key. Every builder's
/// output is pinned to the schema fixture in `GatewaySchemaPinTests`.
enum GatewayRequestCatalog {

    // MARK: Chat / sessions

    /// `sessions.send` — send one message into a session, creating the agent's main session on
    /// demand. The response carries a `runId`; the answer arrives as `chat` events.
    static func sessionsSend(key: String, message: String, agentId: String? = nil,
                             attachments: [GatewayAttachment] = [], timeoutMs: Int? = nil,
                             idempotencyKey: String) -> GatewayRequest {
        var params: [String: Any] = ["key": key, "message": message, "idempotencyKey": idempotencyKey]
        if let agentId { params["agentId"] = agentId }
        if !attachments.isEmpty { params["attachments"] = attachments.map(\.wire) }
        if let timeoutMs { params["timeoutMs"] = timeoutMs }
        return GatewayRequest(method: "sessions.send", params: params)
    }

    /// `chat.send` — the primary chat entry point; same reply contract as `sessions.send`.
    static func chatSend(sessionKey: String, message: String, agentId: String? = nil,
                         attachments: [GatewayAttachment] = [], idempotencyKey: String) -> GatewayRequest {
        var params: [String: Any] = ["sessionKey": sessionKey, "message": message,
                                     "idempotencyKey": idempotencyKey]
        if let agentId { params["agentId"] = agentId }
        if !attachments.isEmpty { params["attachments"] = attachments.map(\.wire) }
        return GatewayRequest(method: "chat.send", params: params)
    }

    /// `sessions.abort` — stop the active (or named) run in a session.
    static func sessionsAbort(key: String, runId: String? = nil) -> GatewayRequest {
        var params: [String: Any] = ["key": key]
        if let runId { params["runId"] = runId }
        return GatewayRequest(method: "sessions.abort", params: params)
    }

    // MARK: Tools

    static func toolsCatalog(agentId: String? = nil) -> GatewayRequest {
        var params: [String: Any] = [:]
        if let agentId { params["agentId"] = agentId }
        return GatewayRequest(method: "tools.catalog", params: params)
    }

    static func toolsEffective(sessionKey: String, agentId: String? = nil) -> GatewayRequest {
        var params: [String: Any] = ["sessionKey": sessionKey]
        if let agentId { params["agentId"] = agentId }
        return GatewayRequest(method: "tools.effective", params: params)
    }

    /// Flatten a `tools.effective` / `tools.catalog` result into `[name, description]` rows —
    /// the shape the system-prompt builder has always consumed.
    static func toolRows(from payload: [String: Any]) -> [[String: String]] {
        var rows: [[String: String]] = []
        for group in payload["groups"] as? [[String: Any]] ?? [] {
            for tool in group["tools"] as? [[String: Any]] ?? [] {
                guard let id = tool["id"] as? String ?? tool["name"] as? String, !id.isEmpty else { continue }
                if tool["deniedBySession"] as? Bool == true { continue }
                var row = ["name": id]
                if let description = tool["description"] as? String { row["description"] = description }
                rows.append(row)
            }
        }
        return rows
    }

    // MARK: Cron

    /// `cron.add` — an agent-turn job. `sessionTarget` "main" runs it in the agent's main
    /// session; `wakeMode` "now" runs on schedule rather than at the next heartbeat.
    static func cronAdd(name: String, message: String, schedule: GatewayCronSchedule,
                        description: String? = nil, sessionTarget: String = "main",
                        wakeMode: String = "now") -> GatewayRequest {
        var params: [String: Any] = [
            "name": name,
            "schedule": schedule.wire,
            "sessionTarget": sessionTarget,
            "wakeMode": wakeMode,
            "payload": ["kind": "agentTurn", "message": message],
        ]
        if let description, !description.isEmpty { params["description"] = description }
        return GatewayRequest(method: "cron.add", params: params)
    }

    static func cronUpdate(id: String, patch: GatewayCronPatch) -> GatewayRequest {
        GatewayRequest(method: "cron.update", params: ["id": id, "patch": patch.wire])
    }

    static func cronRemove(id: String) -> GatewayRequest {
        GatewayRequest(method: "cron.remove", params: ["id": id])
    }

    static func cronList(includeDisabled: Bool = true) -> GatewayRequest {
        GatewayRequest(method: "cron.list", params: ["includeDisabled": includeDisabled])
    }

    /// One spoken line per job from a `cron.list` payload.
    static func cronRows(from payload: [String: Any]) -> [String] {
        (payload["jobs"] as? [[String: Any]] ?? []).map { job in
            let id = job["id"] as? String ?? "?"
            let name = job["name"] as? String ?? "?"
            let enabled = job["enabled"] as? Bool ?? true
            let schedule = job["schedule"] as? [String: Any] ?? [:]
            let when: String
            switch schedule["kind"] as? String {
            case "cron": when = schedule["expr"] as? String ?? "?"
            case "every": when = "every \((schedule["everyMs"] as? Int ?? 0) / 1000)s"
            case "at": when = "at \(schedule["at"] as? String ?? "?")"
            default: when = "?"
            }
            let message = (job["payload"] as? [String: Any])?["message"] as? String ?? ""
            return "\(enabled ? "+" : "-") [\(id)] \(name) (\(when))\(message.isEmpty ? "" : ": \(message)")"
        }
    }

    // MARK: Memory (read-only on the wire)

    static func memorySearch(query: String, maxResults: Int) -> GatewayRequest {
        GatewayRequest(method: "memory.search",
                       params: ["query": query, "maxResults": max(1, min(50, maxResults))])
    }

    /// Text of each `memory.search` hit, tolerant of the provider-specific row shape.
    static func memoryTexts(from payload: [String: Any]) -> [String] {
        (payload["results"] as? [[String: Any]] ?? []).compactMap { row in
            for key in ["text", "snippet", "content", "chunk"] {
                if let s = row[key] as? String, !s.isEmpty { return s }
            }
            return nil
        }
    }

    // MARK: Skills

    static func skillsStatus() -> GatewayRequest {
        GatewayRequest(method: "skills.status", params: [:])
    }

    static func skillsSearch(query: String, limit: Int = 10) -> GatewayRequest {
        GatewayRequest(method: "skills.search", params: ["query": query, "limit": max(1, min(100, limit))])
    }

    static func skillsDetail(slug: String) -> GatewayRequest {
        GatewayRequest(method: "skills.detail", params: ["slug": slug])
    }

    // MARK: Node

    /// `node.event` — a node-originated event; only meaningful on a socket admitted as a node.
    static func nodeEvent(_ event: String, payload: [String: Any]) -> GatewayRequest {
        var params: [String: Any] = ["event": event]
        if !payload.isEmpty { params["payload"] = payload }
        return GatewayRequest(method: "node.event", params: params)
    }
}

// MARK: - Spoken-reply control line

/// Assistants can prefix a reply with a single JSON line that steers the gateway's own TTS
/// (`{"voice": "…", "once": true}`). The gateway strips it before *its* playback; over the chat
/// wire it reaches us verbatim, and it must never reach our TTS or the transcript.
enum GatewaySpokenReplyControl {
    static let controlKeys: Set<String> = [
        "voice", "voiceId", "model", "modelId", "speed", "rate", "stability", "similarity", "style",
        "speakerBoost", "seed", "normalize", "lang", "output_format", "latency_tier", "once",
    ]

    /// True when `line` is a JSON object whose keys are all TTS control keys.
    static func isControlLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !object.isEmpty else { return false }
        return object.keys.allSatisfy { controlKeys.contains($0) }
    }

    /// Strip a leading control line. Anything else is returned untouched.
    static func strip(_ text: String) -> String {
        guard text.first == "{" else { return text }
        // `Character.isNewline` — a CRLF pair is ONE grapheme in Swift, so comparing against
        // "\n" or "\r" individually never matches it.
        let firstLineEnd = text.firstIndex(where: \.isNewline)
        let firstLine = firstLineEnd.map { String(text[..<$0]) } ?? text
        guard isControlLine(firstLine) else { return text }
        guard let firstLineEnd else { return "" }
        return String(text[text.index(after: firstLineEnd)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `buffered` is still possibly an unfinished control line — i.e. it opens with `{`
    /// and no line break has arrived yet. Streaming callers withhold such text.
    static func isPossiblyUnfinishedControlLine(_ buffered: String) -> Bool {
        buffered.first == "{" && !buffered.contains(where: \.isNewline)
    }
}
