import Foundation

/// Plan CO Item 2 — how much of a Gemini turn's output allowance may be spent thinking.
///
/// # The failure this prevents
///
/// On a thinking model, reasoning tokens are drawn from the *same* budget as the answer. The
/// Gemini tool-calling turn sent our full system prompt and the entire tool-declaration set with
/// `maxOutputTokens: 1024` and no `thinkingConfig` at all, so an unbounded reasoning pass could
/// consume the whole allowance and leave nothing for the reply. What comes back is a 200 with a
/// `STOP` finish reason and zero output tokens — not a truncation, not an error, just nothing.
///
/// The tool turn is the worst place for it: that is the turn that was about to *do* something.
/// And the asymmetry is the tell — `GeminiLiveService` has capped the live path at
/// `thinkingBudget: 0` since it was written. The REST path never got the same treatment.
///
/// # Why not zero
///
/// Zero is proven in our own codebase and would be the safe default, but the live path answers
/// conversationally while this one chooses between 36+ tools and fills in their arguments — the
/// step that most benefits from a moment's deliberation. So the tool turn gets a real but bounded
/// budget, and the allowance is raised so the budget is a floor under the answer rather than a
/// competitor to it.
///
/// Pure and table-tested: the numbers live here with their reasoning, not as literals at call sites.
enum GeminiBudgetPolicy {

    struct Budget: Equatable {
        /// `generationConfig.maxOutputTokens` — covers thinking *and* the answer.
        let maxOutputTokens: Int
        /// `generationConfig.thinkingConfig.thinkingBudget`, or nil to omit the key entirely.
        let thinkingBudget: Int?

        /// Tokens guaranteed to remain for the reply once thinking has taken its share.
        var answerAllowance: Int { maxOutputTokens - (thinkingBudget ?? 0) }
    }

    /// Deliberation allowed on a tool-selection turn. Enough to choose a tool and shape its
    /// arguments; far short of the allowance, so the answer can never be starved.
    static let toolTurnThinkingBudget = 512

    /// Raised from 1024: that ceiling was set when nothing was competing for it. It must now cover
    /// the thinking budget *plus* a full answer, and a tool turn's reply can carry a spoken summary
    /// alongside the call.
    static let toolTurnMaxOutputTokens = 2048

    /// The budget for one Gemini REST turn.
    ///
    /// - Parameters:
    ///   - includesTools: whether the tool-declaration set is attached — the condition that makes
    ///     the empty-completion failure reachable.
    ///   - configuredMaxTokens: the user's `Config.maxTokens`, used for plain turns as before.
    static func budget(includesTools: Bool, configuredMaxTokens: Int) -> Budget {
        guard includesTools else {
            // No tools, no long declaration set — the original behaviour, unchanged. Thinking stays
            // unconstrained here because nothing has been observed to go wrong with it.
            return Budget(maxOutputTokens: configuredMaxTokens, thinkingBudget: nil)
        }
        return Budget(maxOutputTokens: toolTurnMaxOutputTokens, thinkingBudget: toolTurnThinkingBudget)
    }

    /// `generationConfig` fragment for a turn, ready to merge into the request body.
    static func generationConfig(includesTools: Bool, configuredMaxTokens: Int) -> [String: Any] {
        let budget = budget(includesTools: includesTools, configuredMaxTokens: configuredMaxTokens)
        var config: [String: Any] = ["maxOutputTokens": budget.maxOutputTokens]
        if let thinking = budget.thinkingBudget {
            config["thinkingConfig"] = ["thinkingBudget": thinking]
        }
        return config
    }
}
