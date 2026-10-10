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
/// # Gemini 3 and later: a level, not a budget
///
/// A Gemini 3 model takes `thinkingLevel`, a named level, where 2.5 took a token count
/// (`GeminiThinkingStyle`). A level does not cap what thinking spends: `maxOutputTokens` is still a
/// hard cutoff over thinking and the answer together, and a turn that reaches it while thinking
/// comes back empty. These models think by default and none can switch it off, so every turn to
/// one, plain turns included, names its level and is given `thinkingHeadroom(for:)` on top of the
/// answer's allowance. The headroom is a ceiling, not a spend: only tokens used are billed.
///
/// Pure and table-tested: the numbers live here with their reasoning, not as literals at call sites.
enum GeminiBudgetPolicy {

    struct Budget: Equatable {
        /// `generationConfig.maxOutputTokens` — covers thinking *and* the answer.
        let maxOutputTokens: Int
        /// `generationConfig.thinkingConfig.thinkingBudget` (Gemini 2.x), or nil to omit the key.
        let thinkingBudget: Int?
        /// `generationConfig.thinkingConfig.thinkingLevel` (Gemini 3 and later), or nil to omit
        /// the key. Never set together with `thinkingBudget`: sending both is a 400.
        let thinkingLevel: ReasoningEffort?

        init(maxOutputTokens: Int, thinkingBudget: Int? = nil, thinkingLevel: ReasoningEffort? = nil) {
            self.maxOutputTokens = maxOutputTokens
            self.thinkingBudget = thinkingBudget
            self.thinkingLevel = thinkingLevel
        }

        /// Tokens set aside for thinking: the budget itself, or the level's headroom.
        var thinkingAllowance: Int {
            thinkingBudget ?? thinkingLevel.map(GeminiBudgetPolicy.thinkingHeadroom(for:)) ?? 0
        }

        /// Tokens that remain for the reply once thinking has taken its share. Guaranteed under a
        /// budget; under a level it holds for as long as thinking stays inside its headroom.
        var answerAllowance: Int { maxOutputTokens - thinkingAllowance }

        /// `generationConfig` fragment, ready to merge into the request body.
        var generationConfig: [String: Any] {
            var config: [String: Any] = ["maxOutputTokens": maxOutputTokens]
            if let thinkingLevel {
                config["thinkingConfig"] = ["thinkingLevel": thinkingLevel.rawValue]
            } else if let thinkingBudget {
                config["thinkingConfig"] = ["thinkingBudget": thinkingBudget]
            }
            return config
        }
    }

    /// Deliberation allowed on a tool-selection turn. Enough to choose a tool and shape its
    /// arguments; far short of the allowance, so the answer can never be starved.
    static let toolTurnThinkingBudget = 512

    /// Raised from 1024: that ceiling was set when nothing was competing for it. It must now cover
    /// the thinking budget *plus* a full answer, and a tool turn's reply can carry a spoken summary
    /// alongside the call.
    static let toolTurnMaxOutputTokens = 2048

    /// Room left for thinking at each level, on top of the answer's allowance. The docs give no
    /// token figure for a level, so these are ceilings chosen to sit well clear of what a level
    /// spends on a spoken turn while still stopping a runaway; the largest total is far under any
    /// Gemini 3 model's output limit. Levels a Gemini model has no name for fall to the nearest
    /// one (`GeminiThinkingStyle.nearestLevel`) before they reach here.
    static func thinkingHeadroom(for level: ReasoningEffort) -> Int {
        switch level {
        case .none, .minimal: return 1_024
        case .low: return 4_096
        case .medium: return 8_192
        case .high, .xhigh: return 16_384
        }
    }

    /// The budget for one Gemini REST turn at Automatic on a model that takes a thinking budget
    /// (Gemini 2.x, and ids `GeminiThinkingStyle` cannot place).
    ///
    /// - Parameters:
    ///   - includesTools: whether the tool-declaration set is attached — the condition that makes
    ///     the empty-completion failure reachable.
    ///   - configuredMaxTokens: the user's `Config.maxTokens`, used for plain turns as before.
    static func budget(includesTools: Bool, configuredMaxTokens: Int) -> Budget {
        guard includesTools else {
            // No tools, no long declaration set — the original behaviour, unchanged. Thinking stays
            // unconstrained here because nothing has been observed to go wrong with it.
            return Budget(maxOutputTokens: configuredMaxTokens)
        }
        return Budget(maxOutputTokens: toolTurnMaxOutputTokens, thinkingBudget: toolTurnThinkingBudget)
    }

    /// The budget for a turn with an explicit thinking budget: the answer's allowance sits on top
    /// of it, so the two never compete.
    static func budget(thinkingBudget: Int, includesTools: Bool, configuredMaxTokens: Int) -> Budget {
        Budget(maxOutputTokens: thinkingBudget + answerTokens(includesTools: includesTools,
                                                              configuredMaxTokens: configuredMaxTokens),
               thinkingBudget: thinkingBudget)
    }

    /// The budget for a turn to a model that takes a thinking level: the level, and its headroom on
    /// top of the answer's allowance.
    static func budget(thinkingLevel: ReasoningEffort, includesTools: Bool, configuredMaxTokens: Int) -> Budget {
        Budget(maxOutputTokens: thinkingHeadroom(for: thinkingLevel)
                   + answerTokens(includesTools: includesTools, configuredMaxTokens: configuredMaxTokens),
               thinkingLevel: thinkingLevel)
    }

    /// What the answer alone is allowed: the tool turn's ceiling, or the configured maximum.
    private static func answerTokens(includesTools: Bool, configuredMaxTokens: Int) -> Int {
        includesTools ? toolTurnMaxOutputTokens : configuredMaxTokens
    }

    /// `generationConfig` fragment for an Automatic budget-style turn, ready to merge into the
    /// request body.
    static func generationConfig(includesTools: Bool, configuredMaxTokens: Int) -> [String: Any] {
        budget(includesTools: includesTools, configuredMaxTokens: configuredMaxTokens).generationConfig
    }
}
