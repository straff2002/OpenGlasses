import XCTest
@testable import OpenGlasses

/// Plan CB P1 — the injection envelopes, phrasing, capture policy, and zoom arithmetic.
final class LiveInjectionTests: XCTestCase {

    // MARK: - Envelope: the completeTurn contract

    /// The whole point of the flag: without `turnComplete: true`, `clientContent` appends silently
    /// and the model generates nothing — the failure that presents as a delivery bug and provokes
    /// duplicate re-asks. The envelope must carry the flag explicitly in both states.
    func testGeminiTextCarriesTurnCompleteExplicitly() throws {
        for complete in [true, false] {
            let env = LiveInjectionEnvelope.geminiText("hello", completeTurn: complete)
            let content = try XCTUnwrap(env["clientContent"] as? [String: Any])
            XCTAssertEqual(content["turnComplete"] as? Bool, complete,
                           "turnComplete must be present and exact — absence means append-only")
            let turns = try XCTUnwrap(content["turns"] as? [[String: Any]])
            XCTAssertEqual(turns.count, 1)
            XCTAssertEqual(turns[0]["role"] as? String, "user")
            let parts = try XCTUnwrap(turns[0]["parts"] as? [[String: String]])
            XCTAssertEqual(parts, [["text": "hello"]])
        }
    }

    func testGeminiImageRidesTheRealtimeVideoLane() throws {
        let env = LiveInjectionEnvelope.geminiImage(base64JPEG: "QUJD")
        let input = try XCTUnwrap(env["realtimeInput"] as? [String: Any])
        let video = try XCTUnwrap(input["video"] as? [String: String])
        XCTAssertEqual(video, ["mimeType": "image/jpeg", "data": "QUJD"])
        XCTAssertNil(env["clientContent"], "an image injection must not carry turn semantics")
    }

    func testRealtimeTextItemShape() throws {
        let env = LiveInjectionEnvelope.realtimeText("hi")
        XCTAssertEqual(env["type"] as? String, "conversation.item.create")
        let item = try XCTUnwrap(env["item"] as? [String: Any])
        XCTAssertEqual(item["role"] as? String, "user")
        let content = try XCTUnwrap(item["content"] as? [[String: String]])
        XCTAssertEqual(content, [["type": "input_text", "text": "hi"]])
    }

    /// The Realtime spelling of the same trap: `conversation.item.create` alone appends;
    /// `response.create` is the generation trigger and must exist as its own message.
    func testRealtimeResponseCreateIsItsOwnMessage() {
        let env = LiveInjectionEnvelope.realtimeResponseCreate()
        XCTAssertEqual(env.count, 1)
        XCTAssertEqual(env["type"] as? String, "response.create")
    }

    func testRealtimeImagePutsPromptBeforeImage() throws {
        let env = LiveInjectionEnvelope.realtimeImage(base64JPEG: "QUJD", prompt: "read this")
        let item = try XCTUnwrap(env["item"] as? [String: Any])
        let content = try XCTUnwrap(item["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertEqual(content[1]["type"] as? String, "input_image")
        XCTAssertEqual(content[1]["image"] as? String, "QUJD")

        let bare = LiveInjectionEnvelope.realtimeImage(base64JPEG: "QUJD", prompt: nil)
        let bareItem = try XCTUnwrap(bare["item"] as? [String: Any])
        XCTAssertEqual((bareItem["content"] as? [[String: Any]])?.count, 1)
    }

    // MARK: - Phrasing

    func testAcknowledgementIsAnInstructionWithTheNoMemoryClause() {
        let text = AsyncDeliveryPhrasing.acknowledgementInstruction(taskDescription: "check calendar")
        // Rule 1: instruction, not a sentence to read out.
        XCTAssertTrue(text.contains("in your own words"), "must instruct, not dictate a status line")
        // Rule 2: a model handed "task started" with no constraint invents the result.
        XCTAssertTrue(text.contains("Do not answer the request from memory"),
                      "the no-memory clause is mandatory")
        XCTAssertTrue(text.contains("check calendar"))
        // Also valid without a task description.
        XCTAssertTrue(AsyncDeliveryPhrasing.acknowledgementInstruction(taskDescription: nil)
            .contains("Do not answer the request from memory"))
    }

    func testResultCarriesItsQuestionAndForbidsNotificationFraming() {
        let text = AsyncDeliveryPhrasing.resultInstruction(question: "what's on my calendar", answer: "Two meetings")
        XCTAssertTrue(text.contains("what's on my calendar"), "a late result carries its question")
        XCTAssertTrue(text.contains("Two meetings"))
        XCTAssertTrue(text.contains("not as a new notification"),
                      "bare-notification delivery is the failure mode this exists to prevent")
        // Without the question the framing must still say it answers an earlier ask.
        let bare = AsyncDeliveryPhrasing.resultInstruction(question: nil, answer: "Done")
        XCTAssertTrue(bare.contains("answer to what was asked"))
    }

    func testDirectModeFallbackIsDeterministicAndVaries() {
        XCTAssertEqual(AsyncDeliveryPhrasing.directModeStillWorking(elapsedSeconds: 10),
                       "Still working on that.")
        XCTAssertNotEqual(AsyncDeliveryPhrasing.directModeStillWorking(elapsedSeconds: 30),
                          AsyncDeliveryPhrasing.directModeStillWorking(elapsedSeconds: 10),
                          "repeats shouldn't sound like a stuck loop")
    }

    // MARK: - LookCloselyPolicy

    func testReservePostureNeverFiresTheCamera() {
        let d = LookCloselyPolicy.decide(posture: .reserve, secondsSinceLastCapture: nil)
        guard case .declineWithReason(let reason) = d else {
            return XCTFail("reserve must decline, got \(d)")
        }
        XCTAssertTrue(reason.contains("power reserve"), "the model must be told why, so it says so")
    }

    func testMinimumIntervalDeclinesRapidRepeatCaptures() {
        let recent = LookCloselyPolicy.decide(posture: .normal, secondsSinceLastCapture: 1)
        guard case .declineWithReason(let reason) = recent else {
            return XCTFail("rapid repeat must decline")
        }
        XCTAssertTrue(reason.contains("already in your view"))

        XCTAssertEqual(
            LookCloselyPolicy.decide(posture: .normal,
                                     secondsSinceLastCapture: LookCloselyPolicy.minimumCaptureInterval + 0.1),
            .captureSharpFrame)
    }

    func testNormalAndConservePosturesCaptureOnFirstCall() {
        XCTAssertEqual(LookCloselyPolicy.decide(posture: .normal, secondsSinceLastCapture: nil),
                       .captureSharpFrame)
        // Conserve throttles streams, but a single explicit still is exactly the snapshot-first
        // behavior the posture prefers.
        XCTAssertEqual(LookCloselyPolicy.decide(posture: .conserve, secondsSinceLastCapture: nil),
                       .captureSharpFrame)
    }

    func testSharpFrameInstructionTellsTheModelToReadTheNewImage() {
        XCTAssertTrue(LookCloselyPolicy.sharpFrameInstruction.contains("added to your vision"))
        XCTAssertTrue(LookCloselyPolicy.sharpFrameInstruction.contains("full-resolution"))
    }

    // MARK: - PhoneZoomPolicy

    func testZoomMultipliesGestureStartNotLastCommitted() {
        // Scale reported against gesture start: start 2×, pinch to 1.5 → 3×, NOT 2×1.5×(previous…).
        XCTAssertEqual(PhoneZoomPolicy.factor(gestureStart: 2, gestureScale: 1.5, deviceMax: 10), 3)
        // Same gesture re-applied from the same start must be idempotent (no accumulation).
        let once = PhoneZoomPolicy.factor(gestureStart: 2, gestureScale: 1.5, deviceMax: 10)
        let again = PhoneZoomPolicy.factor(gestureStart: 2, gestureScale: 1.5, deviceMax: 10)
        XCTAssertEqual(once, again)
    }

    func testZoomClampsToUsefulCeilingAndDeviceMax() {
        XCTAssertEqual(PhoneZoomPolicy.factor(gestureStart: 4, gestureScale: 10, deviceMax: 16),
                       PhoneZoomPolicy.maxUsefulZoom, "past ~8× the sensor is upscaling")
        XCTAssertEqual(PhoneZoomPolicy.factor(gestureStart: 4, gestureScale: 10, deviceMax: 6), 6,
                       "a lower device ceiling wins")
        XCTAssertEqual(PhoneZoomPolicy.factor(gestureStart: 1, gestureScale: 0.2, deviceMax: 10), 1,
                       "cannot zoom out past 1×")
    }

    func testReadoutOnlyAboveThreshold() {
        XCTAssertFalse(PhoneZoomPolicy.showsReadout(factor: 1.0))
        XCTAssertFalse(PhoneZoomPolicy.showsReadout(factor: 1.04))
        XCTAssertTrue(PhoneZoomPolicy.showsReadout(factor: 1.2))
        XCTAssertEqual(PhoneZoomPolicy.readoutLabel(factor: 2.34), "2.3×")
    }
}
