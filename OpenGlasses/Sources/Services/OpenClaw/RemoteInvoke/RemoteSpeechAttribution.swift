import Foundation

/// Names the source of anything a remote caller makes the glasses say (Plan BH).
///
/// Remote `speak` text used to reach TTS verbatim, so a wearer could not tell an instruction they
/// had asked for from one a remote — possibly prompt-injected — agent pushed. Attribution is the
/// same convention the rest of the app narrates with: the utterance says who it came from before
/// it says anything else.
///
/// **One string, deliberately.** The prefix and the body are a single utterance handed to a single
/// `speak` call, so a wearer's "stop" barge-in can never cut the prefix and leave an unattributed
/// body playing, and the audit trail and the speech stay one event.
enum RemoteSpeechAttribution {

    /// The utterance to speak for remote `text` issued by `origin` — "Message from the gateway: …"
    /// for the gateway socket, "Message from <peer>: …" for an MCP peer.
    static func spoken(_ text: String, from origin: RemoteCommandOrigin) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Message from \(source(of: origin))"
        // The parser already rejects a missing/empty `text`; belt-and-braces, an empty body speaks
        // the attribution alone rather than a dangling colon.
        return body.isEmpty ? prefix : "\(prefix): \(body)"
    }

    /// How the source is named inside the sentence. The gateway reads as a thing ("the gateway"),
    /// a peer by the display name the origin already carries.
    private static func source(of origin: RemoteCommandOrigin) -> String {
        switch origin {
        case .gateway:  return "the gateway"
        case .mcpPeer:  return origin.displayName
        }
    }
}
