import Foundation

/// What a request to one Claude model may carry (Plan IE P1).
///
/// The Messages API stopped being one contract. A request the previous model in a line accepts is
/// one its successor refuses with a 400: a forced tool choice, a sampling parameter, a thinking
/// configuration. So what a request may carry is read from the model id here, in one table, and
/// the request builder (`AnthropicRequest`) and `ReasoningPolicy` both ask this type instead of
/// each keeping its own idea of the rules.
///
/// **An id the table does not know gets the strictest contract.** A model released after this
/// build is far more likely to have dropped a parameter than to have regained one, so an unknown
/// id is sent the shape every current model accepts: no forced tool choice, no sampling
/// parameters, no effort, and room in the output for thinking it may do by default.
///
/// Pure and table-tested. Read 2026-10-10 against the provider's per-model notes.
struct AnthropicModelContract: Equatable, Sendable {

    /// The provider's effort vocabulary, lowest first. `max` is in the table because the models
    /// take it; the app never sends it (see `ReasoningEffort`).
    enum Effort: String, CaseIterable, Comparable, Sendable {
        case low, medium, high, xhigh, max

        static func < (lhs: Effort, rhs: Effort) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// `tool_choice` may name a tool (`tool`) or demand any call (`any`). Where it may not, the
    /// request sends `auto` and asks for the call in words.
    let allowsForcedToolChoice: Bool
    /// The model thinks before it answers when the request says nothing about thinking. Thinking
    /// is billed as output and counts toward `max_tokens`, so this decides the output room.
    let thinksByDefault: Bool
    /// The `output_config.effort` levels the model takes. Empty means the field itself is an
    /// error on this model and is never sent.
    let effortLevels: [Effort]
    /// Non-default `temperature`, `top_p` or `top_k` are accepted.
    let allowsSamplingParameters: Bool
    /// False for an id no row matched.
    let isKnownModel: Bool

    init(allowsForcedToolChoice: Bool, thinksByDefault: Bool, effortLevels: [Effort],
         allowsSamplingParameters: Bool, isKnownModel: Bool = true) {
        self.allowsForcedToolChoice = allowsForcedToolChoice
        self.thinksByDefault = thinksByDefault
        self.effortLevels = effortLevels
        self.allowsSamplingParameters = allowsSamplingParameters
        self.isKnownModel = isKnownModel
    }

    /// The contract for an id the table does not recognise.
    static let strictest = AnthropicModelContract(
        allowsForcedToolChoice: false, thinksByDefault: true, effortLevels: [],
        allowsSamplingParameters: false, isKnownModel: false)

    // MARK: - Output room

    /// The output cap for a request with `base` as the app's own ceiling. A model that thinks by
    /// default spends its thinking out of the same allowance as its answer, so a 1,024-token tool
    /// turn (or a 200-token one-shot) can come back with a `max_tokens` stop and no text at all.
    /// Those models are never capped below `ReasoningPolicy.reasoningOutputFloor`; every other
    /// model keeps the cap it had.
    func outputCap(base: Int) -> Int {
        thinksByDefault ? Swift.max(base, ReasoningPolicy.reasoningOutputFloor) : base
    }

    // MARK: - The table

    private static let allEfforts: [Effort] = [.low, .medium, .high, .xhigh, .max]

    /// One row per family, most specific prefix first: `claude-sonnet-5-5` has to be tried before
    /// `claude-sonnet-5`, and `claude-fable-5-1` before `claude-fable-5`.
    private static let rows: [(prefix: String, contract: AnthropicModelContract)] = [
        ("claude-fable-5-1", .init(allowsForcedToolChoice: false, thinksByDefault: true,
                                   effortLevels: allEfforts, allowsSamplingParameters: false)),
        ("claude-mythos-5-1", .init(allowsForcedToolChoice: false, thinksByDefault: true,
                                    effortLevels: allEfforts, allowsSamplingParameters: false)),
        ("claude-fable-5", .init(allowsForcedToolChoice: true, thinksByDefault: true,
                                 effortLevels: allEfforts, allowsSamplingParameters: false)),
        ("claude-mythos-5", .init(allowsForcedToolChoice: true, thinksByDefault: true,
                                  effortLevels: allEfforts, allowsSamplingParameters: false)),
        ("claude-opus-5-5", .init(allowsForcedToolChoice: false, thinksByDefault: true,
                                  effortLevels: allEfforts, allowsSamplingParameters: false)),
        ("claude-opus-5", .init(allowsForcedToolChoice: true, thinksByDefault: true,
                                effortLevels: allEfforts, allowsSamplingParameters: false)),
        ("claude-opus-4-8", .init(allowsForcedToolChoice: true, thinksByDefault: false,
                                  effortLevels: allEfforts, allowsSamplingParameters: false)),
        ("claude-opus-4-7", .init(allowsForcedToolChoice: true, thinksByDefault: false,
                                  effortLevels: allEfforts, allowsSamplingParameters: false)),
        ("claude-sonnet-5-5", .init(allowsForcedToolChoice: false, thinksByDefault: true,
                                    effortLevels: allEfforts, allowsSamplingParameters: false)),
        ("claude-sonnet-5", .init(allowsForcedToolChoice: true, thinksByDefault: true,
                                  effortLevels: allEfforts, allowsSamplingParameters: false)),
        ("claude-haiku-5-5", .init(allowsForcedToolChoice: true, thinksByDefault: true,
                                   effortLevels: allEfforts, allowsSamplingParameters: false)),
        // 4.6 has no `xhigh`: it arrived with Opus 4.7.
        ("claude-opus-4-6", .init(allowsForcedToolChoice: true, thinksByDefault: false,
                                  effortLevels: [.low, .medium, .high, .max],
                                  allowsSamplingParameters: true)),
        ("claude-sonnet-4-6", .init(allowsForcedToolChoice: true, thinksByDefault: false,
                                    effortLevels: [.low, .medium, .high, .max],
                                    allowsSamplingParameters: true)),
        ("claude-opus-4-5", .init(allowsForcedToolChoice: true, thinksByDefault: false,
                                  effortLevels: [.low, .medium, .high],
                                  allowsSamplingParameters: true)),
    ]

    /// Families from before the effort setting: they take the old request shape whole, and
    /// `output_config.effort` is an error on them.
    private static let olderFamilies = [
        "claude-haiku-4-5", "claude-sonnet-4-5", "claude-opus-4-1", "claude-opus-4-0",
        "claude-sonnet-4-0", "claude-opus-4", "claude-sonnet-4",
    ]

    private static let older = AnthropicModelContract(
        allowsForcedToolChoice: true, thinksByDefault: false, effortLevels: [],
        allowsSamplingParameters: true)

    /// The contract for a model id.
    ///
    /// An id is matched by family: the row's prefix, then either nothing or a suffix that is not
    /// another version number. So `claude-sonnet-5-5-20260901` and `claude-opus-4-5@20251101` are
    /// their families, while `claude-sonnet-5-6` is not `claude-sonnet-5` — it is a model this
    /// build has never heard of, and gets `strictest`. Anything a models listing puts in front of
    /// the name (`anthropic.claude-…`) is ignored.
    static func contract(for model: String) -> AnthropicModelContract {
        var id = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = id.range(of: "claude-") { id = String(id[name.lowerBound...]) }

        for row in rows where isFamilyMember(id, of: row.prefix) { return row.contract }
        for prefix in olderFamilies where isFamilyMember(id, of: prefix) { return older }
        // Every third-generation id is settled: nothing newer will be named `claude-3-…`.
        if id.hasPrefix("claude-3-") { return older }
        return strictest
    }

    /// Whether `id` is `prefix` itself or a snapshot of it. What follows the prefix must start at
    /// a separator, and its first part must not be a one- or two-digit number: that is the next
    /// version in the line (`-5`, `-10`), not a date (`-20260901`) or a label (`-latest`).
    private static func isFamilyMember(_ id: String, of prefix: String) -> Bool {
        guard id.hasPrefix(prefix) else { return false }
        let rest = id.dropFirst(prefix.count)
        guard let separator = rest.first else { return true }
        guard separator == "-" || separator == "@" || separator == ":" else { return false }
        let part = rest.dropFirst().prefix { $0 != "-" && $0 != "@" && $0 != ":" }
        let isVersionNumber = !part.isEmpty && part.count <= 2 && part.allSatisfy(\.isNumber)
        return !isVersionNumber
    }

    // MARK: - Strict tool schemas

    /// Whether a tool's `input_schema` may be marked `strict: true`. The service refuses a strict
    /// tool whose schema leaves an object open, so every object level must close itself with
    /// `additionalProperties: false` and list its `required` properties. A schema that does not
    /// qualify is simply sent without `strict` — the call still works, only the guarantee that
    /// its arguments validate is given up.
    static func schemaQualifiesForStrict(_ schema: [String: Any]) -> Bool {
        if isObjectSchema(schema) {
            guard let closed = schema["additionalProperties"] as? Bool, closed == false,
                  schema["required"] is [String] else { return false }
        }
        if let properties = schema["properties"] as? [String: Any] {
            for value in properties.values {
                guard let child = value as? [String: Any], schemaQualifiesForStrict(child) else { return false }
            }
        }
        if let items = schema["items"] as? [String: Any], !schemaQualifiesForStrict(items) { return false }
        for key in ["anyOf", "oneOf", "allOf"] {
            guard let options = schema[key] as? [[String: Any]] else { continue }
            if !options.allSatisfy(schemaQualifiesForStrict) { return false }
        }
        for key in ["$defs", "definitions"] {
            guard let definitions = schema[key] as? [String: Any] else { continue }
            for value in definitions.values {
                guard let child = value as? [String: Any], schemaQualifiesForStrict(child) else { return false }
            }
        }
        return true
    }

    private static func isObjectSchema(_ schema: [String: Any]) -> Bool {
        if let type = schema["type"] as? String { return type == "object" }
        if let types = schema["type"] as? [String] { return types.contains("object") }
        return schema["properties"] != nil
    }
}
