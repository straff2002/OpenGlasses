import Foundation

// Plan LU P1 — the watch's Private button and badge. Foundation only and compiled into both targets
// (listed in `project.watch.yml`), so the phone that answers the request and the watch that sends
// it, and that draws the badge, read the same strings and the same rule.

/// The watch's half of a private conversation: the request its Private and End buttons send, the
/// reply the phone gives, and what the wrist shows as the last reply while one is open.
enum WatchPrivateWire {
    /// The message command for both buttons.
    static let command = "privateConversation"
    /// The key the request's action travels under.
    static let actionKey = "action"
    /// The application-context key the phone sets while a private conversation is open.
    static let contextKey = "isPrivate"
    /// The key a refusal travels under, the same `error` every watch command's reply uses.
    static let errorKey = "error"

    /// What a button asks for.
    enum Action: String, Equatable, CaseIterable {
        /// The Private button: start a private conversation.
        case start
        /// End on the wrist's Private badge.
        case end
    }

    /// The message a button sends.
    static func message(_ action: Action) -> [String: Any] {
        ["command": command, actionKey: action.rawValue]
    }

    /// The action a message carries; nil when it carries none this build knows. Peer-supplied, so
    /// an unknown value is refused rather than guessed at.
    static func action(from message: [String: Any]) -> Action? {
        guard message["command"] as? String == command,
              let raw = message[actionKey] as? String else { return nil }
        return Action(rawValue: raw)
    }

    /// The phone's reply: whether a private conversation is open afterwards, and why it could not
    /// start when it didn't. The reason is the same line the phone shows and says.
    static func reply(isPrivate: Bool, refusal: String?) -> [String: Any] {
        var reply: [String: Any] = [contextKey: isPrivate]
        if let refusal { reply[errorKey] = refusal }
        return reply
    }

    /// The reply line the watch draws. While a private conversation is open that is only a reply to
    /// a request made on the watch itself, never the phone's idle summary (which carries a fixed
    /// line in its place); otherwise it is the last reply, as ever.
    static func shownReply(lastResponse: String, isPrivate: Bool, replyToWatchRequest: String?) -> String {
        guard isPrivate else { return lastResponse }
        return replyToWatchRequest ?? ""
    }
}
