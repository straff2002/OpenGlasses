import Foundation

/// Authoritative CXR-M command vocabulary for Rokid Glasses (RV101).
///
/// Modelled on the `com.rokid.cxr:client-m` **1.0.8** SDK as publicly documented by the
/// community, written here from the wire format rather than ported: a CXR message is a `Caps` tuple addressed to a named
/// channel, where `[0]` is the command string and `[1]` an optional JSON payload.
///
/// This type pins only the *model* — channel names, command names, argument order and Caps
/// type tags — so the transport can be replaced without re-deriving the vocabulary. It is
/// deliberately independent of `RokidCommand`, whose `{"cmd","key","param"}` JSON is the
/// legacy wire shape that the current dark transport still emits.
enum RokidCXRChannel: String, CaseIterable, Equatable {
    case dev = "Dev"
    case ai = "Ai"
    case med = "Med"
    case sys = "Sys"
    case trans = "Trans"
    case settings = "Settings"
    case artc = "ARTC"
}

/// One typed value in a `Caps` tuple.
///
/// The tags are the SDK's own `Caps.Value` type characters, so a future encoder can be
/// checked against them directly.
enum RokidCapsValue: Equatable {
    case void
    case int32(Int32)
    case uint32(UInt32)
    case int64(Int64)
    case uint64(UInt64)
    case float(Float)
    case double(Double)
    case string(String)
    case binary(Data)
    case object([RokidCapsValue])

    /// The SDK's wire type tag for this value (`Caps.Value.TYPE_*`).
    var typeTag: Character {
        switch self {
        case .void: return "V"
        case .int32: return "i"
        case .uint32: return "u"
        case .int64: return "l"
        case .uint64: return "k"
        case .float: return "f"
        case .double: return "d"
        case .string: return "S"
        case .binary: return "B"
        case .object: return "O"
        }
    }
}

/// One CXR-M message: a channel, a command string, and its ordered `Caps` arguments.
struct RokidCXRCommand: Equatable {
    let channel: RokidCXRChannel
    let command: String
    let arguments: [RokidCapsValue]

    init(channel: RokidCXRChannel, command: String, arguments: [RokidCapsValue] = []) {
        self.channel = channel
        self.command = command
        self.arguments = arguments
    }

    /// The SDK's convention for a structured argument: JSON text in `[1]`.
    static func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

// MARK: - Documented commands

// Each factory below is one of the channel/command pairs the SDK actually issues. Payload
// shapes follow the decompiled reference; where a JSON body is the SDK's convention it is
// rendered with `RokidCXRCommand.json`.
extension RokidCXRCommand {
    // Ai — the AI/assistant interaction channel.

    /// `Ai_Start` — tell the glasses an AI session began.
    static func aiStart() -> RokidCXRCommand {
        RokidCXRCommand(channel: .ai, command: "Ai_Start")
    }

    /// `Ai_Heartbeat` — keep the AI session alive.
    static func aiHeartbeat(count: Int) -> RokidCXRCommand {
        RokidCXRCommand(channel: .ai, command: "Ai_Heartbeat",
                        arguments: [.string(json(["count": count]))])
    }

    /// `ASR_Result` — push recognised speech text to the glasses.
    static func asrResult(_ text: String) -> RokidCXRCommand {
        RokidCXRCommand(channel: .ai, command: "ASR_Result", arguments: [.string(text)])
    }

    /// `ASR_None` — recognition produced nothing.
    static func asrNone() -> RokidCXRCommand {
        RokidCXRCommand(channel: .ai, command: "ASR_None")
    }

    /// `ASR_End` — recognition finished.
    static func asrEnd() -> RokidCXRCommand {
        RokidCXRCommand(channel: .ai, command: "ASR_End")
    }

    /// `ASR_Error` — recognition failed.
    static func asrError() -> RokidCXRCommand {
        RokidCXRCommand(channel: .ai, command: "ASR_Error")
    }

    /// `TTS_Result` — have the glasses speak text.
    static func tts(_ text: String) -> RokidCXRCommand {
        RokidCXRCommand(channel: .ai, command: "TTS_Result", arguments: [.string(text)])
    }

    /// `TTS_AudioFinished` — TTS playback has ended.
    static func ttsFinished() -> RokidCXRCommand {
        RokidCXRCommand(channel: .ai, command: "TTS_AudioFinished")
    }

    /// `Ai_OpenCamera` — open the camera for the AI flow.
    static func openCamera(width: Int, height: Int, quality: Int = 100) -> RokidCXRCommand {
        RokidCXRCommand(channel: .ai, command: "Ai_OpenCamera",
                        arguments: [.string(json(["width": width, "height": height, "quality": quality]))])
    }

    /// `Ai_TakePhoto` — capture a still and receive it as bytes on the callback.
    static func takePhoto(width: Int, height: Int, quality: Int = 100) -> RokidCXRCommand {
        RokidCXRCommand(channel: .ai, command: "Ai_TakePhoto",
                        arguments: [.string(json(["width": width, "height": height, "quality": quality]))])
    }

    /// `Exit` — end the AI session.
    static func exit(sessionCount: Int32 = 0) -> RokidCXRCommand {
        RokidCXRCommand(channel: .ai, command: "Exit", arguments: [.int32(sessionCount)])
    }

    /// `NoNetwork` — tell the glasses the phone has no connectivity.
    static func noNetwork() -> RokidCXRCommand {
        RokidCXRCommand(channel: .ai, command: "NoNetwork")
    }

    /// `Ai_Error` — the AI request failed.
    static func aiError() -> RokidCXRCommand {
        RokidCXRCommand(channel: .ai, command: "Ai_Error")
    }

    // Sys — system text overlays. This is the documented text-display path.

    /// `WordTips_SetTvConfig` — configure the text overlay.
    static func wordTipsConfig(_ config: [String: Any]) -> RokidCXRCommand {
        RokidCXRCommand(channel: .sys, command: "WordTips_SetTvConfig",
                        arguments: [.string(json(config))])
    }

    /// `WordTips_AiContent` — send text to the overlay.
    static func wordTipsContent(asr text: String) -> RokidCXRCommand {
        RokidCXRCommand(channel: .sys, command: "WordTips_AiContent",
                        arguments: [.string(json(["asr": text]))])
    }

    // Trans — structured result text.

    /// `Trans_Result` — push a structured result (translation or equivalent).
    static func translationResult(id: Int, subId: Int = 0, temporary: Bool = false,
                                  finished: Bool = true, result: String) -> RokidCXRCommand {
        RokidCXRCommand(channel: .trans, command: "Trans_Result",
                        arguments: [.string(json([
                            "id": id,
                            "subId": subId,
                            "temporary": temporary,
                            "finished": finished,
                            "result": result,
                        ]))])
    }

    // Med — media.

    /// `Med_Take_Photo_Url` — capture a still and receive a URL instead of bytes.
    static func takePhotoURL(width: Int, height: Int, quality: Int = 100) -> RokidCXRCommand {
        RokidCXRCommand(channel: .med, command: "Med_Take_Photo_Url",
                        arguments: [.string(json(["width": width, "height": height, "quality": quality]))])
    }

    // Settings / Dev — device control.

    /// `Settings_Update` — update one or more device settings.
    static func settingsUpdate(_ values: [(key: String, value: String)]) -> RokidCXRCommand {
        let entries: [[String: Any]] = values.map { ["key": $0.key, "value": $0.value] }
        let text: String
        if let data = try? JSONSerialization.data(withJSONObject: entries),
           let rendered = String(data: data, encoding: .utf8) {
            text = rendered
        } else {
            text = "[]"
        }
        return RokidCXRCommand(channel: .settings, command: "Settings_Update",
                               arguments: [.string(text)])
    }

    /// `Dev_GlassBrightness` — set brightness, clamped to the documented 0…15 range.
    static func brightness(_ level: Int) -> RokidCXRCommand {
        RokidCXRCommand(channel: .dev, command: "Dev_GlassBrightness",
                        arguments: [.uint32(UInt32(min(max(level, 0), 15)))])
    }

    /// `Dev_GlassSound` — set volume, clamped to the documented 0…15 range.
    static func volume(_ level: Int) -> RokidCXRCommand {
        RokidCXRCommand(channel: .dev, command: "Dev_GlassSound",
                        arguments: [.uint32(UInt32(min(max(level, 0), 15)))])
    }

    /// `Dev_TimeUpdate` — sync the phone's clock and time zone.
    static func timeUpdate(timeZone: String, milliseconds: Int64) -> RokidCXRCommand {
        RokidCXRCommand(channel: .dev, command: "Dev_TimeUpdate",
                        arguments: [.string(json(["timeZone": timeZone, "time": milliseconds]))])
    }

    // ARTC — real-time transport.

    /// `OnStop` — stop ARTC streaming.
    static func artcStop() -> RokidCXRCommand {
        RokidCXRCommand(channel: .artc, command: "OnStop")
    }
}
