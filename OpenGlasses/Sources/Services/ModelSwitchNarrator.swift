import Foundation

/// Pure phrasing for the "tell the user what the app is doing" model-switch notices (BK P2c).
///
/// The cascade (P2b) already hops between models on failure, but every switch was silent — the
/// user had no signal that the model, and therefore the cost/latency profile, changed under them.
/// This builds the spoken/HUD line for three moments; the live layer decides *when* to speak
/// (first fallback hop only, interactive turns only) and restarts the thinking sound afterwards.
///
/// Wording is class-based and honest (this is the feature-honesty plan): a timeout isn't called a
/// rate-limit, an overflow isn't called an outage.
enum ModelSwitchNarrator {

    /// The minimum a phrase needs to know about a model.
    struct Model: Equatable {
        let name: String
        /// The on-device MLX model, which the overflow and outage lines call "the on-device model".
        let isLocal: Bool
        /// Runs on this phone (MLX or Apple Intelligence): a credential line says "I'm answering on
        /// this phone" rather than naming it. Defaults to `isLocal`.
        let isOnDevice: Bool

        init(name: String, isLocal: Bool, isOnDevice: Bool? = nil) {
            self.name = name
            self.isLocal = isLocal
            self.isOnDevice = isOnDevice ?? isLocal
        }
    }

    /// Spoken when the turn falls over from `from` to `to`. The caller speaks this on the **first**
    /// hop of a turn only (not once per hop, not on restore).
    ///
    /// `gap` is `from`'s credential gap when the hop was a missing or refused sign-in or key
    /// (Plan KL P0): that is a setting, not an outage, so the line names the service and what is
    /// wrong with it, and never says "unavailable".
    static func fallbackPhrase(from: Model, to: Model, failure: ModelFallbackChain.FailureClass,
                               gap: CredentialGap? = nil) -> String {
        if let gap {
            return to.isOnDevice
                ? "\(gap.sentenceOpening), so I'm answering on this phone."
                : "\(gap.sentenceOpening), so I'm using \(to.name)."
        }
        switch failure {
        case .visionUnavailable:
            return "\(from.name) can't analyze photos — using \(to.name) for this picture."
        case .needsBiggerWindow:
            return from.isLocal
                ? "That's a bit much for the on-device model — switching to \(to.name)."
                : "That's too long for \(from.name) — switching to \(to.name)."
        case .retryOtherModel, .terminalForCandidate:
            return from.isLocal
                ? "The on-device model couldn't handle that — switching to \(to.name)."
                : "\(from.name) is unavailable — switching to \(to.name)."
        case .terminalForTurn:
            // No hop happens on a turn-terminal failure; defensive only.
            return "Switching to \(to.name)."
        }
    }

    /// Spoken when auto-routing (not a failure) deliberately switches to a tier model for this turn.
    static func routingPhrase(to: Model) -> String {
        "Switching to \(to.name) for this."
    }

    /// Spoken instead of the generic error line when the whole chain is exhausted — the real reason.
    static func exhaustionPhrase(lastError: Error, gap: CredentialGap? = nil) -> String {
        "I couldn't get a response — \(exhaustionReason(lastError: lastError, gap: gap))."
    }

    /// The reason half of `exhaustionPhrase`, for a caller that frames it itself (a photo turn
    /// says it took the picture first).
    ///
    /// `gap` is the credential gap of the model that threw `lastError`, when the caller knows it
    /// (`LLMService.credentialGap(behind:)`). It names the service only while the error itself is
    /// a credential failure of the same kind, so a stale gap can never explain another failure.
    static func exhaustionReason(lastError: Error, gap: CredentialGap? = nil) -> String {
        // Plan KL P0: "I don't have working credentials for them" named neither the service nor
        // the fix. The exhaustion line is the turn's answer, so it is said every time.
        if let gap, CredentialGap.kind(of: lastError) == gap.kind {
            return gap.reason
        }
        // Too large is its own reason whichever way it was classified: before a tool ran it may
        // have hopped, after one it ended the turn — either way "unavailable" would be untrue.
        if lastError is RequestContextBudget.CapacityError || RequestContextBudget.isOverflow(error: lastError) {
            return "the request was too large for this model"
        }
        // So is a model the service would not serve, whatever status carried it (a 400 from the
        // ChatGPT backend, a 404 elsewhere). On the subscription the same refusal comes back both
        // for a model outside the account's catalog and, observed, for one whose own allowance is
        // used up, so the line says both and names neither as certain.
        if case LLMError.apiError(let provider, _, _, let rejection?) = lastError,
           rejection.reason == .modelNotAvailable {
            // "ChatGPT" is the label the subscription's send path throws under.
            return provider == "ChatGPT"
                ? "the chosen model isn't available on your ChatGPT account right now — it may have reached its usage limit, so try again later or pick another model"
                : "the chosen model isn't available on this account, so pick another in Settings"
        }
        // "Unavailable" would send the wearer to wait it out; the same request fails every time.
        if case LLMError.apiError(_, _, _, let rejection?) = lastError,
           rejection.reason == .requestOverTokenRateLimit {
            return "the request is bigger than that AI account allows per minute, so turn on Small context for that model in Settings, or pick another"
        }
        let reason: String
        switch ModelFallbackChain.classify(lastError) {
        case .visionUnavailable:
            reason = "no model could analyze the picture"
        case .needsBiggerWindow:
            reason = "that was too long for all of them"
        case .retryOtherModel:
            if case LLMError.apiError(_, 429, _, _) = lastError {
                reason = "the last one was rate-limited"
            } else {
                reason = "they're all unavailable right now"
            }
        case .terminalForCandidate:
            // A refusal that names the model's own contract is not a credential problem, and
            // saying it was sends the wearer to the wrong setting (Plan IE P0).
            if case LLMError.apiError(_, _, _, let rejection?) = lastError, rejection.reason.isModelContract {
                reason = "the model didn't accept the request, so try another model"
            } else if case LLMError.apiError(_, _, _, let rejection?) = lastError,
                      rejection.reason == .credentialNotAccepted || rejection.reason == .betaHeaderUnknown {
                reason = "the AI service didn't accept the key or sign-in"
            } else if case LLMError.modelDeclined = lastError {
                // Nor is a model that declined (Plan IE P3).
                reason = "the model declined to answer that"
            } else {
                reason = "I don't have working credentials for them"
            }
        case .terminalForTurn:
            reason = "the request couldn't be processed"
        }
        return reason
    }
}
