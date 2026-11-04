import Foundation

/// How many tokens a minute a saved model's account takes, learned from the provider's own refusal
/// (Plan KL P1, decision 3).
///
/// A free Groq key refused every turn of one tester's day with 413 `rate_limit_exceeded`: each
/// request was larger than the account's per-minute allowance, a ceiling the app had no way to know
/// until the provider stated it. The refusal states it ("Limit 8000, Requested 11234"), so it is
/// kept here, per saved model, and every later turn on that model is fitted to it before it is
/// sent (`PerMinuteFit`).
///
/// An allowance belongs to one account and one model. It is filed under the saved model's id with
/// a fingerprint of what it was learned for — the provider, the model id and the endpoint — and a
/// read whose fingerprint no longer matches finds nothing: a different provider or another model id
/// starts unknown again. The key is never part of it, not even as a digest: a changed key is caught
/// where the saved models are written (`Config.setSavedModels`, `modelsToForget(old:new:)`), which
/// clears the entry there and then.
///
/// Pure value; `PerMinuteAllowanceStore` keeps it.
struct PerMinuteAllowance: Codable, Equatable, Sendable {

    /// Tokens a minute, as the latest refusal stated it.
    var limit: Int
    /// What the provider counted a refused request as, over the app's own estimate of that same
    /// request (`PerMinuteFit.estimatedTokens`). Applied to every later estimate on this model, so
    /// the fit uses the provider's arithmetic rather than four characters to a token. Nil until a
    /// refusal carried a requested count, or a limit the estimate fell short of.
    var calibration: Double?
    /// What the allowance was learned for (`fingerprint(provider:model:baseURL:)`).
    var fingerprint: String

    /// A calibration outside this range says the estimate measured something else (an image, a
    /// different request), not that tokens are that much larger or smaller than the house
    /// estimate. It is clamped, never trusted past it.
    static let calibrationRange: ClosedRange<Double> = 0.5...2.0

    /// The estimate as the provider would count it.
    func calibrated(_ estimate: Int) -> Int {
        guard let calibration else { return estimate }
        return Int((Double(estimate) * calibration).rounded(.up))
    }

    /// The allowance a refusal teaches.
    ///
    /// - Parameters:
    ///   - limit: the refusal's allowance.
    ///   - requested: what the provider counted the refused request as, when it said.
    ///   - estimate: the app's own estimate of that refused request, when the request path recorded
    ///     one (`PerMinuteFit.estimatedTokens(bodyBytes:outputCap:)`).
    ///   - previous: what was known before, used only while its fingerprint still matches.
    ///
    /// With both figures the calibration is their ratio. With the limit alone the refused request
    /// was, by the provider's count, over the limit; an estimate at or under it was too low by at
    /// least that much, so the calibration is raised to make it so — and a calibration already
    /// higher is kept.
    static func learned(limit: Int, requested: Int?, estimate: Int?, previous: PerMinuteAllowance?,
                        fingerprint: String) -> PerMinuteAllowance {
        let prior = previous?.fingerprint == fingerprint ? previous?.calibration : nil
        var calibration = prior
        if let estimate, estimate > 0 {
            if let requested, requested > 0 {
                calibration = clamp(Double(requested) / Double(estimate))
            } else if estimate <= limit {
                let floor = clamp(Double(limit + 1) / Double(estimate))
                calibration = max(prior ?? floor, floor)
            }
        }
        return PerMinuteAllowance(limit: limit, calibration: calibration, fingerprint: fingerprint)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, calibrationRange.lowerBound), calibrationRange.upperBound)
    }

    // MARK: - Fingerprint

    /// What an allowance is valid for: the provider, the model id and the endpoint. Nothing of the
    /// key — a key edit is caught at the edit itself (`modelsToForget(old:new:)`).
    static func fingerprint(provider: LLMProvider, model: String, baseURL: String) -> String {
        let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [provider.rawValue, model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                endpoint].joined(separator: "|")
    }

    static func fingerprint(for model: ModelConfig) -> String {
        fingerprint(provider: model.llmProvider, model: model.model, baseURL: model.baseURL)
    }

    /// The saved models whose learned allowance a write of the saved list makes stale (decision 3):
    /// one that is gone, and one whose key, provider, model id or endpoint changed. The keys are
    /// compared in memory, trimmed, at the moment of the write; nothing derived from them is kept.
    static func modelsToForget(old: [ModelConfig], new: [ModelConfig]) -> Set<String> {
        let now = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func key(_ model: ModelConfig) -> String { model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
        return Set(old.compactMap { before in
            guard let after = now[before.id] else { return before.id }
            let same = key(before) == key(after) && fingerprint(for: before) == fingerprint(for: after)
            return same ? nil : before.id
        })
    }
}

/// The learned allowances, by saved model id, kept across launches in the app's preferences.
///
/// Holds numbers and fingerprints only: no content, nothing about the wearer, nothing of a key. A
/// stale entry (its model's provider, endpoint or model id changed since) is dropped the first time
/// it is read, and one whose key changed is dropped when the saved models are written.
///
/// Read through to the preferences on every call — the record is a handful of numbers per saved
/// model — so the shared instance and `Config.setSavedModels`, which runs on any thread, never
/// disagree about what is kept.
final class PerMinuteAllowanceStore: @unchecked Sendable {

    static let shared = PerMinuteAllowanceStore()

    static let defaultsKey = "llm.perMinuteAllowances"

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = PerMinuteAllowanceStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    /// The allowance learned for `model` as it is configured now, or nil.
    func allowance(for model: ModelConfig) -> PerMinuteAllowance? {
        allowance(modelID: model.id, fingerprint: PerMinuteAllowance.fingerprint(for: model))
    }

    func allowance(modelID: String, fingerprint: String) -> PerMinuteAllowance? {
        lock.lock(); defer { lock.unlock() }
        var byModel = load()
        guard let stored = byModel[modelID] else { return nil }
        guard stored.fingerprint == fingerprint else {
            // Decision 3: a changed provider or model id clears what was learned for the old one.
            byModel[modelID] = nil
            save(byModel)
            return nil
        }
        return stored
    }

    /// Record what a refusal said about `model`'s allowance, and return what is now known.
    @discardableResult
    func record(limit: Int, requested: Int?, estimate: Int?, for model: ModelConfig) -> PerMinuteAllowance {
        record(limit: limit, requested: requested, estimate: estimate, modelID: model.id,
               fingerprint: PerMinuteAllowance.fingerprint(for: model))
    }

    @discardableResult
    func record(limit: Int, requested: Int?, estimate: Int?, modelID: String,
                fingerprint: String) -> PerMinuteAllowance {
        lock.lock(); defer { lock.unlock() }
        var byModel = load()
        let learned = PerMinuteAllowance.learned(limit: limit, requested: requested, estimate: estimate,
                                                 previous: byModel[modelID], fingerprint: fingerprint)
        byModel[modelID] = learned
        save(byModel)
        return learned
    }

    /// Drop what was learned for these saved models. Returns how many entries there were.
    @discardableResult
    func forget(_ modelIDs: Set<String>) -> Int {
        guard !modelIDs.isEmpty else { return 0 }
        lock.lock(); defer { lock.unlock() }
        var byModel = load()
        let before = byModel.count
        for id in modelIDs { byModel[id] = nil }
        guard byModel.count != before else { return 0 }
        save(byModel)
        return before - byModel.count
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }

    private func load() -> [String: PerMinuteAllowance] {
        defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([String: PerMinuteAllowance].self, from: $0) } ?? [:]
    }

    private func save(_ byModel: [String: PerMinuteAllowance]) {
        guard !byModel.isEmpty else { return defaults.removeObject(forKey: key) }
        if let data = try? JSONEncoder().encode(byModel) { defaults.set(data, forKey: key) }
    }
}
