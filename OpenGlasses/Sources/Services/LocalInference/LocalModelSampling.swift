import Foundation

/// A downloaded model's own sampling settings, as its publisher recommends them (Plan MQ H1, P3).
///
/// Every local turn used one set, temperature 0.7 and top-p 0.9, whatever the model. Publishers
/// recommend very different ones (Gemma 4: temperature 1.0, top-p 0.95, top-k 64; LFM2.5:
/// temperature 0.1, top-k 50, repetition penalty 1.1), and a model screened on settings its
/// publisher does not recommend can fail a qualification floor for that reason alone. So an MLX or
/// GGUF catalog entry may carry a `sampling` object, and only the members it sets replace the
/// global value. Every member is optional and decoded only when present.
///
/// A separate `toolTurn` set is allowed, because a call wants less randomness than a sentence. It
/// is applied over the entry's own set on a native tool turn. No entry sets one yet: no publisher
/// we ship recommends tool-turn settings, and none is added without a citation.
///
/// `source` says where the numbers came from. An entry without a published recommendation has no
/// `sampling` at all and keeps the global set. The device qualification record names the set a run
/// used (`resolved(over:toolTurn:)` and `source`).
struct LocalModelSampling: Equatable, Sendable, Decodable {

    /// The members a set may override. Nil leaves the value below it in place.
    struct Members: Equatable, Sendable, Decodable {
        var temperature: Float?
        var topP: Float?
        /// 0 turns top-k off.
        var topK: Int?
        /// 0 turns min-p off.
        var minP: Float?
        var repetitionPenalty: Float?
        var presencePenalty: Float?

        init(temperature: Float? = nil, topP: Float? = nil, topK: Int? = nil, minP: Float? = nil,
             repetitionPenalty: Float? = nil, presencePenalty: Float? = nil) {
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.minP = minP
            self.repetitionPenalty = repetitionPenalty
            self.presencePenalty = presencePenalty
        }

        var isEmpty: Bool { self == Members() }

        /// `values` with every member this set holds put in its place.
        func applied(to values: LocalSamplingConfiguration) -> LocalSamplingConfiguration {
            var result = values
            if let temperature { result.temperature = temperature }
            if let topP { result.topP = topP }
            if let topK { result.topK = topK }
            if let minP { result.minP = minP }
            if let repetitionPenalty { result.repetitionPenalty = repetitionPenalty }
            if let presencePenalty { result.presencePenalty = presencePenalty }
            return result
        }
    }

    /// The entry's own set, for every turn.
    let general: Members
    /// Applied over `general` on a native tool turn.
    let toolTurn: Members?
    /// Where the numbers come from: the publisher's page and the section that states them.
    let source: String

    init(general: Members, toolTurn: Members? = nil, source: String) {
        self.general = general
        self.toolTurn = toolTurn
        self.source = source
    }

    /// The JSON shape: the general members flat beside `source`, and `toolTurn` as an object.
    private enum CodingKeys: String, CodingKey {
        case temperature, topP, topK, minP, repetitionPenalty, presencePenalty, toolTurn, source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        general = Members(
            temperature: try container.decodeIfPresent(Float.self, forKey: .temperature),
            topP: try container.decodeIfPresent(Float.self, forKey: .topP),
            topK: try container.decodeIfPresent(Int.self, forKey: .topK),
            minP: try container.decodeIfPresent(Float.self, forKey: .minP),
            repetitionPenalty: try container.decodeIfPresent(Float.self, forKey: .repetitionPenalty),
            presencePenalty: try container.decodeIfPresent(Float.self, forKey: .presencePenalty))
        toolTurn = try container.decodeIfPresent(Members.self, forKey: .toolTurn)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
    }

    /// The settings a turn runs with: `global`, then this entry's set, then (on a tool turn) its
    /// tool-turn set.
    func resolved(over global: LocalSamplingConfiguration, toolTurn isToolTurn: Bool) -> LocalSamplingConfiguration {
        var values = general.applied(to: global)
        if isToolTurn, let toolTurn { values = toolTurn.applied(to: values) }
        return values
    }

    /// Why a set may not ship. Nil means it may: it names its source, sets something, and every
    /// value is one a sampler can take.
    func validationError(supportsPresencePenalty: Bool) -> String? {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "sampling names no source"
        }
        guard !general.isEmpty || !(toolTurn?.isEmpty ?? true) else { return "sampling sets nothing" }
        for set in [general, toolTurn].compactMap({ $0 }) {
            if let t = set.temperature, !(0...2).contains(t) { return "sampling temperature out of range" }
            if let p = set.topP, !(p > 0 && p <= 1) { return "sampling top-p out of range" }
            if let k = set.topK, k < 0 { return "sampling top-k is negative" }
            if let m = set.minP, !(0...1).contains(m) { return "sampling min-p out of range" }
            if let r = set.repetitionPenalty, r <= 0 { return "sampling repetition penalty must be positive" }
            if set.presencePenalty != nil, !supportsPresencePenalty {
                return "sampling presence penalty is not supported by this runtime"
            }
        }
        return nil
    }

    // MARK: - Global and per-model resolution

    /// The values every local turn ran with before per-model sampling, and still runs with when
    /// the catalog has no set for the model.
    static let global = LocalSamplingConfiguration()

    /// The catalog's set for `modelID`, MLX or GGUF, or nil when it has none.
    static func catalogSampling(for modelID: String?,
                                ggufEntries: () -> [LocalModelCatalog.GGUFEntry] = { LocalModelCatalog.bundledGGUFEntries() })
        -> LocalModelSampling? {
        guard let modelID else { return nil }
        let id = LocalModelID(modelID)
        if let entry = LocalModelCatalog.entry(for: id) { return entry.sampling }
        return ggufEntries().first { $0.id == id }?.sampling
    }

    /// A qualification run's experiment, applied over every tool turn's set: set only by the device
    /// qualification app (`--tool-temperature`), before its first case, and named in its record. The
    /// app never sets it, so a shipping turn is unaffected.
    nonisolated(unsafe) static var qualificationToolTurnOverride: Members?

    /// What a turn on `modelID` samples with: the global set with the catalog's members over it.
    static func configuration(for modelID: String?, toolTurn: Bool,
                              ggufEntries: () -> [LocalModelCatalog.GGUFEntry] = { LocalModelCatalog.bundledGGUFEntries() })
        -> LocalSamplingConfiguration {
        let base = catalogSampling(for: modelID, ggufEntries: ggufEntries)?.resolved(over: global, toolTurn: toolTurn) ?? global
        guard toolTurn, let override = qualificationToolTurnOverride else { return base }
        return override.applied(to: base)
    }
}
