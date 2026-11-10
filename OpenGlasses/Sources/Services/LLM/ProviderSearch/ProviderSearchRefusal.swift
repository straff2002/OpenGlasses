import Foundation
import CryptoKit

/// Whether a refused request was refused *because of* the provider's search tool (Plan KZ §4).
///
/// A refusal that names search is retried once with our own tool, and remembered, so the next
/// turn goes straight to our tool and the switch's line can say why. A refusal that does not
/// name search is the provider's ordinary error and is left to the paths that already handle it.
/// Pure: status and message in, a class out.
enum ProviderSearchRefusal {

    enum Kind: String, Codable, Equatable, CaseIterable {
        /// The account or organisation has web search switched off (Anthropic's 400 when an
        /// administrator turned it off).
        case searchDisabled
        /// The workspace locks which search engines may run (OpenRouter's 403).
        case workspaceLocked
        /// The model or endpoint does not take the search tool, or refused one of its fields.
        case toolUnsupported

        /// Whether the refusal is about this model only, not the whole account.
        var isPerModel: Bool { self == .toolUnsupported }
    }

    /// The class of a whole-request refusal that names search, or nil.
    static func classify(status: Int, message: String?) -> Kind? {
        guard (400...499).contains(status), ![401, 429].contains(status) else { return nil }
        let text = (message ?? "").lowercased()
        let namesSearch = ["web search", "web_search", "websearch", "browser_search", "google_search",
                           "openrouter:web_search", "search engine", "server tool", "server_tool",
                           "user_location", "hosted tool"]
            .contains(where: text.contains)
        guard namesSearch else { return nil }
        if status == 403 {
            return text.contains("engine") || text.contains("workspace") || text.contains("organization")
                || text.contains("organisation") ? .workspaceLocked : .searchDisabled
        }
        let turnedOff = ["not enabled", "disabled", "turned off", "not allowed", "has been disabled",
                         "is off"]
        if turnedOff.contains(where: text.contains),
           text.contains("organization") || text.contains("organisation") || text.contains("admin")
            || text.contains("workspace") || text.contains("account") {
            return .searchDisabled
        }
        return .toolUnsupported
    }

    /// The in-turn search error codes that mean the search service itself is failing, and so
    /// start the 10-minute cool-off (Decision 7). A bad query or a used-up allowance is the
    /// model's, not an outage, and does not.
    static let outageCodes: Set<String> = ["unavailable", "too_many_requests", "overloaded",
                                           "internal_error", "failed"]

    static func startsCoolOff(_ errors: [String]) -> Bool {
        errors.contains { outageCodes.contains($0) }
    }
}

/// What this run and this account have taught the app about the provider's search (§4).
///
/// Refusals are kept per provider and per credential, by a fingerprint of the credential (never
/// the credential), so they hold until the wearer changes the key; a per-model refusal names
/// the model too. The 10-minute cool-off after a failed search lives in memory only. Stored as a
/// plain dictionary of tokens in preferences: no conversation content, no third party.
final class ProviderSearchMemory {

    enum Reading: Equatable {
        case clear
        case refused(ProviderSearchRefusal.Kind)
        case coolingOff
    }

    static let shared = ProviderSearchMemory()
    static let coolOff: TimeInterval = 10 * 60
    static let defaultsKey = "providerSearchRefusals"

    private let defaults: UserDefaults
    private let now: () -> Date
    private var coolingUntil: [String: Date] = [:]

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    /// `provider|fingerprint`, where the fingerprint is the first 12 hex digits of the
    /// credential's SHA-256: enough to tell keys apart, nothing that leads back to one.
    static func accountKey(provider: LLMProvider, credential: String) -> String {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        let hex = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(provider.rawValue)|\(hex)"
    }

    private var stored: [String: String] {
        get { defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Self.defaultsKey) }
    }

    func reading(provider: LLMProvider, credential: String, model: String) -> Reading {
        if let kind = refusal(provider: provider, credential: credential, model: model) {
            return .refused(kind)
        }
        let key = Self.accountKey(provider: provider, credential: credential)
        if let until = coolingUntil[key], until > now() { return .coolingOff }
        return .clear
    }

    func refusal(provider: LLMProvider, credential: String, model: String) -> ProviderSearchRefusal.Kind? {
        let key = Self.accountKey(provider: provider, credential: credential)
        let entries = stored
        if let raw = entries[key], let kind = ProviderSearchRefusal.Kind(rawValue: raw) { return kind }
        if let raw = entries[key + "|" + model.lowercased()], let kind = ProviderSearchRefusal.Kind(rawValue: raw) {
            return kind
        }
        return nil
    }

    /// The most recent refusal remembered for a provider under any model of this credential.
    func latestRefusal(provider: LLMProvider, credential: String) -> ProviderSearchRefusal.Kind? {
        let key = Self.accountKey(provider: provider, credential: credential)
        return stored.first { $0.key == key || $0.key.hasPrefix(key + "|") }
            .flatMap { ProviderSearchRefusal.Kind(rawValue: $0.value) }
    }

    func noteRefusal(_ kind: ProviderSearchRefusal.Kind, provider: LLMProvider, credential: String,
                     model: String) {
        let key = Self.accountKey(provider: provider, credential: credential)
        var entries = stored
        // A refusal for another key of this provider belongs to a key that is no longer used.
        for existing in entries.keys where existing.hasPrefix(provider.rawValue + "|")
            && !(existing == key || existing.hasPrefix(key + "|")) {
            entries.removeValue(forKey: existing)
        }
        entries[kind.isPerModel ? key + "|" + model.lowercased() : key] = kind.rawValue
        stored = entries
    }

    /// A search failed inside a 200: our tool for the next 10 minutes.
    func noteInTurnFailure(provider: LLMProvider, credential: String) {
        coolingUntil[Self.accountKey(provider: provider, credential: credential)] = now().addingTimeInterval(Self.coolOff)
    }

    func forgetAll() {
        defaults.removeObject(forKey: Self.defaultsKey)
        coolingUntil.removeAll()
    }
}
