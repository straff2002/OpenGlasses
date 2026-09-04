import XCTest
@testable import OpenGlasses

// MARK: - Scripted socket

/// A `GatewaySocket` fed from a script: frames the "gateway" pushes, plus a request handler that
/// answers each frame the client sends. Everything the client sent is recorded for assertions.
final class ScriptedGatewaySocket: GatewaySocket {
    private let lock = NSLock()
    private var inbound: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var sent: [[String: Any]] = []
    private var cancelled = false

    /// Answers a client request with zero or more frames the gateway sends back, in order.
    var onRequest: (([String: Any]) -> [[String: Any]])?

    init(initialFrames: [[String: Any]] = []) {
        initialFrames.forEach(push)
    }

    var sentFrames: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return sent
    }

    func sentRequests(method: String) -> [[String: Any]] {
        sentFrames.filter { ($0["method"] as? String) == method }
    }

    func push(_ frame: [String: Any]) {
        let text = String(data: try! JSONSerialization.data(withJSONObject: frame), encoding: .utf8)!
        lock.lock()
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: text)
            return
        }
        inbound.append(text)
        lock.unlock()
    }

    func send(_ text: String) async throws {
        guard let data = text.data(using: .utf8),
              let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lock.lock()
        sent.append(frame)
        let handler = onRequest
        lock.unlock()
        for reply in handler?(frame) ?? [] { push(reply) }
    }

    func receive() async throws -> String {
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        if !inbound.isEmpty {
            let next = inbound.removeFirst()
            lock.unlock()
            return next
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}

// MARK: - Gateway script helpers

enum GatewayScript {
    static let challengeTs = 1_737_264_000_000

    static var challenge: [String: Any] {
        ["type": "event", "event": "connect.challenge", "payload": ["nonce": "nonce-1", "ts": challengeTs]]
    }

    static func helloOk(replyTo id: String, methods: [String], events: [String] = ["chat", "agent", "heartbeat", "cron"],
                        deviceToken: String? = nil) -> [String: Any] {
        var auth: [String: Any] = ["role": "operator", "scopes": ["operator.read", "operator.write"]]
        if let deviceToken { auth["deviceToken"] = deviceToken }
        return ["type": "res", "id": id, "ok": true, "payload": [
            "type": "hello-ok", "protocol": 4,
            "server": ["version": "2026.8.2", "connId": "conn-1"],
            "features": ["methods": methods, "events": events],
            "snapshot": [:],
            "auth": auth,
            "policy": ["maxPayload": 26_214_400, "maxBufferedBytes": 52_428_800, "tickIntervalMs": 15_000,
                       "attachments": ["maxBytes": 20_971_520, "maxImageBytes": 16]],
        ] as [String: Any]]
    }

    static func ok(replyTo id: String, payload: [String: Any]) -> [String: Any] {
        ["type": "res", "id": id, "ok": true, "payload": payload]
    }

    static func chat(runId: String, seq: Int, state: String, text: String?) -> [String: Any] {
        var payload: [String: Any] = ["runId": runId, "sessionKey": "agent:main:glass", "seq": seq, "state": state]
        if let text {
            payload["message"] = ["role": "assistant", "content": [["type": "text", "text": text]], "timestamp": 1]
            if state == "delta" { payload["deltaText"] = text }
        }
        return ["type": "event", "event": "chat", "payload": payload]
    }
}

// MARK: - Bridge

/// Drives `OpenClawBridge` through challenge → connect → hello-ok → `sessions.send` → `chat`
/// delta/final against a scripted 2.0 gateway, and pins what went over the wire.
@MainActor
final class OpenClawBridgeScriptedSocketTests: XCTestCase {

    private var priorAgentMode = false
    private var priorGateways: [GatewayConfig] = []

    override func setUp() {
        super.setUp()
        priorAgentMode = Config.agentModeEnabled
        priorGateways = Config.savedGateways
        Config.setAgentModeEnabled(true)
        Config.setSavedGateways([])
        Config.setOpenClawEnabled(true)
        Config.setOpenClawGatewayToken("shared-token")
        Config.setOpenClawConnectionMode(.lan)
        Config.setOpenClawLanHost("http://127.0.0.1")
        Config.setOpenClawPort(18789)
    }

    override func tearDown() {
        Config.setAgentModeEnabled(priorAgentMode)
        Config.setSavedGateways(priorGateways)
        Config.setOpenClawEnabled(false)
        Config.setOpenClawGatewayToken("")
        super.tearDown()
    }

    private func makeBridge(methods: [String] = ["sessions.send", "chat.send", "tools.effective", "memory.search"],
                            answer: @escaping (_ requestId: String, _ params: [String: Any]) -> [[String: Any]])
        -> (OpenClawBridge, ScriptedGatewaySocket) {
        let socket = ScriptedGatewaySocket(initialFrames: [GatewayScript.challenge])
        socket.onRequest = { frame in
            let id = frame["id"] as? String ?? ""
            let params = frame["params"] as? [String: Any] ?? [:]
            switch frame["method"] as? String {
            case "connect":
                return [GatewayScript.helloOk(replyTo: id, methods: methods)]
            case "tools.effective":
                return [GatewayScript.ok(replyTo: id, payload: [
                    "agentId": "main", "profile": "full",
                    "groups": [["id": "core", "label": "Core", "source": "core",
                                "tools": [["id": "web_search", "label": "Web", "description": "Search", "rawDescription": "", "source": "core"]]]],
                ])]
            case "sessions.send":
                return answer(id, params)
            default:
                return [["type": "res", "id": id, "ok": false, "error": ["code": "UNKNOWN_METHOD", "message": "nope"]]]
            }
        }
        let bridge = OpenClawBridge(socketFactory: { _ in socket })
        return (bridge, socket)
    }

    /// Poll a condition fed by a fire-and-forget task. Returns as soon as it holds, so a
    /// passing run costs nothing; the deadline only bounds a broken one.
    private func waitUntil(_ description: String, timeout: TimeInterval = 10,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for \(description)")
    }

    func testDelegateTaskCorrelatesTheAnswerByRunId() async throws {
        let (bridge, socket) = makeBridge { id, _ in
            [GatewayScript.ok(replyTo: id, payload: ["runId": "run-1", "status": "ok"]),
             GatewayScript.chat(runId: "run-1", seq: 1, state: "delta", text: "Hello "),
             GatewayScript.chat(runId: "run-1", seq: 2, state: "delta", text: "Hello from the gateway."),
             GatewayScript.chat(runId: "run-1", seq: 3, state: "final", text: "Hello from the gateway.")]
        }
        var chunks: [String] = []
        bridge.onStreamChunk = { chunks.append($0) }

        let result = await bridge.delegateTask(task: "What time is it?")

        guard case .success(let answer) = result else { return XCTFail("expected the run's final text, got \(result)") }
        XCTAssertEqual(answer, "Hello from the gateway.")
        XCTAssertEqual(chunks.joined(), "Hello from the gateway.")
        XCTAssertEqual(bridge.lastToolCallStatus, .completed("execute"))
        XCTAssertNotNil(bridge.gatewayHello)
        XCTAssertFalse(bridge.supports("tools.available"))

        // The handshake as it went over the wire.
        let connect = try XCTUnwrap(socket.sentRequests(method: "connect").first)
        let params = try XCTUnwrap(connect["params"] as? [String: Any])
        XCTAssertNil(params["deviceCapabilities"])
        XCTAssertEqual(params["minProtocol"] as? Int, 4)
        let client = try XCTUnwrap(params["client"] as? [String: Any])
        XCTAssertEqual(client["deviceFamily"] as? String, OpenClawDeviceIdentity.deviceFamilyLabel())
        let device = try XCTUnwrap(params["device"] as? [String: Any])
        XCTAssertEqual(device["signedAt"] as? Int, GatewayScript.challengeTs, "signed at the challenge's clock")
        XCTAssertEqual(device["nonce"] as? String, "nonce-1")

        // The send as it went over the wire.
        let send = try XCTUnwrap(socket.sentRequests(method: "sessions.send").first)
        let sendParams = try XCTUnwrap(send["params"] as? [String: Any])
        XCTAssertEqual(Set(sendParams.keys), ["key", "message", "agentId", "idempotencyKey"])
        XCTAssertEqual(sendParams["key"] as? String, bridge.currentSessionKey)
        XCTAssertEqual(sendParams["message"] as? String, "What time is it?")
        XCTAssertNil(sendParams["text"], "the pre-2.0 key")
        XCTAssertTrue(socket.sentRequests(method: "tools.available").isEmpty, "gone from the gateway; never asked")
    }

    func testToolCatalogComesFromToolsEffective() async {
        let (bridge, socket) = makeBridge { id, _ in
            [GatewayScript.ok(replyTo: id, payload: ["runId": "r", "status": "ok"]),
             GatewayScript.chat(runId: "r", seq: 1, state: "final", text: "ok")]
        }
        _ = await bridge.delegateTask(task: "x")
        // The catalog query is fire-and-forget after connect; wait for it, don't race it.
        await waitUntil("the tool catalog") { !bridge.availableToolNames.isEmpty }
        XCTAssertEqual(bridge.availableToolNames, ["web_search"])
        XCTAssertEqual(socket.sentRequests(method: "tools.effective").count, 1)
    }

    func testTimedOutRunIsParkedAndAnswersLate() async throws {
        let (bridge, socket) = makeBridge { id, _ in
            [GatewayScript.ok(replyTo: id, payload: ["runId": "slow-1", "status": "ok"])]
        }
        bridge.replyTimeout = 0.2
        let late = expectation(description: "late answer announced")
        var lateText: String?
        bridge.onLateResult = { lateText = $0; late.fulfill() }

        let result = await bridge.delegateTask(task: "Plan my week")
        guard case .success(let text) = result else { return XCTFail("expected a parked success, got \(result)") }
        XCTAssertTrue(text.contains("still working"), "the model is told to wait, not to invent")
        XCTAssertEqual(bridge.runTracker.state(runId: "slow-1"), ChatRunTracker.RunState(phase: .running))

        socket.push(GatewayScript.chat(runId: "slow-1", seq: 1, state: "final", text: "Here is your week."))
        await fulfillment(of: [late], timeout: 2)
        XCTAssertEqual(lateText, "Here is your week.")
    }

    /// The gateway aborts the run in the same breath as accepting it: the `chat` event is on the
    /// wire before `delegateTask` resumes to look at the response. The run must already be tracked
    /// by then — the bridge registers it as the response is routed — or the terminal state lands on
    /// an unknown run, is dropped, and the caller waits out `replyTimeout` for an answer that
    /// already came and went.
    func testAbortedRunIsAFailure() async {
        let (bridge, _) = makeBridge { id, _ in
            [GatewayScript.ok(replyTo: id, payload: ["runId": "a", "status": "ok"]),
             GatewayScript.chat(runId: "a", seq: 1, state: "aborted", text: nil)]
        }
        // Nothing here waits on a clock: the abort is queued before the send returns. The bound
        // exists so a dropped terminal event fails in seconds instead of parking for two minutes.
        bridge.replyTimeout = 5

        let result = await bridge.delegateTask(task: "x")

        guard case .failure(let message) = result else {
            return XCTFail("expected failure, got \(result) — the abort was not correlated to the run")
        }
        XCTAssertTrue(message.contains("stopped"))
        XCTAssertEqual(bridge.runTracker.state(runId: "a"),
                       ChatRunTracker.RunState(phase: .aborted), "the abort is recorded against the run")
    }

    func testOversizeImageIsDroppedNotSent() async throws {
        let (bridge, socket) = makeBridge { id, _ in
            [GatewayScript.ok(replyTo: id, payload: ["runId": "i", "status": "ok"]),
             GatewayScript.chat(runId: "i", seq: 1, state: "final", text: "seen")]
        }
        // hello-ok advertises maxImageBytes: 16 — a 17-byte "image" is over the ceiling.
        _ = await bridge.delegateTask(task: "look", imageData: Data(count: 17))
        let send = try XCTUnwrap(socket.sentRequests(method: "sessions.send").first)
        XCTAssertNil((send["params"] as? [String: Any])?["attachments"])

        _ = await bridge.delegateTask(task: "look again", imageData: Data(count: 16))
        let second = try XCTUnwrap(socket.sentRequests(method: "sessions.send").last)
        let attachments = try XCTUnwrap((second["params"] as? [String: Any])?["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.first?["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual(attachments.first?["sizeBytes"] as? Int, 16)
    }

    func testMethodsAbsentFromTheCatalogAreRefusedWithoutARoundTrip() async {
        let (bridge, socket) = makeBridge(methods: ["sessions.send"]) { id, _ in
            [GatewayScript.ok(replyTo: id, payload: ["runId": "r", "status": "ok"]),
             GatewayScript.chat(runId: "r", seq: 1, state: "final", text: "ok")]
        }
        _ = await bridge.delegateTask(task: "connect first")
        let result = await bridge.createCronJob(expression: "0 7 * * *", task: "brief")
        guard case .failure(let message) = result else { return XCTFail("expected refusal") }
        XCTAssertTrue(message.contains("does not offer"))
        XCTAssertTrue(socket.sentRequests(method: "cron.add").isEmpty)
        XCTAssertTrue(socket.sentRequests(method: "cron.create").isEmpty)
    }

    func testMemoryStoreIsHonestlyUnsupported() async {
        let (bridge, socket) = makeBridge { id, _ in [GatewayScript.ok(replyTo: id, payload: ["runId": "r"])] }
        let result = await bridge.storeMemory(content: "likes tea")
        guard case .failure(let message) = result else { return XCTFail("expected refusal") }
        XCTAssertTrue(message.contains("no memory store"))
        XCTAssertTrue(socket.sentRequests(method: "memory.store").isEmpty)
    }
}

// MARK: - Event client

/// Drives `OpenClawEventClient` through the same handshake and one heartbeat.
final class OpenClawEventClientScriptedSocketTests: XCTestCase {

    private var priorAgentMode = false
    private var priorGateways: [GatewayConfig] = []

    override func setUp() {
        super.setUp()
        priorAgentMode = Config.agentModeEnabled
        priorGateways = Config.savedGateways
        Config.setAgentModeEnabled(true)
        Config.setSavedGateways([])
        Config.setOpenClawEnabled(true)
        Config.setOpenClawGatewayToken("shared-token")
        Config.setOpenClawConnectionMode(.lan)
        Config.setOpenClawLanHost("http://127.0.0.1")
        Config.setOpenClawPort(18789)
    }

    override func tearDown() {
        Config.setAgentModeEnabled(priorAgentMode)
        Config.setSavedGateways(priorGateways)
        Config.setOpenClawEnabled(false)
        Config.setOpenClawGatewayToken("")
        super.tearDown()
    }

    func testHandshakeThenHeartbeatIsSpoken() async throws {
        let socket = ScriptedGatewaySocket(initialFrames: [GatewayScript.challenge])
        socket.onRequest = { frame in
            guard (frame["method"] as? String) == "connect" else { return [] }
            return [GatewayScript.helloOk(replyTo: frame["id"] as? String ?? "", methods: ["sessions.send"])]
        }
        let client = OpenClawEventClient(socketFactory: { _ in socket })
        let paired = expectation(description: "paired")
        client.onPairingStatusChange = { if $0 == .paired { paired.fulfill() } }
        let spoken = expectation(description: "heartbeat spoken")
        var heard: String?
        client.onNotification = { heard = $0; spoken.fulfill() }

        client.connect()
        await fulfillment(of: [paired], timeout: 2)

        let connect = try XCTUnwrap(socket.sentRequests(method: "connect").first)
        let params = try XCTUnwrap(connect["params"] as? [String: Any])
        XCTAssertEqual(params["role"] as? String, "operator")
        XCTAssertNil(params["deviceCapabilities"])
        let device = try XCTUnwrap(params["device"] as? [String: Any])
        XCTAssertEqual(device["signedAt"] as? Int, GatewayScript.challengeTs)
        XCTAssertEqual(client.gatewayHello?.role, "operator")

        socket.push(["type": "event", "event": "heartbeat",
                     "payload": ["ts": 1, "status": "sent", "preview": "Your 3pm moved to 4.", "silent": false]])
        await fulfillment(of: [spoken], timeout: 2)
        XCTAssertEqual(heard, "Your 3pm moved to 4.")

        // No node role → no device event frames; the gateway would refuse them.
        XCTAssertTrue(socket.sentRequests(method: "node.event").isEmpty)
        client.disconnect()
    }

    func testPendingApprovalIsSurfacedNotFatal() async throws {
        let socket = ScriptedGatewaySocket(initialFrames: [GatewayScript.challenge])
        socket.onRequest = { frame in
            guard (frame["method"] as? String) == "connect" else { return [] }
            return [["type": "res", "id": frame["id"] as? String ?? "", "ok": false,
                     "error": ["code": "INVALID_REQUEST", "message": "pairing required",
                               "details": ["code": "PAIRING_REQUIRED", "requestId": "req-1", "pauseReconnect": true]]]]
        }
        let client = OpenClawEventClient(socketFactory: { _ in socket })
        let waiting = expectation(description: "waiting for approval")
        client.onPairingStatusChange = { if $0 == .waitingApproval { waiting.fulfill() } }
        client.connect()
        await fulfillment(of: [waiting], timeout: 2)
        client.disconnect()
    }
}
