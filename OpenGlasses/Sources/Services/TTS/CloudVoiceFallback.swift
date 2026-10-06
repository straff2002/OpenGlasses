import Foundation

/// Why the cloud voice turned a request away, when the wearer is the only one who can fix it.
///
/// A network blip or a server error falls through to the next engine and is nobody's business.
/// These two are different: they repeat on every reply until the wearer tops up or corrects the
/// key, and until now the only sign was a worse voice with no explanation (support report,
/// 2026-10-05 — the wearer went looking for a voice setting to undo a change they never made).
enum CloudVoiceRejection: String, Equatable, CaseIterable {
    /// The account has no credit left. ElevenLabs sends this as a 401 whose body names
    /// `quota_exceeded`, so the status alone cannot tell it from a bad key.
    case outOfCredit
    /// The key, or the voice chosen for it, was refused.
    case refused

    static func classify(statusCode: Int, body: String) -> CloudVoiceRejection? {
        if body.contains("quota_exceeded") { return .outOfCredit }
        switch statusCode {
        case 401, 402, 403: return .refused
        default: return nil
        }
    }

    /// Said once, after the reply it interrupted. The path is spoken as words: a wearer who is not
    /// looking at the phone has to be able to find it later from memory.
    var spokenLine: String {
        switch self {
        case .outOfCredit:
            return String(localized: "By the way, your ElevenLabs credit has run out, so I'm using the built-in voice. You can change voices in the app's Settings, under Connections, then Services and Integrations.")
        case .refused:
            return String(localized: "By the way, ElevenLabs refused the voice request, so I'm using the built-in voice. Check the key and voice in the app's Settings, under Connections, then Services and Integrations.")
        }
    }

    /// The same news for the screen.
    var banner: String {
        switch self {
        case .outOfCredit:
            return String(localized: "ElevenLabs is out of credit, so replies use the built-in voice. Change voices in Settings › Connections › Services & Integrations.")
        case .refused:
            return String(localized: "ElevenLabs refused the voice request, so replies use the built-in voice. Check the key and voice in Settings › Connections › Services & Integrations.")
        }
    }
}

/// When a rejection is worth saying aloud. Once per episode, not once per launch: a wearer who has
/// decided to live with the built-in voice should not be told again every morning. The episode ends
/// when the cloud voice speaks again or the wearer changes the key or voice.
struct CloudVoiceFallbackAnnouncer {
    static let defaultsKey = "cloudVoiceFallbackAnnounced"

    var defaults: UserDefaults = .standard

    /// The line to add to this utterance, or nil when this rejection has been said already or the
    /// utterance is not one to append to.
    ///
    /// - Parameter plainReply: an ordinary reply at neutral urgency. An alert or a warning is
    ///   never lengthened with housekeeping, and stays unannounced until the next ordinary reply.
    mutating func lineToSpeak(for rejection: CloudVoiceRejection, plainReply: Bool) -> String? {
        guard plainReply, defaults.string(forKey: Self.defaultsKey) != rejection.rawValue else {
            return nil
        }
        defaults.set(rejection.rawValue, forKey: Self.defaultsKey)
        return rejection.spokenLine
    }

    /// The cloud voice is working, or its key or voice has changed: the next rejection is news.
    func episodeEnded() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
