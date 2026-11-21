import Foundation

/// Which Field Assist tools a downloaded model is offered on one turn (Plan MQ P0). Pure.
///
/// The local path offers a downloaded model only the everyday safe set today
/// (`LLMService.localToolNames`), so a technician offline on a downloaded model cannot open a job,
/// log a reading or run a calculation by voice — although `OfflineToolPolicy` marks every one of
/// those tools as working offline. This is the selector that closes the gap once a model has
/// earned it:
///
/// 1. **Only for a qualified model, only with Field Assist on.** A model is qualified when its
///    catalog entry carries device evidence for tool calls (`LocalModelCatalog.qualifiesForFieldAssistTools`).
///    Until then the answer is empty: an unbadged model keeps the everyday set and nothing more
///    (decision 6).
/// 2. **A priority list, offline-filtered.** `priority`, narrowed to what is registered and what
///    `OfflineToolPolicy` offers on the phone.
/// 3. **The turn's own words first.** `OfflineKeywordRouter.fieldToolHints` puts the tools the turn
///    names ahead of the rest; the remainder keep the priority order.
/// 4. **At most `perTurnLimit` (5, decision 3)**, then cut to the model's definition budget: a tool
///    whose definition doesn't fit is skipped, not the rest.
///
/// Manual questions are not on this list on purpose: `manual_lookup` returns thousands of
/// characters, and Plan MP's path (search in code, then a reader, then `ManualReadingCheck`)
/// answers them instead.
///
/// Nothing calls this live yet; P1 wires it into the local turn behind a flag.
enum FieldAssistLocalToolSet {

    /// The Field Assist tools a job is run from by voice, in priority order. `field_session` leads
    /// because opening a job is the first thing a technician says.
    static let priority: [String] = [
        "field_session", "reading", "evidence", "equipment_lookup", "domain_calc",
        "procedure_runner", "table_lookup", "show_source",
    ]

    /// Tools offered on one turn (decision 3).
    static let perTurnLimit = 5

    struct Candidate: Equatable {
        let name: String
        let estimatedTokens: Int
    }

    /// The names for one turn, in the order they are offered.
    ///
    /// - Parameters:
    ///   - registered: the registry's tool names after its own exclusions (disabled, HIPAA, sealed).
    ///   - fieldAssistActive: Field Assist is on for this user.
    ///   - modelQualified: the selected model carries device evidence for tool calls.
    ///   - utterance: the turn's own words.
    ///   - estimatedTokens: a definition's size, by name (`OnDeviceToolSchema.estimatedTokens`).
    ///   - budgetTokens: what the model's prompt can spare for definitions
    ///     (`LocalModelBudget.toolDefinitionBudget(for:)`).
    static func select(registered: [String],
                       fieldAssistActive: Bool,
                       modelQualified: Bool,
                       utterance: String,
                       estimatedTokens: (String) -> Int,
                       budgetTokens: Int) -> [String] {
        guard fieldAssistActive, modelQualified else { return [] }
        let available = Set(OfflineToolPolicy.offlineNames(registered))
        let offered = priority.filter(available.contains)
        let hinted = OfflineKeywordRouter.fieldToolHints(utterance).filter(offered.contains)
        let ordered = hinted + offered.filter { !hinted.contains($0) }
        let candidates = ordered.prefix(perTurnLimit).map {
            Candidate(name: $0, estimatedTokens: estimatedTokens($0))
        }
        return fit(Array(candidates), budget: budgetTokens).map(\.name)
    }

    /// `candidates` in order, kept while the running total stays within `budget`. One that does not
    /// fit is skipped, not the rest: a later, smaller definition may still fit.
    static func fit(_ candidates: [Candidate], budget: Int) -> [Candidate] {
        var used = 0
        var kept: [Candidate] = []
        for candidate in candidates where used + candidate.estimatedTokens <= budget {
            used += candidate.estimatedTokens
            kept.append(candidate)
        }
        return kept
    }
}
