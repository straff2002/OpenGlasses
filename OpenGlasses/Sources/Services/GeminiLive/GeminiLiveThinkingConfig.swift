import Foundation

/// The `thinkingConfig` shape for a given Live model — or nothing, when we cannot be sure.
///
/// The field is family-specific: the 2.5 family takes `thinkingBudget` (a token count), while 3.x
/// takes `thinkingLevel` (`minimal`…`high`, defaulting to minimal for lowest latency). We hard-coded
/// the 2.5 form, which was correct only for as long as the model stayed 2.5 — and the model is now
/// chosen at runtime from whatever the account offers.
///
/// Sending the wrong shape is not a harmless no-op here. This endpoint rejects an unrecognised
/// field by closing the socket with 1007 and refusing the whole setup, which is exactly how a
/// misplaced `contextWindowCompression` made every Live session fail identically
/// (device-traced 2026-08-23). So when the family is unknown, send **nothing** and take the
/// server's default rather than guess a shape.
enum GeminiLiveThinkingConfig {

    /// Config for a model id, or nil to omit the field entirely.
    static func forModel(_ model: String) -> [String: Any]? {
        let id = GeminiLiveModelPolicy.bareId(model)
        if id.contains("2.5") {
            // Lowest latency: no thinking tokens before the reply. A voice assistant that pauses to
            // think reads as a hang, and the turn budget is shared with the answer.
            return ["thinkingBudget": 0]
        }
        if id.contains("3.") {
            return ["thinkingLevel": "minimal"]
        }
        return nil   // unknown family — the server's default beats a guessed field
    }
}
