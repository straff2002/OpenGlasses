import Foundation

/// What to tell the user when a Live session fails to start.
///
/// Device-traced 2026-08-23: every failure surfaced as "Failed to connect to Gemini", which is the
/// *fallback* branch — shown only when the connection state is not `.error`. A server-side refusal
/// closes the socket rather than erroring it, so the close path set `.disconnected`, built a
/// perfectly good message naming the close code and the server's reason, handed it to the
/// reconnect scheduler, and the user-facing branch never saw it. The one string that could have
/// explained the failure was computed and discarded on exactly the failures that needed it.
///
/// Pure so the precedence can be tested without a socket: which of several partial signals wins is
/// the whole decision, and it is the kind that quietly regresses when it lives inline in a manager.
enum GeminiLiveFailureCopy {

    /// Generic last resort. Named so a test can assert we did better than this.
    static let genericFallback = "Failed to connect to Gemini"

    /// Best available explanation, most specific first.
    ///
    /// - Parameters:
    ///   - errorStateMessage: message from a `.error` connection state, when the socket errored.
    ///   - lastCloseReason: message built by the close handler — the server's own words, and the
    ///     only signal present when a session is *refused* rather than broken.
    static func message(errorStateMessage: String?, lastCloseReason: String?) -> String {
        if let errorStateMessage, !errorStateMessage.trimmed.isEmpty { return errorStateMessage }
        if let lastCloseReason, !lastCloseReason.trimmed.isEmpty { return lastCloseReason }
        return genericFallback
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
