import Foundation

/// Wire messages of the Hermes agent bridge — a small JSON-over-WebSocket
/// protocol spoken by the Hermes Glasses Mac bridge (Plan CL P5). Text
/// frames carry JSON objects tagged by `type`; binary frames carry PCM
/// audio between `audio_start`/`audio_end` (we always decline bridge TTS
/// and speak the reply ourselves, so binary frames are dropped).
enum HermesBridgeMessage: Equatable {
    case welcome
    case capturePhoto
    case response(text: String, bridgeWillSendAudio: Bool)
    case audioStart
    case audioEnd
    case sessionReset
    case pong
    case error(message: String)
    /// Forward-compatible: an unrecognised `type` is reported, not dropped
    /// silently, so protocol drift shows up in the debug log.
    case unknown(type: String)
}

/// Pure encode/decode for the bridge protocol — unit-testable without a
/// socket. `HermesBridgeService` owns the live WebSocket.
enum HermesBridgeProtocol {
    static let defaultPort = 8765

    // MARK: - Inbound

    static func decode(_ text: String) -> HermesBridgeMessage? {
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }
        switch type {
        case "welcome": return .welcome
        case "capture_photo": return .capturePhoto
        case "response":
            return .response(
                text: json["text"] as? String ?? "",
                bridgeWillSendAudio: json["tts"] as? Bool ?? false
            )
        case "audio_start": return .audioStart
        case "audio_end": return .audioEnd
        case "session_reset": return .sessionReset
        case "pong": return .pong
        case "error": return .error(message: json["message"] as? String ?? "Bridge error")
        default: return .unknown(type: type)
        }
    }

    // MARK: - Outbound

    /// `tts: false` on every query: OpenGlasses speaks replies through its
    /// own TTS stack (emotion, HUD mirroring, barge-in), so bridge audio
    /// would double-speak.
    static func encodeQuery(_ text: String) -> String {
        encode(["type": "query", "text": text, "tts": false])
    }

    static func encodeNewSession() -> String {
        encode(["type": "new_session"])
    }

    static func encodePhoto(jpegBase64: String) -> String {
        encode(["type": "photo", "data": jpegBase64])
    }

    static func encodePhotoError(_ message: String) -> String {
        encode(["type": "photo_error", "message": message])
    }

    static func encodePing() -> String {
        encode(["type": "ping"])
    }

    // MARK: - Endpoint

    /// ws://host:port/ with the bridge's optional `?token=` auth.
    static func endpointURL(host: String, port: Int, token: String?) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "ws"
        components.host = trimmed
        components.port = port
        components.path = "/"
        if let token, !token.isEmpty {
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        return components.url
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
