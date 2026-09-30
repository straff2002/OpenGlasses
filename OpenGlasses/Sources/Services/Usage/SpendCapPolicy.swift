import Foundation

/// Plan GB P5 — daily and monthly spend caps for priced API usage.
///
/// The field tester's priorities on cost were usage tracking, spending caps and reliable answers.
/// Decided 2026-09-30: warn at 80% of a cap; at 100% **ask** — a spoken or tapped confirmation —
/// before going on. Falling back to a cheaper saved model is an opt-in setting, never the default,
/// because an unannounced model change undermines reliable answers. A model the app cannot price
/// reports the cap as not enforceable rather than pretending to be under it.
///
/// Pure: spend totals, caps, pricing and the clock in; a decision out. `SpendCapGate` applies it.
enum SpendCapPolicy {

    struct Caps: Equatable {
        /// USD; 0 means no cap.
        var dailyUSD: Double
        var monthlyUSD: Double
        var fallBackToCheaperModel: Bool

        var isEmpty: Bool { dailyUSD <= 0 && monthlyUSD <= 0 }

        static let off = Caps(dailyUSD: 0, monthlyUSD: 0, fallBackToCheaperModel: false)
    }

    /// Whether the model serving the turn costs money the app can count.
    enum Pricing: Equatable {
        case priced
        /// Billed, but the app has no rate for it: tokens are recorded, dollars are not.
        case unpriced
        /// Nothing per-token to count: on-device models, the ChatGPT subscription.
        case free
    }

    enum Window: String, Equatable {
        case day, month

        /// Identifies one calendar day or month, so a confirmation covers the rest of it only.
        func key(now: Date, calendar: Calendar = .current) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: now)
            let y = parts.year ?? 0, m = parts.month ?? 0, d = parts.day ?? 0
            switch self {
            case .day: return String(format: "day-%04d-%02d-%02d", y, m, d)
            case .month: return String(format: "month-%04d-%02d", y, m)
            }
        }

        /// The start of the window containing `now`.
        func start(of now: Date, calendar: Calendar = .current) -> Date {
            switch self {
            case .day: return calendar.startOfDay(for: now)
            case .month: return calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
            }
        }
    }

    enum Decision: Equatable {
        case ok
        /// At or past `warnFraction` of a cap, under 100%.
        case warn(Window, fraction: Double)
        /// At or past a cap: ask before this turn goes out.
        case confirmToContinue(Window)
        /// At or past a cap with the opt-in fallback on: use a cheaper saved model.
        case fallBackToCheaperModel(Window)
        /// A cap is set but this model's spend can't be counted.
        case notEnforceable
    }

    static let warnFraction = 0.8

    /// - Parameter overrideKey: the window key the wearer already agreed to go past
    ///   (`Window.key`), so one confirmation covers the rest of that day or month.
    static func decide(spentToday: Double, spentMonth: Double, caps: Caps, pricing: Pricing,
                       overrideKey: String?, now: Date, calendar: Calendar = .current) -> Decision {
        guard !caps.isEmpty else { return .ok }
        switch pricing {
        case .free: return .ok
        case .unpriced: return .notEnforceable
        case .priced: break
        }
        // The month first: a monthly cap reached outranks today's.
        let checks: [(Window, Double, Double)] = [(.month, spentMonth, caps.monthlyUSD),
                                                   (.day, spentToday, caps.dailyUSD)]
        for (window, spent, cap) in checks where cap > 0 && spent >= cap {
            if overrideKey == window.key(now: now, calendar: calendar) { continue }
            return caps.fallBackToCheaperModel ? .fallBackToCheaperModel(window) : .confirmToContinue(window)
        }
        let fractions = checks.compactMap { window, spent, cap -> (Window, Double)? in
            guard cap > 0 else { return nil }
            let fraction = spent / cap
            // A window the wearer already agreed to exceed doesn't keep warning.
            if fraction >= 1 { return nil }
            return fraction >= warnFraction ? (window, fraction) : nil
        }
        if let highest = fractions.max(by: { $0.1 < $1.1 }) {
            return .warn(highest.0, fraction: highest.1)
        }
        return .ok
    }

    /// The saved model to fall back to: the cheapest *priced* model strictly cheaper than the
    /// current one (by input + output list rate). Nil when there is none — the caller then asks.
    static func cheaperModel(than current: ModelConfig, among saved: [ModelConfig]) -> ModelConfig? {
        func cost(_ config: ModelConfig) -> Double? {
            guard config.llmProvider != .chatgpt, config.llmProvider != .local,
                  config.llmProvider != .appleOnDevice,
                  let rate = ModelPricing.rate(for: config.model) else { return nil }
            return rate.inputPer1M + rate.outputPer1M
        }
        guard let currentCost = cost(current) else { return nil }
        return saved
            .filter { $0.id != current.id }
            .compactMap { config in cost(config).map { (config, $0) } }
            .filter { $0.1 < currentCost }
            .min { $0.1 < $1.1 }?.0
    }

    // MARK: - Spoken copy

    static func windowName(_ window: Window) -> String {
        window == .day ? "today's" : "this month's"
    }

    static func warningLine(_ window: Window, fraction: Double) -> String {
        "You've used \(Int((fraction * 100).rounded(.down)))% of \(windowName(window)) AI spending limit."
    }

    static func confirmationPrompt(_ window: Window) -> String {
        "You've reached \(windowName(window)) AI spending limit. Say \"continue\" to go past it, or change the limit in Insights."
    }

    static func fallbackLine(_ window: Window, modelName: String) -> String {
        "You've reached \(windowName(window)) AI spending limit, so I'm using \(modelName) instead."
    }
}

/// Recognises the wearer's go-ahead to spend past a cap. Deterministic and deliberately narrow: a
/// question or a new request is never read as consent to spend.
enum SpendCapConfirmation {
    private static let phrases: Set<String> = [
        "continue", "continue anyway", "yes continue", "yes continue anyway", "go ahead",
        "yes go ahead", "keep going", "carry on", "ok continue", "okay continue",
        "yes please continue", "go past it", "go over it",
    ]

    static func isConfirmation(_ utterance: String) -> Bool {
        let cleaned = utterance.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.whitespaces).inverted).joined()
            .split(separator: " ").joined(separator: " ")
        return phrases.contains(cleaned)
    }
}

/// The conversational half of the spend cap (Plan GB P5): what the turn does with a
/// `SpendCapPolicy.Decision`, given what was said and what was already asked. Pure state — the
/// service holds one and applies its outcome; nothing here reads a clock or a store.
struct SpendCapGate: Equatable {

    enum Outcome: Equatable {
        case proceed
        /// Go ahead, and say this line before the answer (an 80% warning, an unpriced model).
        case proceedWithNotice(String)
        /// Answer with this line instead of calling the model (the cap prompt).
        case answer(String)
        /// The wearer said to go past the cap: record the override for `window`, then answer.
        case confirmed(SpendCapPolicy.Window, reply: String)
        /// Use this cheaper saved model for the turn and say so first (opt-in fallback).
        case useCheaperModel(ModelConfig, notice: String)
    }

    /// A cap prompt is outstanding: the next "continue" is consent.
    private(set) var awaitingConfirmation = false
    /// Notices already given, by window key, so each is said once per window.
    private(set) var noticed: Set<String> = []

    static let confirmedReply = "Okay, going past the limit for now. Go ahead."
    static let unpricedNotice = "Spending limits can't be tracked for this model because it has no price set."

    mutating func evaluate(_ decision: SpendCapPolicy.Decision, utterance: String, now: Date,
                           calendar: Calendar = .current,
                           cheaperModel: () -> ModelConfig? = { nil }) -> Outcome {
        switch decision {
        case .ok:
            awaitingConfirmation = false
            return .proceed
        case .warn(let window, let fraction):
            awaitingConfirmation = false
            let key = "warn-" + window.key(now: now, calendar: calendar)
            guard noticed.insert(key).inserted else { return .proceed }
            return .proceedWithNotice(SpendCapPolicy.warningLine(window, fraction: fraction))
        case .notEnforceable:
            awaitingConfirmation = false
            let key = "unpriced-" + SpendCapPolicy.Window.day.key(now: now, calendar: calendar)
            guard noticed.insert(key).inserted else { return .proceed }
            return .proceedWithNotice(Self.unpricedNotice)
        case .fallBackToCheaperModel(let window):
            if let cheaper = cheaperModel() {
                awaitingConfirmation = false
                return .useCheaperModel(cheaper, notice: SpendCapPolicy.fallbackLine(window, modelName: cheaper.name))
            }
            return ask(window, utterance: utterance)
        case .confirmToContinue(let window):
            return ask(window, utterance: utterance)
        }
    }

    private mutating func ask(_ window: SpendCapPolicy.Window, utterance: String) -> Outcome {
        if awaitingConfirmation, SpendCapConfirmation.isConfirmation(utterance) {
            awaitingConfirmation = false
            return .confirmed(window, reply: Self.confirmedReply)
        }
        awaitingConfirmation = true
        return .answer(SpendCapPolicy.confirmationPrompt(window))
    }
}
