import XCTest
@testable import OpenGlasses

/// Pins every frame this client emits to the OpenClaw gateway's request schemas.
///
/// The gateway validates each request against a **closed** TypeBox object — an unknown key is a
/// rejected frame, not an ignored one. `schemaKeys` is a checked-in copy of the allowed key set
/// per method (source: `packages/gateway-protocol/src/schema/*.ts`, OpenClaw
/// `GatewayWire.pinnedGatewayVersion`). A builder that grows a key the schema lacks fails here,
/// before any gateway sees it. Re-record the fixture on each gateway minor we claim to support.
final class GatewaySchemaPinTests: XCTestCase {

    // MARK: - Fixture (OpenClaw 2026.8.2 schemas)

    static let schemaKeys: [String: Set<String>] = [
        "connect": ["minProtocol", "maxProtocol", "client", "caps", "commands", "computerUse",
                    "workerRuns", "permissions", "pathEnv", "role", "scopes", "device", "auth",
                    "locale", "userAgent"],
        "connect.client": ["id", "displayName", "version", "buildId", "platform", "deviceFamily",
                           "modelIdentifier", "timeZone", "mode", "instanceId"],
        "connect.device": ["id", "publicKey", "signature", "signedAt", "nonce"],
        "connect.auth": ["token", "bootstrapToken", "deviceToken", "password",
                         "approvalRuntimeToken", "agentRuntimeIdentityToken"],
        "sessions.send": ["key", "agentId", "message", "thinking", "attachments", "timeoutMs",
                          "idempotencyKey"],
        "chat.send": ["sessionKey", "agentId", "sessionId", "message", "intent", "thinking", "fastMode",
                      "fastAutoOnSeconds", "queueMode", "deliver", "originatingChannel", "originatingTo",
                      "originatingAccountId", "originatingThreadId", "replyToId", "attachments",
                      "toolBindings", "timeoutMs", "systemInputProvenance", "systemProvenanceReceipt",
                      "suppressCommandInterpretation", "expectedLeafEntryId",
                      "expectedSessionRoutingContract", "expectedPermissionMode",
                      "expectedToolOverrides", "idempotencyKey"],
        "sessions.abort": ["key", "runId", "agentId", "clearQueued"],
        "tools.catalog": ["agentId", "includePlugins"],
        "tools.effective": ["agentId", "sessionKey"],
        "cron.add": ["name", "declarationKey", "displayName", "owner", "agentId", "sessionKey",
                     "description", "enabled", "deleteAfterRun", "schedule", "pacing", "trigger",
                     "sessionTarget", "wakeMode", "payload", "delivery", "failureAlert"],
        "cron.add.schedule.cron": ["kind", "expr", "tz", "staggerMs"],
        "cron.add.schedule.every": ["kind", "everyMs", "anchorMs"],
        "cron.add.schedule.at": ["kind", "at"],
        "cron.add.payload.agentTurn": ["kind", "message", "model", "fallbacks", "thinking",
                                       "timeoutSeconds", "allowUnsafeExternalContent", "lightContext",
                                       "toolsAllow", "toolsAllowIsDefault"],
        "cron.update": ["id", "jobId", "patch", "expectedConfigRevision"],
        "cron.update.patch": ["name", "displayName", "agentId", "sessionKey", "description", "enabled",
                              "deleteAfterRun", "schedule", "pacing", "trigger", "sessionTarget",
                              "wakeMode", "payload", "delivery", "failureAlert", "state"],
        "cron.remove": ["id", "jobId"],
        "cron.list": ["includeDisabled", "limit", "offset", "query", "enabled", "scheduleKind",
                      "lastRunStatus", "trigger", "sortBy", "sortDir", "agentId", "compact",
                      "includeDeliveryPreviews"],
        "memory.search": ["query", "maxResults", "minScore", "agentId", "sessionKey"],
        "skills.status": ["agentId", "sessionKey"],
        "skills.search": ["query", "limit"],
        "skills.detail": ["slug"],
        "node.event": ["event", "payload", "payloadJSON"],
    ]

    // MARK: - Helpers

    private func assertKeys(_ params: [String: Any], within pin: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let allowed = Self.schemaKeys[pin] else {
            return XCTFail("no schema pin recorded for \(pin)", file: file, line: line)
        }
        let extra = Set(params.keys).subtracting(allowed)
        XCTAssertTrue(extra.isEmpty, "\(pin) emits keys the closed schema rejects: \(extra.sorted())",
                      file: file, line: line)
    }

    private func assertRequest(_ request: GatewayRequest, file: StaticString = #filePath, line: UInt = #line) {
        assertKeys(request.params, within: request.method, file: file, line: line)
        XCTAssertFalse(GatewayWire.removedMethods.contains(request.method),
                       "\(request.method) is not on the 2.0 gateway", file: file, line: line)
    }

    // MARK: - connect

    func testConnectParamsStayWithinTheClosedSchema() {
        let params = OpenClawConnectParams.build(
            displayName: "OpenGlasses", version: "1.0", token: "tok", role: .operator,
            caps: ["tool-events"], commands: ["camera.snap"],
            challenge: GatewayChallenge(nonce: "n", timestampMs: 1_000),
            pairedDeviceId: "dev-1", localeIdentifier: "en_NZ", signedAtMs: nil)
        assertKeys(params, within: "connect")
        assertKeys(params["client"] as? [String: Any] ?? [:], within: "connect.client")
        assertKeys(params["device"] as? [String: Any] ?? [:], within: "connect.device")
        assertKeys(params["auth"] as? [String: Any] ?? [:], within: "connect.auth")
        XCTAssertNil(params["deviceCapabilities"], "the pre-2.0 free-form key is gone")
    }

    // MARK: - request catalog

    func testSessionsSendAndChatSend() {
        let attachment = GatewayAttachment(mimeType: "image/jpeg", fileName: "a.jpg", content: Data([1, 2, 3]))
        assertRequest(GatewayRequestCatalog.sessionsSend(
            key: "agent:main:glass", message: "hi", agentId: "main", attachments: [attachment],
            timeoutMs: 1_000, idempotencyKey: "k"))
        assertRequest(GatewayRequestCatalog.chatSend(
            sessionKey: "agent:main:glass", message: "hi", agentId: "main", attachments: [attachment],
            idempotencyKey: "k"))
        assertRequest(GatewayRequestCatalog.sessionsAbort(key: "agent:main:glass", runId: "r"))
        let wire = attachment.wire
        XCTAssertEqual(Set(wire.keys), ["type", "mimeType", "fileName", "content", "sizeBytes"])
        XCTAssertEqual(wire["content"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual(wire["sizeBytes"] as? Int, 3)
    }

    func testToolsMemorySkillsAndNodeEvent() {
        assertRequest(GatewayRequestCatalog.toolsCatalog(agentId: "main"))
        assertRequest(GatewayRequestCatalog.toolsEffective(sessionKey: "s", agentId: "main"))
        assertRequest(GatewayRequestCatalog.memorySearch(query: "q", maxResults: 500))
        XCTAssertEqual(GatewayRequestCatalog.memorySearch(query: "q", maxResults: 500).params["maxResults"] as? Int, 50,
                       "the gateway caps maxResults at 50")
        assertRequest(GatewayRequestCatalog.skillsStatus())
        assertRequest(GatewayRequestCatalog.skillsSearch(query: "weather", limit: 5))
        assertRequest(GatewayRequestCatalog.skillsDetail(slug: "weather"))
        assertRequest(GatewayRequestCatalog.nodeEvent("device.event", payload: ["type": "battery"]))
    }

    func testCronRequests() {
        let add = GatewayRequestCatalog.cronAdd(
            name: "Morning brief", message: "Summarise my day", schedule: .cron(expr: "0 7 * * *", tz: "Pacific/Auckland"),
            description: "from glasses")
        assertRequest(add)
        assertKeys(add.params["schedule"] as? [String: Any] ?? [:], within: "cron.add.schedule.cron")
        assertKeys(add.params["payload"] as? [String: Any] ?? [:], within: "cron.add.payload.agentTurn")
        XCTAssertEqual((add.params["payload"] as? [String: Any])?["kind"] as? String, "agentTurn")
        XCTAssertEqual(add.params["sessionTarget"] as? String, "main")
        XCTAssertEqual(add.params["wakeMode"] as? String, "now")

        assertKeys(GatewayCronSchedule.every(ms: 60_000).wire, within: "cron.add.schedule.every")
        assertKeys(GatewayCronSchedule.at(iso8601: "2026-09-04T07:00:00Z").wire, within: "cron.add.schedule.at")

        let update = GatewayRequestCatalog.cronUpdate(
            id: "job-1", patch: GatewayCronPatch(name: "n", schedule: .cron(expr: "* * * * *"), message: "m", enabled: false))
        assertRequest(update)
        assertKeys(update.params["patch"] as? [String: Any] ?? [:], within: "cron.update.patch")
        assertRequest(GatewayRequestCatalog.cronRemove(id: "job-1"))
        assertRequest(GatewayRequestCatalog.cronList())
    }

    func testRemovedMethodsAreNeverBuilt() {
        // Every method the catalog can produce, versus the ones the 2.0 gateway dropped.
        let produced: Set<String> = [
            GatewayRequestCatalog.sessionsSend(key: "k", message: "m", idempotencyKey: "i").method,
            GatewayRequestCatalog.chatSend(sessionKey: "k", message: "m", idempotencyKey: "i").method,
            GatewayRequestCatalog.sessionsAbort(key: "k").method,
            GatewayRequestCatalog.toolsCatalog().method,
            GatewayRequestCatalog.toolsEffective(sessionKey: "k").method,
            GatewayRequestCatalog.cronAdd(name: "n", message: "m", schedule: .every(ms: 1)).method,
            GatewayRequestCatalog.cronUpdate(id: "i", patch: GatewayCronPatch()).method,
            GatewayRequestCatalog.cronRemove(id: "i").method,
            GatewayRequestCatalog.cronList().method,
            GatewayRequestCatalog.memorySearch(query: "q", maxResults: 1).method,
            GatewayRequestCatalog.skillsStatus().method,
            GatewayRequestCatalog.skillsSearch(query: "q").method,
            GatewayRequestCatalog.skillsDetail(slug: "s").method,
            GatewayRequestCatalog.nodeEvent("e", payload: [:]).method,
        ]
        XCTAssertTrue(produced.isDisjoint(with: GatewayWire.removedMethods))
        XCTAssertTrue(produced.allSatisfy { Self.schemaKeys[$0] != nil },
                      "every produced method has a recorded pin")
    }

    // MARK: - wire constants

    func testProtocolWindowPerRole() {
        XCTAssertEqual(GatewayWire.Role.operator.protocolWindow.min, 4, "operator clients must speak exactly 4")
        XCTAssertEqual(GatewayWire.Role.operator.protocolWindow.max, 4)
        XCTAssertEqual(GatewayWire.Role.node.protocolWindow.min, 3, "nodes get the N-1 window")
        XCTAssertEqual(GatewayWire.Role.node.protocolWindow.max, 4)
        XCTAssertEqual(GatewayWire.clientId, "gateway-client", "one of the gateway's closed client ids")
        XCTAssertEqual(GatewayWire.clientMode, "node", "one of the gateway's closed client modes")
    }
}
