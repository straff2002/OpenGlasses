import Foundation
import CryptoKit

/// Keeps tool arguments, results, and confirmation copy out of release logs.
///
/// A device log is readable by anything with the device in hand, and these strings are the actual
/// message being sent, the actual note being saved, the actual address being navigated to. In a
/// debug build they are exactly what you need while working on a tool; in a shipped build the shape
/// of the log — which tool, when, how long, what verdict — is kept and the content is not.
enum ToolLogContent {
    static func redacted(_ text: String) -> String {
        #if DEBUG
        return text
        #else
        return "<\(text.count) chars>"
        #endif
    }
}

/// A content-free record of one authorization verdict.
///
/// Ids are fingerprints, never the values: an invocation id correlates a refusal with the turn that
/// caused it, and a pack id is user-installed content that has no business sitting in a log. The
/// tool name is kept in the clear deliberately — it comes from a fixed, app-defined vocabulary and
/// is the one field that makes the record actionable. No argument, template, or result ever lands
/// here.
struct ToolAuthorizationEvent: Sendable, Equatable {
    let at: Date
    let toolName: String
    let origin: ToolInvocationOrigin
    let depth: Int
    let verdict: String
    let invocationFingerprint: String
    let rootFingerprint: String
    let composerFingerprint: String?
}

/// Bounded in-memory security event ring for authorization refusals. Owned by the router rather
/// than a singleton so a test observes exactly the calls it made.
@MainActor
final class ToolAuthorizationEventLog {
    /// Enough to see a pattern in a session; small enough that it can't become a data store.
    static let capacity = 50

    private(set) var events: [ToolAuthorizationEvent] = []

    func record(call: ResolvedToolCall, verdict: String, at: Date = Date()) {
        let context = call.context
        let event = ToolAuthorizationEvent(
            at: at,
            toolName: call.name,
            origin: context.origin,
            depth: context.depth,
            verdict: verdict,
            invocationFingerprint: Self.fingerprint(context.invocationID),
            rootFingerprint: Self.fingerprint(context.rootInvocationID),
            composerFingerprint: context.parent?.composerID.map(Self.fingerprint))
        events.insert(event, at: 0)
        if events.count > Self.capacity {
            events.removeLast(events.count - Self.capacity)
        }
        NSLog("[ToolAuthorization] %@ refused for %@ (origin=%@ depth=%d invocation=%@)",
              verdict, call.name, context.origin.rawValue, context.depth, event.invocationFingerprint)
    }

    /// Short, stable, one-way. Correlates records within a session without carrying the value.
    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
