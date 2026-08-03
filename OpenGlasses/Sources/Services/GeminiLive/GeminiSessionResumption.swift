import Foundation

/// Native Gemini Live session resumption (Plan CJ item 7), as pure wire-shape helpers.
///
/// Every setup message requests resumption updates; the server then periodically sends
/// `sessionResumptionUpdate` messages carrying a handle. On reconnect (goAway rotation, network
/// drop) the stored handle goes back into setup and the server restores the session context —
/// cheaper and faster than the cold reconnect we shipped before, which rebuilt the session from
/// scratch and lost the live dialogue. Pure so the wire shapes are testable without a socket.
enum GeminiSessionResumption {

    /// The `sessionResumption` field for a setup message: `{}` requests updates on a fresh
    /// session; `{"handle": …}` resumes a prior one.
    static func setupValue(handle: String?) -> [String: Any] {
        if let handle, !handle.isEmpty { return ["handle": handle] }
        return [:]
    }

    /// A parsed `sessionResumptionUpdate` server message.
    struct Update: Equatable {
        let newHandle: String?
        let resumable: Bool
    }

    /// Parse an incoming server message; `nil` when it isn't a resumption update.
    static func update(from json: [String: Any]) -> Update? {
        guard let body = json["sessionResumptionUpdate"] as? [String: Any] else { return nil }
        return Update(newHandle: body["newHandle"] as? String,
                      resumable: body["resumable"] as? Bool ?? false)
    }

    /// The handle to hold after an update: only a resumable, non-empty handle replaces the
    /// current one — a non-resumable update means "not yet valid", so the last good handle
    /// (if any) is kept.
    static func apply(_ update: Update, to current: String?) -> String? {
        guard update.resumable, let handle = update.newHandle, !handle.isEmpty else {
            return current
        }
        return handle
    }
}
