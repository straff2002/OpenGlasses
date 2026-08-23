import Foundation

/// Which model id to hand the Gemini Live socket.
///
/// Device-traced 2026-08-23, twice over. First: we sent the user's *Direct-mode* model, and the
/// Live endpoint serves a different family, so the socket closed. Then the hard-coded fallback
/// (`gemini-2.0-flash-exp`) turned out to be **retired upstream** — the endpoint answered
/// "not found for API version v1beta, or is not supported for bidiGenerateContent". A pinned model
/// id in a family that renames this often is a time bomb, and it always detonates the same way:
/// as what looks like a broken API key.
///
/// The first attempt at a fix guessed capability from the id's shape (`live` / `flash-exp`).
/// Checking that against a real account's model list killed it: `gemini-2.5-flash-native-audio-latest`
/// and `gemini-robotics-er-2-streaming-preview` are both live-capable and match neither marker.
/// **Names are not a capability contract.** `ModelService.ListModels` reports
/// `bidiGenerateContent` per model, so the app asks instead of guessing, and this type is reduced
/// to what remains a genuine decision: which of the offered models to prefer.
enum GeminiLiveModelPolicy {

    /// Used only when the model list cannot be fetched (offline, or the call failed). A stable
    /// alias rather than a dated preview: aliases survive the renames that retire the previews.
    static let offlineFallbackModel = "gemini-2.5-flash-native-audio-latest"

    /// Task-specialised live models. They speak `bidiGenerateContent`, but a translation or
    /// robotics model is not a general assistant, and silently defaulting a wearer into one would
    /// be a stranger failure than no session at all. Chosen only if nothing else is offered.
    static let specialisedMarkers = ["translate", "robotics"]

    /// Families documented to support **asynchronous** function calling — the model keeps talking
    /// while a tool runs (`behavior: NON_BLOCKING`).
    ///
    /// This app is built on that behaviour: every declaration is stamped `NON_BLOCKING` and the
    /// tool router acks slow calls and defers results `WHEN_IDLE`. The alternative is documented as
    /// *sequential only* — "the model will not start responding until you've sent the tool
    /// response" — which with 36+ native tools stalls the conversation on every call.
    ///
    /// So capability outranks recency here. Picking the newest model would quietly downgrade the
    /// tool loop, and it would present as the assistant going mute mid-sentence rather than as a
    /// model choice.
    static let asyncToolFamilyMarkers = ["2.5"]

    struct Resolution: Equatable {
        /// Bare model id (no `models/` prefix) to send in the setup message.
        let model: String
        /// The configured id, when it differed and was replaced. `nil` when no swap happened.
        let substitutedFor: String?
        /// True when the list could not be fetched and the offline fallback was used, so a caller
        /// can say "couldn't check what your key supports" rather than reporting a clean choice.
        let usedOfflineFallback: Bool

        var didSubstitute: Bool { substitutedFor != nil }
    }

    /// Strip the wire prefix; ids are compared and stored bare.
    static func bareId(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "models/", with: "")
    }

    /// Pick the best general-purpose model from what the account actually offers.
    ///
    /// Whether a model's family is documented to support asynchronous function calling.
    static func supportsAsyncFunctionCalling(_ id: String) -> Bool {
        asyncToolFamilyMarkers.contains { id.contains($0) }
    }

    /// Preference order, and each step earns its place:
    /// 1. general-purpose over task-specialised — a translate model answers questions in the wrong
    ///    shape entirely;
    /// 2. **async function calling over sequential** — this app's tool loop depends on it, and the
    ///    downgrade is invisible until the assistant stalls mid-sentence on a tool call;
    /// 3. stable aliases (`-latest`) over dated previews — a dated preview is exactly the kind of
    ///    id that gets retired, which is the bug this whole type exists because of;
    /// 4. otherwise the highest version number.
    ///
    /// Note the order of 2 and 4: **newest is not best here.** Ranking by version alone would pick
    /// a newer family whose function calling is sequential, which is a worse assistant on this
    /// device however new the model is.
    static func choose(from available: [String]) -> String? {
        let ids = available.map(bareId).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return nil }

        let general = ids.filter { id in
            !specialisedMarkers.contains { id.lowercased().contains($0) }
        }
        let pool = general.isEmpty ? ids : general

        return pool.sorted { lhs, rhs in
            let lhsAsync = supportsAsyncFunctionCalling(lhs), rhsAsync = supportsAsyncFunctionCalling(rhs)
            if lhsAsync != rhsAsync { return lhsAsync }
            let lhsAlias = lhs.hasSuffix("-latest"), rhsAlias = rhs.hasSuffix("-latest")
            if lhsAlias != rhsAlias { return lhsAlias }
            let lhsVersion = version(of: lhs), rhsVersion = version(of: rhs)
            if lhsVersion != rhsVersion { return lhsVersion > rhsVersion }
            return lhs < rhs   // stable, so the choice does not wander between launches
        }.first
    }

    /// Leading `<major>.<minor>` version in an id, as a comparable number. Unversioned ids sort
    /// last rather than first — an id we cannot read a version from is not evidence of newness.
    static func version(of id: String) -> Double {
        guard let match = id.range(of: #"\d+\.\d+"#, options: .regularExpression) else { return 0 }
        return Double(id[match]) ?? 0
    }

    /// Resolve what to send, given the configured model and the list the account offers.
    ///
    /// A configured model that the account actually offers is always honoured — the wearer's
    /// choice wins whenever it is possible, and only a model the endpoint would refuse is replaced.
    static func resolve(configured: String?, available: [String]) -> Resolution {
        let wanted = bareId(configured ?? "")
        let offered = available.map(bareId)

        guard !offered.isEmpty else {
            let fallback = Resolution(model: offlineFallbackModel,
                                      substitutedFor: wanted.isEmpty ? nil : wanted,
                                      usedOfflineFallback: true)
            return wanted == offlineFallbackModel
                ? Resolution(model: offlineFallbackModel, substitutedFor: nil, usedOfflineFallback: true)
                : fallback
        }
        if !wanted.isEmpty, offered.contains(wanted) {
            return Resolution(model: wanted, substitutedFor: nil, usedOfflineFallback: false)
        }
        let chosen = choose(from: offered) ?? offlineFallbackModel
        return Resolution(model: chosen,
                          substitutedFor: wanted.isEmpty ? nil : wanted,
                          usedOfflineFallback: false)
    }

    /// Wire form — what the setup message's `model` field carries.
    static func wireModel(configured: String?, available: [String]) -> String {
        "models/\(resolve(configured: configured, available: available).model)"
    }
}
