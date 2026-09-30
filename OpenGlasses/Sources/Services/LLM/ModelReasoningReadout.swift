import Foundation

/// The model editor's two read-only reasoning lines (Plan GC P3), from the same route selection the
/// request builder makes — so what the tester reads is what goes on the wire. Pure, so the view
/// carries no logic and the wording is table-tested.
enum ModelReasoningReadout {

    struct Lines: Equatable {
        /// e.g. "Medium · Responses API", "None · Chat Completions", "Not applicable".
        let value: String
        /// One plain sentence: why this endpoint and level.
        let explanation: String
    }

    /// Route reasons that say little about the level itself. When one of them applies and the
    /// reasoning resolution has a more specific story ("The nearest setting this model accepts.",
    /// "Automatic sends nothing, so the provider's default applies."), that story is shown instead.
    private static let genericRouteReasons: Set<OpenAIRouteSelector.Reason> = [
        .otherProvider, .noToolsAttached, .explicitNone,
    ]

    static func lines(for selection: OpenAIRouteSelector.Selection) -> Lines {
        let explanation: String
        if genericRouteReasons.contains(selection.reason), selection.reasoning.reason != .asSet {
            explanation = selection.reasoning.reason.explanation
        } else {
            explanation = selection.reason.explanation
        }
        return Lines(value: selection.displayValue, explanation: explanation)
    }
}
