import Foundation

/// Plan AH (Rokid) — the deterministic, SDK-free command layer for Rokid Glasses (RV101).
///
/// Rokid's glasses take a channel/method command with an optional JSON payload, carried in
/// a binary `Caps` tuple on the CXR-M channel. This file pins the *command* layer; the
/// recovered wire format lives in `RokidCapsCodec`.
///
/// Only one primitive here has a schema attested by the device capture — the brightness and
/// volume setters take a bare integer, and the rest carry JSON text, which is what the
/// observed frames do. The visual-HUD commands used below (`Ntf`, `Custom_View`) are
/// community-reconstructed: no `Ntf` frame appears in the capture, so they ship dark until
/// one does.
///
/// Everything produced here is deterministic and unit-tested, and the encoding round-trips
/// through `RokidWireCodec` in both directions.
struct RokidCommand: Equatable {
    /// Command category — one of the 21 documented prefixes (`Sys`, `Ntf`, `Custom_View`, …).
    let cmd: String
    /// Operation within the category (`Tts_SendPlayTts`, …).
    let key: String
    /// JSON *text* of the parameter object. The wire form carries this as a JSON string
    /// value (Rokid double-encodes params) — see `RokidWireCodec`.
    let param: String

    init(cmd: String, key: String, param: String = "{}") {
        self.cmd = cmd
        self.key = key
        self.param = param
    }

    /// The iAP2 link frame that carries this command, with sequence and timestamp zero.
    ///
    /// This form exists for tests and for anything that just needs *a* valid frame. A real
    /// send must use the connection's own sequence counter and a rising timestamp — see
    /// `encoded(sequence:timestampMicroseconds:)`, which `RokidDisplayBackend` uses.
    func encoded() -> [UInt8] {
        encoded(sequence: 0, timestampMicroseconds: 0)
    }

    /// The iAP2 link frame that carries this command.
    ///
    /// - Parameters:
    ///   - sequence: per-connection frame counter; the glasses echo it in responses.
    ///   - timestampMicroseconds: frame timestamp, in microseconds.
    func encoded(sequence: UInt32, timestampMicroseconds: UInt32) -> [UInt8] {
        RokidIAP2Packet.encodeCommand(
            sequence: sequence,
            channel: cmd,
            method: key,
            payload: .string(param),
            timestampMicroseconds: timestampMicroseconds
        )
    }

    /// Render a parameter object to its JSON text.
    static func param(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

// MARK: - Documented & reconstructed primitives

extension RokidCommand {
    /// Speak text through the glasses' speaker. The only command whose param schema is
    /// published (`{"content":"…"}`). Not wired into the display backend — this app owns
    /// its own TTS — kept as the one hardware-confirmable primitive for the Phase 1 spike.
    static func tts(_ content: String) -> RokidCommand {
        RokidCommand(cmd: "Sys", key: "Tts_SendPlayTts", param: param(["content": content]))
    }

    /// Forward a phone notification to the glasses display. RECONSTRUCTED — `Ntf` is the
    /// documented notification category; the exact key/param schema awaits hardware.
    static func notification(title: String?, text: String, icon: String) -> RokidCommand {
        RokidCommand(cmd: "Ntf", key: "Ntf_SendMessage",
                     param: param([
                        "title": title ?? "",
                        "text": text,
                        "icon": icon,
                     ]))
    }

    /// Third-party custom view — the interactive HUD screen path. RECONSTRUCTED.
    static func customView(param object: [String: Any]) -> RokidCommand {
        RokidCommand(cmd: "Custom_View", key: "Custom_View_SendContent", param: param(object))
    }

    /// Clear the third-party view. RECONSTRUCTED.
    static func clearCustomView() -> RokidCommand {
        RokidCommand(cmd: "Custom_View", key: "Custom_View_Clear", param: "{}")
    }
}

/// The command <-> wire bridge.
///
/// A `RokidCommand` is `(cmd, key, param)`; on the wire that is the Caps tuple
/// `(route, sequence, cmd, object{key, param})` inside an iAP2 link frame — see
/// `RokidCapsCodec` and `RokidIAP2Packet`, which carry the recovered format.
enum RokidWireCodec {
    static func encode(_ command: RokidCommand) -> Data {
        Data(command.encoded())
    }

    static func decode(_ bytes: [UInt8]) -> RokidCommand? {
        guard let frame = RokidIAP2Packet.decode(bytes) else { return nil }
        // (route, sequence, channel, object{method, payload})
        guard frame.caps.count >= 4,
              case .string(let channel) = frame.caps[2],
              case .object(let members) = frame.caps[3],
              !members.isEmpty,
              case .string(let method) = members[0] else { return nil }

        var param = "{}"
        if members.count >= 2, case .string(let payload) = members[1] {
            param = payload
        }
        return RokidCommand(cmd: channel, key: method, param: param)
    }
}
