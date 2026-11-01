#if !AVENKIN_PHONE_ONLY
import XCTest
import MWDATCamera
@testable import OpenGlasses

/// Field-hardening sweep: paused-aware stall recovery, the low-res/voice contention
/// floor, and the flag-gated two-phase Gemini Live tool-response shapes.
final class DATFieldHardeningTests: XCTestCase {

    // MARK: - Stall recovery vs temple-tap pause

    func testStallRecoverySkipsPausedStream() {
        XCTAssertFalse(StreamRecoveryPolicy.shouldRecoverFromStall(state: .paused),
                       "temple-tap pause is a system hold — recovery must wait it out")
    }

    func testStallRecoveryProceedsForActiveOrUnknownStates() {
        XCTAssertTrue(StreamRecoveryPolicy.shouldRecoverFromStall(state: .streaming))
        XCTAssertTrue(StreamRecoveryPolicy.shouldRecoverFromStall(state: .stopped))
        XCTAssertTrue(StreamRecoveryPolicy.shouldRecoverFromStall(state: .waitingForDevice))
        XCTAssertTrue(StreamRecoveryPolicy.shouldRecoverFromStall(state: nil),
                      "no stream reference must not suppress recovery")
    }

    // MARK: - Stream resolution contention floor

    func testLowResolutionFlooredWhenVoiceRidesGlasses() {
        XCTAssertEqual(
            StreamConfigPolicy.effectiveResolution(requested: "low", concurrentGlassesVoice: true),
            "medium",
            "low-res streaming shares the Bluetooth radio with the voice link")
    }

    func testResolutionUntouchedWithoutConcurrentVoice() {
        XCTAssertEqual(
            StreamConfigPolicy.effectiveResolution(requested: "low", concurrentGlassesVoice: false),
            "low")
    }

    func testHigherTiersNeverRemapped() {
        XCTAssertEqual(
            StreamConfigPolicy.effectiveResolution(requested: "medium", concurrentGlassesVoice: true),
            "medium")
        XCTAssertEqual(
            StreamConfigPolicy.effectiveResolution(requested: "high", concurrentGlassesVoice: true),
            "high")
    }

    // MARK: - Two-phase tool-response shapes

    private func functionResponse(in envelope: [String: Any]) -> [String: Any]? {
        ((envelope["toolResponse"] as? [String: Any])?["functionResponses"]
            as? [[String: Any]])?.first
    }

    func testDirectResponseKeepsPlainShape() {
        let envelope = ToolCallRouter.toolResponse(
            callId: "c1", name: "weather", payload: ["result": "sunny"], phase: .direct)
        let fr = functionResponse(in: envelope)
        XCTAssertEqual(fr?["id"] as? String, "c1")
        XCTAssertEqual(fr?["name"] as? String, "weather")
        XCTAssertEqual((fr?["response"] as? [String: Any])?["result"] as? String, "sunny")
        XCTAssertNil(fr?["willContinue"], "plain responses must not carry non-blocking fields")
        XCTAssertNil(fr?["scheduling"])
    }

    func testAckResponseKeepsCallOpenSilently() {
        let envelope = ToolCallRouter.toolResponse(
            callId: "c2", name: "slow_tool", payload: ["result": "working"], phase: .ack)
        let fr = functionResponse(in: envelope)
        XCTAssertEqual(fr?["willContinue"] as? Bool, true)
        XCTAssertEqual(fr?["scheduling"] as? String, "SILENT")
    }

    func testFinalAfterAckDefersDelivery() {
        let envelope = ToolCallRouter.toolResponse(
            callId: "c3", name: "slow_tool", payload: ["result": "done"], phase: .finalAfterAck)
        let fr = functionResponse(in: envelope)
        XCTAssertNil(fr?["willContinue"], "the final leg closes the call")
        XCTAssertEqual(fr?["scheduling"] as? String, "WHEN_IDLE",
                       "the result must wait for the user's turn, not interrupt it")
    }

    func testNonBlockingFlagDefaultsOff() {
        UserDefaults.standard.removeObject(forKey: "geminiNonBlockingToolsEnabled")
        XCTAssertFalse(Config.geminiNonBlockingToolsEnabled,
                       "payload-shape change must be opt-in until validated live")
    }
}

#endif
