import XCTest
@testable import OpenGlasses

/// Plan LT §6 — Gemini Live: a deliberate still goes as a `clientContent` turn that says what it is,
/// streamed frames stay on the realtime video lane, and start-of-speech sensitivity is a setting.
final class GeminiLiveStillEnvelopeTests: XCTestCase {

    func testADeliberateStillIsAClientContentTurnWithTheImageAndOneInstruction() throws {
        let env = LiveInjectionEnvelope.geminiStill(base64JPEG: "QUJD")
        XCTAssertNil(env["realtimeInput"], "not on the frame lane")
        let content = try XCTUnwrap(env["clientContent"] as? [String: Any])
        let turns = try XCTUnwrap(content["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0]["role"] as? String, "user")
        let parts = try XCTUnwrap(turns[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        let inline = try XCTUnwrap(parts[0]["inlineData"] as? [String: String])
        XCTAssertEqual(inline, ["mimeType": "image/jpeg", "data": "QUJD"])
        XCTAssertEqual(parts[1]["text"] as? String, LiveInjectionEnvelope.geminiStillInstruction)
        XCTAssertEqual(LiveInjectionEnvelope.geminiStillInstruction,
                       "This photo was just taken by the wearer's camera; answer about it.")
    }

    /// `turnComplete: false`, explicitly: the still extends context and the wearer's words (or the
    /// tool response that follows) lead. True would make the model answer the photo before the
    /// question; absent reads the same as false on the wire but would hide the choice.
    func testTheStillDoesNotCompleteTheTurn() throws {
        let content = try XCTUnwrap(LiveInjectionEnvelope.geminiStill(base64JPEG: "QUJD")["clientContent"]
                                    as? [String: Any])
        XCTAssertEqual(content["turnComplete"] as? Bool, false)
    }

    func testTheStillIsJSONSerialisable() {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(LiveInjectionEnvelope.geminiStill(base64JPEG: "QUJD")))
    }

    // MARK: - The two paths, read from source

    private func serviceCode() throws -> String {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/GeminiLive/GeminiLiveService.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }

    private func body(of function: String, in code: String) throws -> String {
        let start = try XCTUnwrap(code.range(of: "func \(function)"), function)
        let rest = code[start.upperBound...]
        // Up to the next member at the type's indentation.
        let end = rest.range(of: "\n    }\n")
        return String(rest[..<(end?.lowerBound ?? rest.endIndex)])
    }

    func testTheSharpStillUsesTheStillEnvelopeAndTheStreamStaysRealtime() throws {
        let code = try serviceCode()
        let still = try body(of: "sendHighResImage(", in: code)
        XCTAssertTrue(still.contains("LiveInjectionEnvelope.geminiStill("), still)
        XCTAssertFalse(still.contains("\"realtimeInput\""), still)
        let frame = try body(of: "sendVideoFrame(", in: code)
        XCTAssertTrue(frame.contains("\"realtimeInput\""), "the ~1 fps stream stays on realtimeInput.video")
        XCTAssertTrue(frame.contains("\"video\""))
        XCTAssertFalse(frame.contains("clientContent"))
    }

    // MARK: - Start-of-speech sensitivity

    private func detection(_ sensitivity: GeminiLiveStartSensitivity?) -> [String: Any]? {
        let setup: [String: Any]
        if let sensitivity {
            setup = GeminiLiveSetup.body(model: "models/test-live", responseModalities: ["AUDIO"],
                                         systemInstruction: "", tools: [], sessionResumption: [:],
                                         startSensitivity: sensitivity)
        } else {
            setup = GeminiLiveSetup.body(model: "models/test-live", responseModalities: ["AUDIO"],
                                         systemInstruction: "", tools: [], sessionResumption: [:])
        }
        return (setup["realtimeInputConfig"] as? [String: Any])?["automaticActivityDetection"] as? [String: Any]
    }

    func testHighStaysTheDefault() {
        XCTAssertEqual(detection(nil)?["startOfSpeechSensitivity"] as? String, "START_SENSITIVITY_HIGH")
        let key = Config.geminiLiveStartSensitivityKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(Config.geminiLiveStartSensitivity, .high)
        UserDefaults.standard.set("low", forKey: key)
        XCTAssertEqual(Config.geminiLiveStartSensitivity, .low)
        UserDefaults.standard.set("medium", forKey: key)
        XCTAssertEqual(Config.geminiLiveStartSensitivity, .high, "an unknown value reads as the default")
    }

    func testTheSettingReachesTheSetup() {
        XCTAssertEqual(detection(.high)?["startOfSpeechSensitivity"] as? String, "START_SENSITIVITY_HIGH")
        XCTAssertEqual(detection(.low)?["startOfSpeechSensitivity"] as? String, "START_SENSITIVITY_LOW")
        // Only the start changes.
        XCTAssertEqual(detection(.low)?["endOfSpeechSensitivity"] as? String, "END_SENSITIVITY_LOW")
        XCTAssertEqual(detection(.low)?["silenceDurationMs"] as? Int, 500)
    }

    func testTheServicePassesTheSetting() throws {
        XCTAssertTrue(try serviceCode().contains("startSensitivity: Config.geminiLiveStartSensitivity"))
    }
}
