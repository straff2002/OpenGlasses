import Foundation

/// Pure model-cascade decision logic (BK P2b).
///
/// Today a turn is single-shot: `ModelRoutingPolicy` picks one model, `ConversationTurnRunner`
/// calls `send()` once, and any error — `promptTooLong`, a `429`/quota, an empty completion —
/// falls straight to the generic error line, throwing away the intent to fall over to another
/// model. This type supplies the two deterministic decisions a cascade needs:
///
///  1. **`classify(_:)`** — is a failure worth retrying on a *different* model, fatal to the whole
///     turn, or fatal only to *this* candidate (skip it, try the next)?
///  2. **`next(...)`** — given the ordered candidate list and what's already been tried, which
///     model to hop to, honouring capability filters (vision), the on-device background rule, and
///     the "bigger context window" requirement after an overflow.
///
/// No UIKit / no live services — deliberately headless-testable. The live driver
/// (`LLMService.sendMessageCascading`) wires these to real provider calls.
enum ModelFallbackChain {

    // MARK: - Candidate

    /// One model the cascade may hop to. Derived from a `ModelConfig` by `candidates(...)`.
    struct Candidate: Equatable {
        let id: String
        /// Provider is on-device MLX (`.local`) — must be skipped while the app is backgrounded
        /// (Metal work throws `.backgrounded`). ([[project_local_model_background]])
        let isLocalMLX: Bool
        /// Whether this model accepts image input (`ModelConfig.visionEnabled`).
        let supportsVision: Bool
        /// Effective prompt window in tokens. On-device models use their real (memory-safe)
        /// window; cloud models use a large sentinel so a local overflow always finds a bigger one.
        let contextTokens: Int
    }

    /// Sentinel window for cloud models — far larger than any prompt we build, so `promptTooLong`
    /// on a local model always resolves to a cloud candidate.
    static let cloudContextTokens = 1_000_000

    // MARK: - Failure classification

    enum FailureClass: Equatable {
        /// Transient / model-specific — retry on the next eligible model (`429`, quota, timeout,
        /// empty completion, interrupted stream).
        case retryOtherModel
        /// The prompt overflowed this model — retry only on a model with a *bigger* window.
        case needsBiggerWindow
        /// Fatal for this candidate only (bad/expired key for this provider) — skip it, try next.
        case terminalForCandidate
        /// Fatal for the whole turn — every model would fail identically (malformed request,
        /// invalid configuration) or the user cancelled. Don't cascade.
        case terminalForTurn
    }

    /// Classify a thrown error into a cascade decision.
    static func classify(_ error: Error) -> FailureClass {
        if error is CancellationError { return .terminalForTurn }

        if let local = error as? LocalLLMError {
            switch local {
            case .promptTooLong: return .needsBiggerWindow
            case .backgrounded: return .retryOtherModel   // a cloud candidate can still run
            case .insufficientMemory: return .retryOtherModel   // cloud (or a smaller local model) still fits
            // The model is loaded and working; only this turn's photo is out of reach on it. A
            // cloud candidate has no such ceiling, so cascade rather than end the turn.
            case .insufficientMemoryForPhoto: return .retryOtherModel
            case .modelNotLoaded, .generationFailed, .alreadyGenerating, .alreadyDownloading:
                return .retryOtherModel
            }
        }

        if let llm = error as? LLMError {
            switch llm {
            case .missingAPIKey:
                // Per-candidate: a missing/expired credential (incl. refreshed-OAuth failure,
                // which surfaces here) kills only this provider — another may still work.
                return .terminalForCandidate
            case .invalidConfiguration:
                return .terminalForTurn
            case .invalidResponse, .streamInterrupted:
                // Empty completion (P3) / mid-stream death — transient, try another model.
                return .retryOtherModel
            case .apiError(_, let status, _):
                return classifyStatus(status)
            }
        }

        // URLError timeouts / connectivity — transient, worth another model.
        if let url = error as? URLError {
            switch url.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                 .notConnectedToInternet, .dnsLookupFailed:
                return .retryOtherModel
            default:
                return .retryOtherModel
            }
        }

        // Unknown error — one more model is cheap; the attempt cap bounds it.
        return .retryOtherModel
    }

    private static func classifyStatus(_ status: Int) -> FailureClass {
        switch status {
        case 429, 402, 408:            return .retryOtherModel        // rate-limit / quota / timeout
        case 401, 403:                 return .terminalForCandidate   // auth — this provider only
        case 400, 422:                 return .terminalForTurn        // malformed — fails everywhere
        case 500...599:                return .retryOtherModel        // provider blip
        default:                       return .retryOtherModel
        }
    }

    // MARK: - Next candidate

    /// What the turn requires of any candidate it hops to.
    struct TurnNeeds: Equatable {
        /// The turn carries an image — text-only models can't serve it.
        let requiresVision: Bool
        /// The app is backgrounded — on-device MLX models can't run.
        let isBackgrounded: Bool
    }

    /// The next model to try after the current one failed, or `nil` when the chain is exhausted.
    /// - `failure` gates whether we cascade at all (`.terminalForTurn` ⇒ `nil`) and, for
    ///   `.needsBiggerWindow`, restricts to candidates with a larger window than `currentWindow`.
    /// - `tried` are ids already attempted this turn (never retried).
    static func next(
        candidates: [Candidate],
        tried: Set<String>,
        needs: TurnNeeds,
        failure: FailureClass,
        currentWindow: Int
    ) -> Candidate? {
        guard failure != .terminalForTurn else { return nil }
        return candidates.first { candidate in
            guard !tried.contains(candidate.id) else { return false }
            if needs.requiresVision && !candidate.supportsVision { return false }
            if needs.isBackgrounded && candidate.isLocalMLX { return false }
            if failure == .needsBiggerWindow && candidate.contextTokens <= currentWindow { return false }
            return true
        }
    }

    // MARK: - Candidate list from Config

    /// Build the ordered cascade from the active model + a user-defined fallback order, de-duped.
    /// The active model leads (it's already been chosen for the turn); `fallbackOrder` ids follow
    /// in the user's cost/preference order; any remaining saved models trail so a cascade never
    /// dead-ends while an untried model exists. Unknown ids in `fallbackOrder` are ignored.
    ///
    /// No foreground-hop / app-Shortcut providers exist in the current provider set, so every saved
    /// model is a valid automatic candidate; if one is ever added it must be excluded here (it
    /// would break hands-free operation — see the plan's guardrails).
    static func candidates(
        activeId: String,
        saved: [ModelConfig],
        fallbackOrder: [String]
    ) -> [Candidate] {
        let byId = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var orderedIds: [String] = []
        var seen = Set<String>()
        func push(_ id: String) {
            guard byId[id] != nil, !seen.contains(id) else { return }
            seen.insert(id); orderedIds.append(id)
        }
        push(activeId)
        fallbackOrder.forEach(push)
        saved.forEach { push($0.id) }
        return orderedIds.compactMap { byId[$0] }.map(candidate(from:))
    }

    /// Map a saved model to a cascade candidate.
    static func candidate(from config: ModelConfig) -> Candidate {
        let provider = config.llmProvider
        let isLocalMLX = provider == .local
        let window = isLocalMLX
            ? LocalModelBudget.contextWindow(for: config.model)
            : cloudContextTokens
        return Candidate(
            id: config.id,
            isLocalMLX: isLocalMLX,
            supportsVision: config.visionEnabled,
            contextTokens: window
        )
    }
}

/// Pure cascade driver (BK P2b): run one turn over an ordered candidate chain, hopping on a
/// retry-worthy failure until a model succeeds or the chain is exhausted. The `attempt` closure
/// runs the real provider call for a candidate; the driver owns only the retry/next/cap decisions,
/// so it's unit-tested headlessly with fakes.
enum ModelCascade {
    /// - Parameters:
    ///   - maxAttempts: hard cap on provider calls (bounds latency + token spend even on a long chain).
    ///   - isCancelled: re-checked between hops so a barge-in during one hop doesn't launch the next.
    ///   - onSwitch: invoked once per hop, *before* the retry (the P2c narration seam).
    ///   - attempt: run the turn on this candidate; throws to trigger a hop.
    /// - Returns: the first successful response.
    /// - Throws: `CancellationError` on barge-in; otherwise the *last real* error when the chain is
    ///   exhausted, the attempt cap is hit, or the failure is terminal for the turn.
    static func run(
        candidates: [ModelFallbackChain.Candidate],
        needs: ModelFallbackChain.TurnNeeds,
        maxAttempts: Int,
        isCancelled: () -> Bool = { false },
        onSwitch: (_ from: ModelFallbackChain.Candidate,
                   _ to: ModelFallbackChain.Candidate,
                   _ failure: ModelFallbackChain.FailureClass) async -> Void = { _, _, _ in },
        attempt: (ModelFallbackChain.Candidate) async throws -> String
    ) async throws -> String {
        guard var current = candidates.first else {
            throw LLMError.missingAPIKey("No model configured")
        }
        var tried = Set<String>()
        var attempts = 0
        while true {
            attempts += 1
            tried.insert(current.id)
            do {
                return try await attempt(current)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A barge-in between hops maps to cancellation (→ onCancelled), never a spoken error.
                if isCancelled() { throw CancellationError() }
                let failure = ModelFallbackChain.classify(error)
                guard failure != .terminalForTurn, attempts < maxAttempts else { throw error }
                guard let next = ModelFallbackChain.next(
                    candidates: candidates, tried: tried, needs: needs,
                    failure: failure, currentWindow: current.contextTokens
                ) else { throw error }
                await onSwitch(current, next, failure)
                current = next
            }
        }
    }
}
