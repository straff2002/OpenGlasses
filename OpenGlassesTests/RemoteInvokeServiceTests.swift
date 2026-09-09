import XCTest
@testable import OpenGlasses

/// Plan BH — the assembled pipeline: inbound frame → parse → policy → execute → reply envelope,
/// with every exchange audited. Fresh instances + recorder closures throughout (house rule:
/// never exercise `.shared` services in unit tests).
@MainActor
final class RemoteInvokeServiceTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "remoteInvokeAuditLog")
    }

    /// Executor whose stages record and return canned outcomes; only the closures a test
    /// exercises matter, the rest fail loudly if reached.
    private func recorderExecutor(
        log: Box<[String]>,
        confirmCapture: @escaping @MainActor (String) async -> Bool = { _ in true }
    ) -> RemoteCommandExecutor {
        RemoteCommandExecutor(deps: .init(
            confirmCapture: { summary in log.value.append("confirm(\(summary))"); return await confirmCapture(summary) },
            announce: { text in log.value.append("announce(\(text))") },
            capturePhoto: { log.value.append("capturePhoto") },
            startAudioRecording: { log.value.append("startAudio") },
            stopAudioRecording: { log.value.append("stopAudio"); return "rec.m4a" },
            startVideo: { log.value.append("startVideo") },
            stopVideo: { log.value.append("stopVideo"); return nil },
            startTranslation: { s, t in log.value.append("startTranslation(\(s ?? "auto")→\(t ?? "en"))") },
            stopTranslation: { log.value.append("stopTranslation") },
            startTranscription: { log.value.append("startTranscription") },
            stopTranscription: { log.value.append("stopTranscription") },
            speak: { text in log.value.append("speak(\(text))") },
            displayShow: { text, _ in log.value.append("displayShow(\(text))"); return true },
            displayClear: { log.value.append("displayClear") },
            deviceStatus: { ["glasses_connected": "true"] },
            deviceCapabilities: { ["display": "false"] },
            addNote: { text in log.value.append("addNote(\(text))"); return "Saved" },
            getTranscript: { log.value.append("getTranscript"); return "hello world" },
            stopAll: { log.value.append("stopAll") }
        ))
    }

    private func service(
        agentMode: Bool = true,
        toggles: RemoteCommandPolicy.Toggles = .init(observe: true, output: true, capture: true),
        log: Box<[String]> = Box([]),
        confirmCapture: @escaping @MainActor (String) async -> Bool = { _ in true }
    ) -> RemoteInvokeService {
        RemoteInvokeService(
            environment: .init(
                agentModeEnabled: { agentMode },
                toggles: { toggles },
                now: { self.t0 }
            ),
            executor: recorderExecutor(log: log, confirmCapture: confirmCapture)
        )
    }

    private func invoke(_ action: String, id: String = "r1", extra: [String: Any] = [:]) -> [String: Any] {
        var params: [String: Any] = ["action": action]
        params.merge(extra) { a, _ in a }
        return ["type": "req", "id": id, "method": "node.invoke", "params": params]
    }

    // MARK: - Reply envelopes

    func testAllowedCommandExecutesAndRepliesOkWithPayload() async {
        let log = Box<[String]>([])
        let svc = service(log: log)
        let reply = await svc.handleFrame(invoke("device_status"))

        XCTAssertEqual(reply?["type"] as? String, "res")
        XCTAssertEqual(reply?["id"] as? String, "r1")
        XCTAssertEqual(reply?["ok"] as? Bool, true)
        XCTAssertEqual((reply?["payload"] as? [String: String])?["glasses_connected"], "true")
    }

    func testAgentModeOffDeniesWithStructuredReasonAndNeverTouchesTheExecutor() async {
        let log = Box<[String]>([])
        let svc = service(agentMode: false, log: log)
        let reply = await svc.handleFrame(invoke("speak", extra: ["text": "hi"]))

        XCTAssertEqual(reply?["ok"] as? Bool, false)
        let error = reply?["error"] as? [String: String]
        XCTAssertEqual(error?["code"], "denied.agent_mode_off")
        XCTAssertTrue(log.value.isEmpty, "the executor must be unreachable when Agent Mode is off")
    }

    func testCaptureDisabledDeniesBeforeTheExecutor() async {
        let log = Box<[String]>([])
        let svc = service(toggles: .defaults, log: log)   // defaults: capture off
        let reply = await svc.handleFrame(invoke("capture_photo"))

        XCTAssertEqual((reply?["error"] as? [String: String])?["code"], "denied.class_disabled.capture")
        XCTAssertTrue(log.value.isEmpty)
    }

    func testUnsupportedAndMalformedGetRepliesNotSilence() async {
        let svc = service()
        let unsupported = await svc.handleFrame(invoke("warp_drive"))
        XCTAssertEqual((unsupported?["error"] as? [String: String])?["code"], "unsupported_action")

        let malformed = await svc.handleFrame(invoke("speak"))   // no text
        XCTAssertEqual((malformed?["error"] as? [String: String])?["code"], "malformed_request")
    }

    func testNonRequestFramesAreIgnored() async {
        let svc = service()
        let reply = await svc.handleFrame(["type": "event", "event": "heartbeat"])
        XCTAssertNil(reply)
    }

    // MARK: - Capture confirmation flow

    func testCaptureConfirmsThenAnnouncesThenActsInThatOrder() async {
        let log = Box<[String]>([])
        let svc = service(log: log)
        _ = await svc.handleFrame(invoke("capture_photo"))

        XCTAssertEqual(log.value, [
            "confirm(Remote agent wants to take a photo)",
            "announce(Remote photo)",
            "capturePhoto",
        ], "capture must confirm, then announce, then act — nothing remote is silent")
    }

    func testUserDeclineFailsTheRequestAndSkipsTheSensor() async {
        let log = Box<[String]>([])
        let svc = service(log: log, confirmCapture: { _ in false })
        let reply = await svc.handleFrame(invoke("start_audio_recording"))

        XCTAssertEqual((reply?["error"] as? [String: String])?["code"], "execution_failed")
        XCTAssertEqual((reply?["error"] as? [String: String])?["message"], "User declined the request")
        XCTAssertFalse(log.value.contains("startAudio"), "declined capture must never start the sensor")
        XCTAssertFalse(log.value.contains(where: { $0.hasPrefix("announce") }))
    }

    func testOutputCommandsDoNotRequireConfirmation() async {
        let log = Box<[String]>([])
        let svc = service(log: log)
        _ = await svc.handleFrame(invoke("speak", extra: ["text": "hello"]))
        XCTAssertEqual(log.value, ["speak(hello)"])
    }

    // MARK: - Transcript reads are capture-class

    func testTranscriptReadConfirmsAnnouncesThenReads() async {
        let log = Box<[String]>([])
        let svc = service(log: log)
        let reply = await svc.handleFrame(invoke("get_transcript"))

        XCTAssertEqual(log.value, [
            "confirm(Remote agent wants to read the recent transcript)",
            "announce(Remote transcript read)",
            "getTranscript",
        ], "reading back recorded speech must confirm, then announce, then read")
        XCTAssertEqual((reply?["payload"] as? [String: String])?["transcript"], "hello world")
    }

    func testTranscriptReadIsDeniedByDefault() async {
        let log = Box<[String]>([])
        let svc = service(toggles: .defaults, log: log)   // defaults: capture off
        let reply = await svc.handleFrame(invoke("get_transcript"))

        XCTAssertEqual((reply?["error"] as? [String: String])?["code"], "denied.class_disabled.capture")
        XCTAssertTrue(log.value.isEmpty,
                      "with the shipping defaults a gateway agent must not read the room's speech")
    }

    // MARK: - Audit trail

    func testEveryExchangeIsAudited() async {
        let svc = service(toggles: .defaults)
        _ = await svc.handleFrame(invoke("device_status"))          // allowed
        _ = await svc.handleFrame(invoke("capture_photo"))          // denied (capture off)
        _ = await svc.handleFrame(invoke("warp_drive"))             // unsupported
        _ = await svc.handleFrame(invoke("speak"))                  // malformed

        XCTAssertEqual(svc.auditLog.count, 4)
        // Newest first.
        XCTAssertEqual(svc.auditLog[3].action, "device_status")
        XCTAssertEqual(svc.auditLog[3].disposition, "allowed")
        XCTAssertEqual(svc.auditLog[2].disposition, "denied: denied.class_disabled.capture")
        XCTAssertEqual(svc.auditLog[1].disposition, "unsupported")
        XCTAssertTrue(svc.auditLog[0].disposition.hasPrefix("malformed"))
    }

    func testAuditPersistsAcrossInstances() async {
        let first = service()
        _ = await first.handleFrame(invoke("device_status"))
        let second = service()
        XCTAssertEqual(second.auditLog.first?.action, "device_status")
    }

    // MARK: - Origin attribution (Plan BN P2)

    func testAuditEntryCarriesOrigin() async {
        let svc = service()
        _ = await svc.handleFrame(invoke("device_status"))                                 // gateway (default)
        _ = await svc.handleFrame(invoke("device_status"), origin: .mcpPeer(id: "acme"))    // peer
        XCTAssertEqual(svc.auditLog[0].origin, "peer:acme", "newest is the peer call")
        XCTAssertEqual(svc.auditLog[1].origin, "gateway")
    }

    func testPeerRateBudgetIsIndependentOfGateway() async {
        let svc = service()   // capture on; fixed clock, so no refill
        // Exhaust the gateway capture bucket (capacity 2).
        _ = await svc.handleFrame(invoke("capture_photo"))
        _ = await svc.handleFrame(invoke("capture_photo"))
        let gatewayDenied = await svc.handleFrame(invoke("capture_photo"))
        XCTAssertEqual((gatewayDenied?["error"] as? [String: String])?["code"], "denied.rate_limited.capture")

        // A peer arriving now has its own full capture budget — not starved by the gateway.
        let peerOk = await svc.handleFrame(invoke("capture_photo"), origin: .mcpPeer(id: "acme"))
        XCTAssertEqual(peerOk?["ok"] as? Bool, true)
    }

    func testPeerOriginPersistsAcrossInstances() async {
        let first = service()
        _ = await first.handleFrame(invoke("device_status"), origin: .mcpPeer(id: "acme"))
        let second = service()
        XCTAssertEqual(second.auditLog.first?.origin, "peer:acme")
    }
}
