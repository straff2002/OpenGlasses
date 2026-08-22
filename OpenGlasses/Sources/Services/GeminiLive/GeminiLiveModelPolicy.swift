import Foundation

/// Which model id to hand the Gemini Live socket.
///
/// Device-traced 2026-08-23: a key that worked perfectly in Direct mode failed to open a Live
/// session, because the model id we sent was the user's *Direct-mode* model. The Live endpoint
/// (`BidiGenerateContent`) serves a small, separate family; a general text model like
/// `gemini-2.5-flash` is not in it and the socket closes. Nothing validated this — the only
/// live-capable id in the codebase was a fallback reached solely when **no** Gemini model was
/// saved, i.e. never for a user who had configured Gemini at all.
///
/// The rule is deliberately a substitution rather than a refusal. The wearer picked a Gemini model
/// and a working key; the live family is an implementation detail of the endpoint, not a decision
/// they should have to make. But the substitution is *reported*, because a silent model swap is its
/// own kind of lie — the usage tracker and any latency cohort would otherwise be filed under a
/// model that never served the session.
enum GeminiLiveModelPolicy {

    /// Known-live-capable id used when the configured model is not one. This is the value the app
    /// already shipped as its no-model-configured default.
    static let defaultLiveModel = "gemini-2.0-flash-exp"

    struct Resolution: Equatable {
        /// Bare model id (no `models/` prefix) to send in the setup message.
        let model: String
        /// The configured id, when it differed and was replaced. `nil` when no swap happened.
        let substitutedFor: String?

        var didSubstitute: Bool { substitutedFor != nil }
    }

    /// Whether an id names a model the Live endpoint serves.
    ///
    /// Matched on shape rather than an allow-list of exact ids: the live family gains and renames
    /// members faster than we ship, and a stale allow-list would reject a model the user can
    /// legitimately use. Both markers are load-bearing — the family is named either by carrying
    /// `live` in the id, or by being one of the experimental `flash-exp` builds.
    static func isLiveCapable(_ model: String) -> Bool {
        let id = model.lowercased()
        return id.contains("live") || id.contains("flash-exp")
    }

    /// Resolve the configured model id to one the socket will accept.
    static func resolve(configured: String?) -> Resolution {
        let trimmed = (configured ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "models/", with: "")

        guard !trimmed.isEmpty else {
            return Resolution(model: defaultLiveModel, substitutedFor: nil)
        }
        guard !isLiveCapable(trimmed) else {
            return Resolution(model: trimmed, substitutedFor: nil)
        }
        return Resolution(model: defaultLiveModel, substitutedFor: trimmed)
    }

    /// Wire form — what the setup message's `model` field carries.
    static func wireModel(configured: String?) -> String {
        "models/\(resolve(configured: configured).model)"
    }
}
