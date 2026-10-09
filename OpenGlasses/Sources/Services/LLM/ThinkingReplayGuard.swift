import CryptoKit
import Foundation

/// Decides, inside one turn's tool loop, whether the thinking blocks the model produced may be
/// sent back (Plan IE P2).
///
/// A thinking block is bound to what it was produced over: the system prompt, the tool
/// definitions and every message before it. Sent back over exactly that, it is valid — and an
/// assistant message that calls a tool is meant to be returned with its thinking intact. Sent
/// back over anything else, the newest models answer 400.
///
/// Within a turn that prefix is *usually* unchanged from one round trip to the next, but not by
/// construction: a capture tool's photo makes the image prune rewrite an earlier message, the
/// request copy stops resending a photo once the model has answered from it, and the history
/// budget can drop an old exchange (and change the note in the system text that says so) as the
/// turn grows. Rather than prove each of those away, the guard checks. Each request records a
/// digest of what it sent; the next request compares the same span of what it is about to send.
/// Equal, and the blocks ride. Different, and the caller drops this turn's thinking blocks before
/// sending — which is always legal, and costs the model only its notes.
///
/// Comparing against the previous request alone covers every earlier block: that request was
/// itself checked against the one before it.
///
/// Pure: the digest is a hash, and carries none of the prompt's text.
enum ThinkingReplayGuard {

    /// What one request sent, reduced to a count and a hash.
    struct Sent: Equatable {
        /// How many messages the request carried. Blocks produced in reply sit after these.
        let messageCount: Int
        let digest: String
    }

    /// Record a request that is about to go.
    static func record(system: [[String: Any]], tools: [[String: Any]],
                       messages: [[String: Any]]) -> Sent {
        Sent(messageCount: messages.count,
             digest: digest(system: system, tools: tools, messages: messages[...]))
    }

    /// Whether everything `previous` sent is about to be sent again unchanged, ahead of whatever
    /// has been appended since.
    static func prefixUnchanged(since previous: Sent, system: [[String: Any]],
                                tools: [[String: Any]], messages: [[String: Any]]) -> Bool {
        guard messages.count >= previous.messageCount else { return false }
        return digest(system: system, tools: tools,
                      messages: messages.prefix(previous.messageCount)) == previous.digest
    }

    private static func digest(system: [[String: Any]], tools: [[String: Any]],
                               messages: ArraySlice<[String: Any]>) -> String {
        var hasher = SHA256()
        // Sorted keys, so two equal dictionaries always hash alike. Each part is followed by a
        // zero byte, so moving text from one part to the next cannot produce the same stream.
        for part in [system as Any, tools as Any] + messages.map({ $0 as Any }) {
            let data = (try? JSONSerialization.data(withJSONObject: part, options: [.sortedKeys])) ?? Data()
            hasher.update(data: data)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
