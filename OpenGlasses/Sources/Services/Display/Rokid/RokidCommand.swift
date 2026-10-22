import Foundation

/// Plan AH (Rokid) — the deterministic, SDK-free command layer for Rokid Glasses (RV101).
///
/// Rokid's glasses speak a JSON command vocabulary — `{"cmd","key","param"}` — carried over
/// a proprietary binary "Caps" serialization on the Bluetooth channel. This file pins the
/// *command* layer only. Of the 21 documented command categories, exactly one primitive has
/// a published parameter schema (`Sys/Tts_SendPlayTts` → `{"content":"…"}`); the visual-HUD
/// commands used here (`Ntf`, `Custom_View`) are community-reconstructed and ship dark until
/// a capture-log / hardware pass confirms them.
///
/// Every byte produced here is deterministic and unit-tested at the JSON layer. The Caps
/// binary framing is deliberately a transport concern (`RokidWireCodec`) so the command
/// model stays put when the wire is finally recovered.
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

    /// UTF-8 bytes for the transport. This is the *interim* wire form (raw JSON); the
    /// device expects Caps-framed bytes and `RokidWireCodec.encode` is the single place
    /// that changes when that framing lands.
    func encoded() -> [UInt8] {
        Array(RokidWireCodec.encode(self))
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

/// Interim wire codec: raw JSON today, Caps binary when recovered from hardware.
enum RokidWireCodec {
    static func encode(_ command: RokidCommand) -> Data {
        let object: [String: String] = ["cmd": command.cmd, "key": command.key, "param": command.param]
        // A [String: String] of non-nil strings cannot fail JSONSerialization.
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func decode(_ bytes: [UInt8]) -> RokidCommand? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: String],
              let cmd = object["cmd"], let key = object["key"] else { return nil }
        return RokidCommand(cmd: cmd, key: key, param: object["param"] ?? "{}")
    }
}
