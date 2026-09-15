import XCTest
@testable import OpenGlasses

/// Plan EX — the acceptance test, one backend at a time.
///
/// Each fixture plants a unique marker in a conversation, resets through the coordinator, and then
/// asserts the marker is not in the next turn's context. That is the only question that matters:
/// a reset that clears the phone's screen while a backend keeps the conversation is the failure
/// this plan exists to close, and it is invisible from the phone.
///
/// Two backends are reasoned rather than round-tripped, and say so: the Gemini Live and OpenAI
/// Realtime session managers build a `RealtimeAudioEngine` at init, so they cannot be constructed
/// headlessly. Their adapters are tested against the seam instead — ordering, the resumption-handle
/// rule, and the refusal to reconnect — and the handle rule is additionally pinned on the real
/// `GeminiLiveService`, which *is* constructible.
@MainActor
final class ConversationResetMarkerTests: XCTestCase {

    private let marker = "PINEAPPLE-QUARTZ-4417"

    // MARK: - Shared coordinator wiring

    private final class ResetProbe {
        var threadsStarted = 0
        var reports: [ConversationResetReport] = []
    }

    private func makeCoordinator(plan: [ConversationBackendID],
                                 adapters: [ConversationBackendID: any ConversationContextResetting],
                                 llm: LLMService? = nil,
                                 probe: ResetProbe) -> ConversationResetCoordinator {
        let coordinator = ConversationResetCoordinator()
        coordinator.configure(.init(
            plan: { plan },
            adapter: { adapters[$0] },
            awaitTurnBoundary: { await ConversationTurnBoundary.wait { llm?.isTurnInFlight ?? false } },
            clearLocalHistory: { llm?.requestHistoryClear() },
            startSavedThread: { probe.threadsStarted += 1 },
            stopSpeech: {},
            announce: { _ in },
            record: { probe.reports.append($0) }))
        return coordinator
    }

    // MARK: - Direct / cloud

    /// The phone's own history is what every cloud request body is built from, so "the next turn's
    /// context" is literally this array.
    func testDirectCloudHistoryLosesTheMarkerAndTheNextTurnStartsClean() async {
        let llm = LLMService()
        llm.resetConversationHistoryForTesting([
            (role: "user", content: "remember the code word \(marker)"),
            (role: "assistant", content: "Got it — \(marker).")])
        XCTAssertTrue(llm.conversationHistorySnapshotForTesting()
            .contains { $0.content.contains(marker) })

        let probe = ResetProbe()
        let coordinator = makeCoordinator(plan: [], adapters: [:], llm: llm, probe: probe)
        let report = await coordinator.requestReset(source: .voiceCommand)
        XCTAssertTrue(report.didRetireLocalContext)
        XCTAssertEqual(probe.threadsStarted, 1)

        XCTAssertTrue(llm.conversationHistorySnapshotForTesting().isEmpty)

        // The next turn's context is exactly the next turn.
        llm.recordExternalExchange(user: "what's the code word?", assistant: "I don't have one.")
        let next = llm.conversationHistorySnapshotForTesting()
        XCTAssertEqual(next.count, 2)
        XCTAssertFalse(next.contains { $0.content.contains(marker) },
                       "the marker survived into the next request body")
    }

    /// A reset requested while a turn is in flight waits for it: clearing mid-turn would orphan a
    /// pending tool_result, and — worse for the marker — the turn appends its exchange *after* the
    /// clear, so the "reset" conversation would start holding the turn it was meant to discard.
    func testAResetRequestedMidTurnDoesNotClearUnderneathTheTurn() async {
        let llm = LLMService()
        let probe = ResetProbe()
        let coordinator = ConversationResetCoordinator()

        var busy = true
        var log: [String] = []
        coordinator.configure(.init(
            plan: { [] },
            adapter: { _ in nil },
            awaitTurnBoundary: {
                await ConversationTurnBoundary.wait { busy }
                log.append("turnFinished")
            },
            clearLocalHistory: {
                log.append("clear")
                llm.requestHistoryClear()
            },
            startSavedThread: { probe.threadsStarted += 1 },
            stopSpeech: {}, announce: { _ in }, record: { probe.reports.append($0) }))

        async let run = coordinator.requestReset(source: .modelToolCall)
        await waitUntil("the reset to reach the turn barrier") { coordinator.phase == .inFlight }

        // The turn is still running, and it writes its exchange *after* the reset was asked for.
        llm.resetConversationHistoryForTesting([(role: "assistant", content: marker)])
        busy = false
        _ = await run

        XCTAssertEqual(log, ["turnFinished", "clear"],
                       "the clear must land after the turn, never underneath it")
        XCTAssertTrue(llm.conversationHistorySnapshotForTesting().isEmpty,
                      "a turn that finished after the request still belongs to the retired context")
        XCTAssertEqual(probe.threadsStarted, 1)
    }

    // MARK: - Local / offline

    /// Yields a scripted chunk sequence per generation pass and records what each pass was asked.
    /// (The on-device turn cannot run for real here: MLX needs Metal, which the simulator has not.)
    private final class ScriptedBackend: LocalInferenceBackend, @unchecked Sendable {
        let runtime: LocalModelRuntime
        private let lock = NSLock()
        private var _scripts: [[String]]
        private var _requests: [LocalGenerationRequest] = []

        init(runtime: LocalModelRuntime = .mlx, scripts: [[String]]) {
            self.runtime = runtime
            self._scripts = scripts
        }

        var requests: [LocalGenerationRequest] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }

        private var _loaded: LocalLoadedModel?
        var loadedModel: LocalLoadedModel? {
            lock.lock(); defer { lock.unlock() }
            return _loaded
        }

        func load(_ installation: InstalledLocalModel,
                  configuration: LocalLoadConfiguration) async throws -> LocalLoadedModel {
            let loaded = LocalLoadedModel(id: installation.id, runtime: runtime,
                                          contextLength: configuration.contextLength,
                                          capabilities: [.text, .toolFriendly])
            lock.lock(); _loaded = loaded; lock.unlock()
            return loaded
        }

        func generate(_ request: LocalGenerationRequest) -> AsyncThrowingStream<String, Error> {
            lock.lock()
            _requests.append(request)
            let script = _scripts.isEmpty ? [] : _scripts.removeFirst()
            lock.unlock()
            return AsyncThrowingStream { continuation in
                for piece in script {
                    request.previewSink?(piece)
                    continuation.yield(piece)
                }
                continuation.finish()
            }
        }

        func cancelGeneration() async {}
        func unload() async { lock.lock(); _loaded = nil; lock.unlock() }
    }

    private func makeLocalHarness(scripts: [[String]]) -> (LLMService, ScriptedBackend, ModelConfig) {
        let modelID = LocalModelID("fixture/ex-conversation-reset")
        let backend = ScriptedBackend(scripts: scripts)
        let descriptor = LocalModelDescriptor(
            id: modelID, displayName: "Fixture", runtime: .mlx,
            repositoryID: modelID.rawValue, revision: "fixture000",
            capabilities: [.text, .toolFriendly], contextLength: 4096,
            estimatedWeightsBytes: 1_000, estimatedWorkingBytes: 1_000,
            minimumHeadroomBytes: 2_000)
        let installation = InstalledLocalModel(
            descriptor: descriptor,
            storage: .managed(directoryName: modelID.storageComponent),
            installedAt: Date(timeIntervalSince1970: 0))

        let service = LLMService()
        service.localLLMService = LocalLLMService()
        service.localTurnOverridesForTesting = .init(selectedID: modelID,
                                                     installation: installation,
                                                     coordinator: LocalInferenceCoordinator(backends: [backend]))
        service.resetConversationHistoryForTesting()
        let config = ModelConfig(id: "fixture-local", name: "Fixture",
                                 provider: LLMProvider.local.rawValue, apiKey: "",
                                 model: modelID.rawValue, baseURL: "")
        return (service, backend, config)
    }

    func testLocalOfflineTurnAfterAResetIsNotShownTheMarker() async throws {
        let wasCoordinator = Config.localRuntimeCoordinatorEnabled
        let wasWebFallback = Config.localWebSearchFallbackEnabled
        Config.localRuntimeCoordinatorEnabled = true
        Config.localWebSearchFallbackEnabled = false
        defer {
            Config.localRuntimeCoordinatorEnabled = wasCoordinator
            Config.localWebSearchFallbackEnabled = wasWebFallback
        }

        let (llm, backend, config) = makeLocalHarness(scripts: [["Noted."], ["I have no idea."]])

        _ = try await llm.sendLocalForTesting("the code word is \(marker)",
                                              config: config, includeTools: false)
        XCTAssertTrue(llm.conversationHistorySnapshotForTesting()
            .contains { $0.content.contains(marker) })

        let probe = ResetProbe()
        let coordinator = makeCoordinator(plan: [], adapters: [:], llm: llm, probe: probe)
        await coordinator.requestReset(source: .voiceCommand)

        _ = try await llm.sendLocalForTesting("what is the code word?",
                                              config: config, includeTools: false)

        let lastPrompt = backend.requests.last?.messages.map(\.content).joined(separator: "\n") ?? ""
        XCTAssertFalse(lastPrompt.contains(marker),
                       "the on-device model was still shown the retired conversation")
        XCTAssertFalse(llm.conversationHistorySnapshotForTesting()
            .contains { $0.content.contains(marker) })
    }

    // MARK: - Gateway agent

    private var priorAgentMode = false
    private var priorGateways: [GatewayConfig] = []
    private var priorGeneration: Any?
    private let sessionGenerationKey = "openClawSessionGeneration"

    private func setUpGateway() {
        priorAgentMode = Config.agentModeEnabled
        priorGateways = Config.savedGateways
        priorGeneration = UserDefaults.standard.object(forKey: sessionGenerationKey)
        UserDefaults.standard.removeObject(forKey: sessionGenerationKey)
        Config.setAgentModeEnabled(true)
        Config.setSavedGateways([])
        Config.setOpenClawEnabled(true)
        Config.setOpenClawGatewayToken("shared-token")
        Config.setOpenClawConnectionMode(.lan)
        Config.setOpenClawLanHost("http://127.0.0.1")
        Config.setOpenClawPort(18789)
    }

    private func tearDownGateway() {
        Config.setAgentModeEnabled(priorAgentMode)
        Config.setSavedGateways(priorGateways)
        Config.setOpenClawEnabled(false)
        Config.setOpenClawGatewayToken("")
        if let saved = priorGeneration as? Int {
            UserDefaults.standard.set(saved, forKey: sessionGenerationKey)
        } else {
            UserDefaults.standard.removeObject(forKey: sessionGenerationKey)
        }
    }

    /// The gateway keeps its context under a session key. After a reset every later message is
    /// addressed to a *different* key, so the session holding the marker can never be reached
    /// again — including by a straggler from the old turn.
    func testGatewayMessagesAfterAResetGoToAKeyTheMarkerNeverReached() async {
        setUpGateway()
        defer { tearDownGateway() }

        let socket = ScriptedGatewaySocket(initialFrames: [GatewayScript.challenge])
        socket.onRequest = { frame in
            let id = frame["id"] as? String ?? ""
            switch frame["method"] as? String {
            case "connect":
                return [GatewayScript.helloOk(replyTo: id, methods: ["sessions.send"])]
            case "sessions.send":
                let runId = "run-\(id)"
                return [GatewayScript.ok(replyTo: id, payload: ["runId": runId, "status": "ok"]),
                        GatewayScript.chat(runId: runId, seq: 1, state: "final", text: "Noted.")]
            default:
                return [["type": "res", "id": id, "ok": false,
                         "error": ["code": "UNKNOWN_METHOD", "message": "nope"]]]
            }
        }
        let bridge = OpenClawBridge(socketFactory: { _ in socket })

        _ = await bridge.delegateTask(task: "the code word is \(marker)")
        let keyBefore = bridge.currentSessionKey

        let probe = ResetProbe()
        let coordinator = makeCoordinator(
            plan: [.openClaw],
            adapters: [.openClaw: GatewaySessionResetAdapter(gateway: bridge)],
            probe: probe)
        let report = await coordinator.requestReset(source: .voiceCommand)
        XCTAssertEqual(report.outcomes.last, .completed(.openClaw))
        XCTAssertTrue(report.didRetireLocalContext)

        _ = await bridge.delegateTask(task: "what is the code word?")

        let sends = socket.sentRequests(method: "sessions.send")
        XCTAssertEqual(sends.count, 2)
        let keys = sends.map { ($0["params"] as? [String: Any])?["key"] as? String }
        XCTAssertEqual(keys.first ?? nil, keyBefore)
        XCTAssertNotEqual(keys.first ?? nil, keys.last ?? nil,
                          "the session key must rotate, or the gateway keeps the conversation")
        XCTAssertNotEqual(bridge.currentSessionKey, keyBefore)

        // Nothing under the new key ever carried the marker.
        for send in sends {
            let params = send["params"] as? [String: Any] ?? [:]
            let message = params["message"] as? String ?? ""
            if (params["key"] as? String) != keyBefore {
                XCTAssertFalse(message.contains(marker),
                               "the marker was re-sent under the fresh session key")
            }
        }
    }

    // MARK: - Agent bridge

    /// A `HermesSocket` fed from a script: records every frame the client sends, answers the ones
    /// the fixture wants answered.
    private final class ScriptedHermesSocket: HermesSocket, @unchecked Sendable {
        private let lock = NSLock()
        private var inbound: [String] = []
        private var waiters: [CheckedContinuation<HermesFrame, Error>] = []
        private var _sent: [String] = []
        private var cancelled = false

        /// Answers a client frame with zero or more frames the bridge sends back.
        var onSend: (([String: Any]) -> [String])?

        var sentFrames: [String] {
            lock.lock(); defer { lock.unlock() }
            return _sent
        }

        var sentTypes: [String] {
            sentFrames.compactMap {
                guard let data = $0.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                return json["type"] as? String
            }
        }

        func push(_ text: String) {
            lock.lock()
            if !waiters.isEmpty {
                let waiter = waiters.removeFirst()
                lock.unlock()
                waiter.resume(returning: .text(text))
                return
            }
            inbound.append(text)
            lock.unlock()
        }

        func send(_ text: String) async throws {
            lock.lock()
            _sent.append(text)
            let handler = onSend
            lock.unlock()
            let json = (text.data(using: .utf8).flatMap {
                try? JSONSerialization.jsonObject(with: $0)
            } as? [String: Any]) ?? [:]
            let replies = handler?(json) ?? []
            guard !replies.isEmpty else { return }
            // Answer on a later turn of the loop, like a real bridge would: `ask` registers its
            // continuation *after* the send returns, so a reply pushed synchronously here would
            // arrive before anything was waiting for it and be dropped.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000)
                replies.forEach { self?.push($0) }
            }
        }

        func receive() async throws -> HermesFrame {
            lock.lock()
            if cancelled { lock.unlock(); throw CancellationError() }
            if !inbound.isEmpty {
                let next = inbound.removeFirst()
                lock.unlock()
                return .text(next)
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

    func testBridgeSeesTheResetFrameBeforeTheNextQuery() async throws {
        let wasEnabled = Config.hermesBridgeEnabled
        let wasHost = Config.hermesBridgeHost
        Config.setHermesBridgeEnabled(true)
        Config.setHermesBridgeHost("127.0.0.1")
        defer {
            Config.setHermesBridgeEnabled(wasEnabled)
            Config.setHermesBridgeHost(wasHost)
        }

        let socket = ScriptedHermesSocket()
        socket.onSend = { frame in
            guard frame["type"] as? String == "query" else { return [] }
            return [#"{"type":"response","text":"Noted.","tts":false}"#]
        }
        let bridge = HermesBridgeService(socketFactory: { _ in socket })
        bridge.connect()

        _ = try await bridge.ask("the code word is \(marker)")

        let probe = ResetProbe()
        let coordinator = makeCoordinator(
            plan: [.hermes],
            adapters: [.hermes: BridgeSessionResetAdapter(bridge: bridge)],
            probe: probe)
        let report = await coordinator.requestReset(source: .voiceCommand)

        // The protocol has no acknowledgement for `new_session`, so the honest outcome is
        // "issued", not "confirmed" — and the confirmation the wearer hears is downgraded to match.
        XCTAssertEqual(report.outcomes.last,
                       .issuedUnverified(.hermes, note: "the bridge protocol does not acknowledge a reset"))
        XCTAssertTrue(report.didRetireLocalContext)
        XCTAssertEqual(report.unverified, [.hermes])

        _ = try await bridge.ask("what is the code word?")

        XCTAssertEqual(socket.sentTypes, ["query", "new_session", "query"],
                       "the bridge must be told to forget before it is asked anything else")
        let afterReset = socket.sentFrames.drop { !$0.contains("new_session") }.dropFirst()
        XCTAssertFalse(afterReset.contains { $0.contains(marker) })
    }

    func testBridgeResetFailsHonestlyWhenTheBridgeIsNotConnected() async {
        let bridge = HermesBridgeService(socketFactory: { _ in ScriptedHermesSocket() })
        let probe = ResetProbe()
        let coordinator = makeCoordinator(
            plan: [.hermes],
            adapters: [.hermes: BridgeSessionResetAdapter(bridge: bridge)],
            probe: probe)

        let report = await coordinator.requestReset(source: .voiceCommand)

        XCTAssertFalse(report.didRetireLocalContext,
                       "the phone must not be cleared while the bridge still holds the conversation")
        XCTAssertEqual(probe.threadsStarted, 0)
        XCTAssertEqual(report.heldBack, [.hermes])
    }

    // MARK: - Live sessions (reasoned against the seam)

    /// Records what the adapter asked a live session to do. Stands in for the session managers,
    /// which construct a `RealtimeAudioEngine` at init and cannot exist in a headless test.
    private final class FakeLiveSession: RealtimeSessionResetting {
        var isSessionActive: Bool
        var holdsResumableContext: Bool
        /// Set when the teardown is supposed to fail to drop the handle.
        var keepsHandleOnStop = false
        var comesBackUp = true
        private(set) var calls: [String] = []

        init(isActive: Bool, holdsHandle: Bool) {
            self.isSessionActive = isActive
            self.holdsResumableContext = holdsHandle
        }

        func stopLiveSession() {
            calls.append("stop")
            isSessionActive = false
            if !keepsHandleOnStop { holdsResumableContext = false }
        }

        func startLiveSession() async {
            calls.append("start")
            isSessionActive = comesBackUp
        }
    }

    func testLiveSessionResetStopsBeforeItStartsAndReportsCompleted() async {
        let session = FakeLiveSession(isActive: true, holdsHandle: true)
        let adapter = RealtimeSessionResetAdapter(backend: .geminiLive, session: session)

        let outcome = await adapter.resetConversationContext()

        XCTAssertEqual(outcome, .completed(.geminiLive))
        XCTAssertEqual(session.calls, ["stop", "start"])
        XCTAssertFalse(session.holdsResumableContext)
    }

    func testLiveSessionResetRefusesToReconnectWithASurvivingResumptionHandle() async {
        let session = FakeLiveSession(isActive: true, holdsHandle: true)
        session.keepsHandleOnStop = true
        let adapter = RealtimeSessionResetAdapter(backend: .geminiLive, session: session)

        let outcome = await adapter.resetConversationContext()

        XCTAssertEqual(outcome, .failed(.geminiLive, reason: "the session kept its resumption handle"))
        XCTAssertEqual(session.calls, ["stop"], "reconnecting would have restored the old context")
    }

    func testLiveSessionResetFailsWhenTheFreshSessionDoesNotComeBack() async {
        let session = FakeLiveSession(isActive: true, holdsHandle: false)
        session.comesBackUp = false
        let adapter = RealtimeSessionResetAdapter(backend: .openAIRealtime, session: session)

        let outcome = await adapter.resetConversationContext()

        XCTAssertEqual(outcome, .failed(.openAIRealtime, reason: "the fresh session did not come back up"))
    }

    func testAnIdleLiveSessionHasNothingToRetire() async {
        let session = FakeLiveSession(isActive: false, holdsHandle: false)
        let adapter = RealtimeSessionResetAdapter(backend: .openAIRealtime, session: session)

        let outcome = await adapter.resetConversationContext()
        XCTAssertEqual(outcome, .completed(.openAIRealtime))
        XCTAssertTrue(session.calls.isEmpty)
    }

    // MARK: - Helpers

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    /// The seam's central promise, pinned on the real service: a deliberate teardown drops the
    /// resumption handle, so the fresh session cannot be handed the retired conversation.
    func testGeminiLiveServiceDropsItsResumptionHandleOnDisconnect() {
        let service = GeminiLiveService()
        service.setResumptionHandleForTesting("handle-from-the-old-conversation")
        XCTAssertTrue(service.hasResumptionHandle)

        service.disconnect()

        XCTAssertFalse(service.hasResumptionHandle,
                       "a reconnect would have resumed the conversation the wearer just left")
    }
}
