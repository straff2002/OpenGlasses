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
        let isLocal: Bool
    }

    /// Spoken when the turn falls over from `from` to `to`. The caller speaks this on the **first**
    /// hop of a turn only (not once per hop, not on restore).
    static func fallbackPhrase(from: Model, to: Model, failure: ModelFallbackChain.FailureClass) -> String {
        switch failure {
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
    static func exhaustionPhrase(lastError: Error) -> String {
        let reason: String
        switch ModelFallbackChain.classify(lastError) {
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
        return "I couldn't get a response — \(reason)."
    }
}
