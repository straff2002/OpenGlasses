import XCTest
@testable import OpenGlasses

final class HermesBridgeProtocolTests: XCTestCase {

    // MARK: - Decode

    func testDecodeKnownMessages() {
        XCTAssertEqual(HermesBridgeProtocol.decode(#"{"type":"welcome"}"#), .welcome)
        XCTAssertEqual(HermesBridgeProtocol.decode(#"{"type":"capture_photo"}"#), .capturePhoto)
        XCTAssertEqual(HermesBridgeProtocol.decode(#"{"type":"session_reset"}"#), .sessionReset)
        XCTAssertEqual(HermesBridgeProtocol.decode(#"{"type":"pong"}"#), .pong)
        XCTAssertEqual(HermesBridgeProtocol.decode(#"{"type":"audio_start"}"#), .audioStart)
        XCTAssertEqual(HermesBridgeProtocol.decode(#"{"type":"audio_end"}"#), .audioEnd)
    }

    func testDecodeResponseCarriesTextAndTTSFlag() {
        XCTAssertEqual(
            HermesBridgeProtocol.decode(#"{"type":"response","text":"hi","tts":true}"#),
            .response(text: "hi", bridgeWillSendAudio: true)
        )
        // Missing tts defaults to false — the app speaks.
        XCTAssertEqual(
            HermesBridgeProtocol.decode(#"{"type":"response","text":"hi"}"#),
            .response(text: "hi", bridgeWillSendAudio: false)
        )
    }

    func testDecodeErrorAndUnknownAndGarbage() {
        XCTAssertEqual(
            HermesBridgeProtocol.decode(#"{"type":"error","message":"Empty query."}"#),
            .error(message: "Empty query.")
        )
        // Unknown types surface by name instead of vanishing.
        XCTAssertEqual(
            HermesBridgeProtocol.decode(#"{"type":"telemetry_v9"}"#),
            .unknown(type: "telemetry_v9")
        )
        XCTAssertNil(HermesBridgeProtocol.decode("not json"))
        XCTAssertNil(HermesBridgeProtocol.decode(#"["array"]"#))
        XCTAssertNil(HermesBridgeProtocol.decode(#"{"no_type":1}"#))
    }

    // MARK: - Encode

    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    func testEncodeQueryAlwaysDeclinesBridgeTTS() {
        let object = json(HermesBridgeProtocol.encodeQuery("what am I looking at?"))
        XCTAssertEqual(object["type"] as? String, "query")
        XCTAssertEqual(object["text"] as? String, "what am I looking at?")
        XCTAssertEqual(object["tts"] as? Bool, false)
    }

    func testEncodePhotoAndPhotoError() {
        let photo = json(HermesBridgeProtocol.encodePhoto(jpegBase64: "QUJD"))
        XCTAssertEqual(photo["type"] as? String, "photo")
        XCTAssertEqual(photo["data"] as? String, "QUJD")

        let error = json(HermesBridgeProtocol.encodePhotoError("no camera"))
        XCTAssertEqual(error["type"] as? String, "photo_error")
        XCTAssertEqual(error["message"] as? String, "no camera")
    }

    func testEncodeSessionAndPing() {
        XCTAssertEqual(json(HermesBridgeProtocol.encodeNewSession())["type"] as? String, "new_session")
        XCTAssertEqual(json(HermesBridgeProtocol.encodePing())["type"] as? String, "ping")
    }

    // MARK: - Endpoint

    func testEndpointURLBuildsWSWithOptionalToken() {
        XCTAssertEqual(
            HermesBridgeProtocol.endpointURL(host: "192.168.1.10", port: 8765, token: nil)?.absoluteString,
            "ws://192.168.1.10:8765/"
        )
        XCTAssertEqual(
            HermesBridgeProtocol.endpointURL(host: " mac.local ", port: 9000, token: "s3cret")?.absoluteString,
            "ws://mac.local:9000/?token=s3cret"
        )
        XCTAssertNil(HermesBridgeProtocol.endpointURL(host: "   ", port: 8765, token: nil))
    }
}
