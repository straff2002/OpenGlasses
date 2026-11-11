import Foundation

/// What a provider charges for the searches it runs itself (Plan KZ §7), beside the tokens.
///
/// Read from each provider's pricing page on 2026-11-10 (`readOn`). Prices move: re-read them
/// when a provider announces a change, and keep the date with the figures. An estimate, and the
/// switch's line says so.
enum SearchFeeTable {

    static let readOn = "2026-11-10"

    struct Entry: Equatable {
        /// US dollars per 1,000 searches, or nil where the provider publishes no figure.
        let usdPer1000: Double?
        /// Who bills it, for "billed by …".
        let billedBy: String
    }

    static func entry(for kind: ProviderSearchSpec.Kind, model: String = "") -> Entry {
        switch kind {
        case .anthropic: return Entry(usdPer1000: 10, billedBy: "Anthropic")
        case .openAIResponses: return Entry(usdPer1000: 10, billedBy: "OpenAI")
        case .xaiResponses: return Entry(usdPer1000: 5, billedBy: "xAI")
        case .openRouter:
            // The native engine passes the model's own provider's price through.
            let model = model.lowercased()
            let passed: Double? = model.hasPrefix("anthropic/") || model.hasPrefix("openai/") ? 10
                : model.hasPrefix("x-ai/") ? 5 : nil
            return Entry(usdPer1000: passed, billedBy: "OpenRouter")
        case .groq: return Entry(usdPer1000: nil, billedBy: "Groq")
        // Gemini 3 and later: 5,000 searches a month free, then this.
        case .gemini: return Entry(usdPer1000: 14, billedBy: "Google")
        }
    }

    /// The estimated fee for `searches` searches, or nil when unpriced.
    static func cost(kind: ProviderSearchSpec.Kind, model: String = "", searches: Int) -> Double? {
        guard searches > 0, let per = entry(for: kind, model: model).usdPer1000 else { return nil }
        return per * Double(searches) / 1000
    }

    /// "$10" or "$7.50": a whole number of dollars where it is one.
    static func formatted(_ usd: Double) -> String {
        usd == usd.rounded() ? "$\(Int(usd))" : String(format: "$%.2f", usd)
    }
}
