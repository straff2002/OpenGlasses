import Foundation

/// Which thinking control a Gemini model takes on `generateContent`, read from its id.
///
/// # The failure this prevents
///
/// Every Gemini REST turn that set thinking sent `thinkingConfig.thinkingBudget`, a token count.
/// That is the 2.5 family's control. Gemini 3 and later take `thinkingLevel`, a named level, and
/// the two are not interchangeable: a budget of 0 cannot switch a Gemini 3 model's thinking off,
/// the levels a model takes differ from model to model (`minimal` is an error on
/// `gemini-3.8-flash`), `thinkingLevel` on a 2.5 model is an error, and sending both is a 400.
///
/// # What was read, and when
///
/// Google's thinking guide, the Gemini 3.8 Flash migration notes and the `generateContent` API
/// reference, 2026-10-10:
/// - 2.5 models take `thinkingBudget` only. 2.5 Pro cannot switch thinking off (128 to 32768);
///   2.5 Flash takes 0 to 24576; 2.5 Flash-Lite takes 0 or 512 to 24576.
/// - Gemini 3 and later take `thinkingLevel`. `thinkingBudget` is still accepted there for
///   backward compatibility, and the migration notes say to replace it.
/// - Levels and defaults: 3.8 Flash low/medium/high (default medium); 3.6 Flash all four (medium);
///   3.5 and 3.1 Flash-Lite all four (minimal); 3.1 Pro low/medium/high (high); 3 Flash all four
///   (high); 3 Pro low/high (high); 3.1 Flash-Lite Image minimal/high (minimal).
/// - No Gemini 3 model can switch thinking off; `minimal` is the least a model that takes it does.
///
/// # Ids the table does not name
///
/// An id with a version of 3 or later that is not listed (a new point release) is sent a level,
/// from the two every listed chat model takes: `low` and `high`. An id with no readable version
/// (a tuned model, an experimental name, an older `gemini-pro`) is sent a budget, the one shape
/// every current model accepts. The `-latest` aliases only ever point at current models, so they
/// are treated as an unlisted Gemini 3 id.
///
/// Pure and table-tested.
enum GeminiThinkingStyle: Equatable {
    /// `thinkingConfig.thinkingBudget`: Gemini 2.x and ids with no readable version.
    /// - `floor`: the smallest budget above zero the model takes.
    /// - `canDisable`: whether a budget of 0 is accepted.
    case budget(floor: Int, canDisable: Bool)
    /// `thinkingConfig.thinkingLevel`: Gemini 3 and later. `accepted` is lowest first;
    /// `providerDefault` is nil when the id is not one the docs list.
    case level(accepted: [ReasoningEffort], providerDefault: ReasoningEffort?)

    /// The levels every listed Gemini 3 chat model takes.
    static let commonLevels: [ReasoningEffort] = [.low, .high]

    private static let allLevels: [ReasoningEffort] = [.minimal, .low, .medium, .high]
    private static let noMinimal: [ReasoningEffort] = [.low, .medium, .high]

    /// Listed Gemini 3 models, matched by prefix, most specific first, so a dated snapshot or a
    /// `-preview` suffix resolves to its family.
    private static let levelRows: [(prefix: String, accepted: [ReasoningEffort], providerDefault: ReasoningEffort)] = [
        ("gemini-3.8-flash", noMinimal, .medium),
        ("gemini-3.6-flash", allLevels, .medium),
        ("gemini-3.5-flash-lite", allLevels, .minimal),
        ("gemini-3.1-flash-lite-image", [.minimal, .high], .minimal),
        ("gemini-3.1-flash-lite", allLevels, .minimal),
        ("gemini-3.1-pro", noMinimal, .high),
        ("gemini-3-flash", allLevels, .high),
        ("gemini-3-pro", commonLevels, .high),
    ]

    static func style(for model: String) -> GeminiThinkingStyle {
        var id = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // The models list returns ids as `models/<id>`.
        if id.hasPrefix("models/") { id.removeFirst("models/".count) }

        guard let major = majorVersion(of: id) else {
            if id.hasPrefix("gemini-"), id.hasSuffix("-latest") {
                return .level(accepted: commonLevels, providerDefault: nil)
            }
            return budgetStyle(for: id)
        }
        guard major >= 3 else { return budgetStyle(for: id) }
        if let row = levelRows.first(where: { id.hasPrefix($0.prefix) }) {
            return .level(accepted: row.accepted, providerDefault: row.providerDefault)
        }
        return .level(accepted: commonLevels, providerDefault: nil)
    }

    /// The number straight after `gemini-`: 2 for `gemini-2.5-flash`, 3 for `gemini-3-flash-preview`.
    /// Nil when the id does not start that way (`gemini-pro`, `gemini-exp-1206`, a tuned model).
    private static func majorVersion(of id: String) -> Int? {
        guard id.hasPrefix("gemini-") else { return nil }
        let digits = id.dropFirst("gemini-".count).prefix(while: \.isNumber)
        return Int(digits)
    }

    private static func budgetStyle(for id: String) -> GeminiThinkingStyle {
        if id.contains("-pro") { return .budget(floor: 128, canDisable: false) }
        if id.contains("flash-lite") { return .budget(floor: 512, canDisable: true) }
        return .budget(floor: 0, canDisable: true)
    }

    /// The level a Gemini 3 model is sent for `requested`: that level, or the nearest it takes
    /// (ties go down). `none` and anything below the model's lowest become its lowest, because
    /// thinking cannot be switched off; `xhigh` becomes `high`.
    static func nearestLevel(_ requested: ReasoningEffort, accepted: [ReasoningEffort]) -> ReasoningEffort {
        if accepted.contains(requested) { return requested }
        let lower = accepted.last { $0 < requested }
        let higher = accepted.first { $0 > requested }
        return lower ?? higher ?? requested
    }
}
