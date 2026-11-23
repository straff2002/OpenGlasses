import Foundation

/// Fits a native tool turn's tool definitions into a downloaded model's prompt budget before the
/// history is trimmed (Plan MQ P3, found on the phone 2026-11-22). Pure: the caller supplies the
/// token count, measured with the model's own tokenizer and chat template, so every branch runs
/// headlessly.
///
/// The first phone run threw `promptTooLong` on every tool turn before generating: the system
/// prompt, the turn and four Field Assist definitions came to about 4,320 tokens against Gemma 4
/// E2B's 3,456. History trimming could not help, because the history was already empty; the tools
/// were the overflow, and nothing cut them. This is the cut, run at the one chokepoint every local
/// tool turn goes through (`LocalLLMService.generateTurn`), in this order:
///
/// 1. every tool, with its standard definition;
/// 2. every tool, with its compact definition (`OnDeviceToolSchema.Limits.compact`: a shorter
///    tool description, optional properties' descriptions dropped, required ones cut hard; every
///    node keeps its `type` and nesting stays at most two levels);
/// 3. compact, dropping one tool at a time from the **lowest-priority end** (tools arrive in
///    priority order, `LocalNativeToolPolicy.nativeToolNames`);
/// 4. no tools at all: the turn is answered without tools.
///
/// Each step is measured with no history; only once one fits is the history trimmed into the room
/// left (`LocalModelBudget.historyFittingBudget`). Full detail is taken only when it also leaves
/// `historyReserve` for a turn that has history (three short exchanges): otherwise a roomier window
/// would spend its extra room on longer descriptions and keep less of the conversation than a
/// smaller one. Compact definitions and the drops use the whole budget. A tool turn therefore never throws
/// `promptTooLong` because of its definitions, only when the system prompt and the turn alone do
/// not fit, as before.
enum LocalToolFit {

    /// How much of each definition is sent.
    enum Detail: String, Equatable, Sendable, Codable {
        case standard, compact
    }

    /// What the fit chose: the first `kept` tools of the offer, at `detail`.
    struct Choice: Equatable, Sendable {
        let kept: Int
        let detail: Detail
        /// The prompt's tokens with no history at this choice, when it was measured (nil when no
        /// tools were offered, or none could be kept).
        let tokens: Int?
    }

    /// What one generation was sent, for the dispatcher and the record. The names stay in memory
    /// (they are registered tool names, never the model's text); the record keeps counts only.
    struct Report: Equatable, Sendable {
        /// Tools the turn offered this pass.
        let offered: Int
        /// The tools rendered, in priority order: a prefix of the offer.
        let keptNames: [String]
        /// The kept tools went out with compact definitions.
        let compact: Bool
        /// The context window the runtime budgeted this pass with.
        let contextWindow: Int

        var kept: Int { keptNames.count }
        /// Tools the fit dropped for room.
        var dropped: Int { max(0, offered - kept) }
    }

    /// Room full-detail definitions must leave for a turn's history (Plan MQ's audit floor for
    /// three exchanges on Gemma 4 E2B).
    static let historyReserve = 600

    /// Choose what to send. `tokenCount(kept, detail)` returns the prompt's tokens with no history,
    /// the first `kept` tools rendered at `detail`. `reserve`: room the full-detail step must leave
    /// (`historyReserve` when the turn has history, else 0).
    static func choose(offered: Int, budget: Int, reserve: Int = 0,
                       tokenCount: (_ kept: Int, _ detail: Detail) throws -> Int) rethrows -> Choice {
        guard offered > 0 else { return Choice(kept: 0, detail: .standard, tokens: nil) }
        let full = try tokenCount(offered, .standard)
        if full <= budget - max(0, reserve) { return Choice(kept: offered, detail: .standard, tokens: full) }
        for kept in stride(from: offered, through: 1, by: -1) {
            let tokens = try tokenCount(kept, .compact)
            if tokens <= budget { return Choice(kept: kept, detail: .compact, tokens: tokens) }
        }
        return Choice(kept: 0, detail: .standard, tokens: nil)
    }

    /// A tool spec's name (`{"function": {"name": …}}`), or nil.
    static func name(of spec: [String: Any]) -> String? {
        (spec["function"] as? [String: Any])?["name"] as? String
    }

    /// The names a dispatcher may run after a generation: the kept names when the runtime fitted
    /// the tools, else everything the turn offered.
    static func dispatchable(offered: [String], report: Report?) -> Set<String> {
        guard let report else { return Set(offered) }
        return Set(report.keptNames).intersection(offered)
    }
}
