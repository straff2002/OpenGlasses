import Foundation

/// A model that could not be used because its sign-in or key is missing or was refused (Plan KL P0).
///
/// The fallback chain classifies a missing key and a refused one as `.terminalForCandidate`, the
/// same class as a model that declined or one the service would not serve. Narrated from the class
/// alone, a ChatGPT model the wearer never signed in to was announced as "unavailable" before every
/// answer (support report, build 615): the wearer waited for an outage that was a setting. This
/// reads the thrown error, for the saved model it was thrown for, into the one fact the line needs:
/// which service, which credential, and whether it is missing or was not accepted.
///
/// Pure: an error and a model's provider and key state go in. On-device models never have a gap —
/// Apple Intelligence and the MLX model throw `missingAPIKey` for reasons that are not credentials.
struct CredentialGap: Equatable, Sendable {

    enum Kind: Equatable, Sendable {
        /// Nothing to send: no key saved, or the account is not signed in.
        case missing
        /// Sent and refused: the service answered that the key or sign-in is not accepted.
        case refused
    }

    /// What the wearer has to fix: sign in to an account, or add (or replace) a key.
    enum Credential: Equatable, Sendable {
        case account
        case key
    }

    let provider: LLMProvider
    let kind: Kind
    let credential: Credential

    /// The service the wearer knows ("ChatGPT", "Groq"), not the saved model's name.
    var serviceName: String { provider.serviceName }

    // MARK: - Classification

    /// The gap behind `error` for a saved model, or nil when the error is not about its credential.
    static func classify(_ error: Error?, model: ModelConfig?) -> CredentialGap? {
        guard let model else { return nil }
        return classify(error, provider: model.llmProvider, hasKey: hasKey(model))
    }

    static func classify(_ error: Error?, provider: LLMProvider, hasKey: Bool) -> CredentialGap? {
        guard let error, let kind = kind(of: error),
              let credential = credential(for: provider, hasKey: hasKey) else { return nil }
        return CredentialGap(provider: provider, kind: kind, credential: credential)
    }

    /// Whether `error` says a credential is missing or was refused, whichever model threw it. A
    /// refusal that names the model's own contract, a model the service would not serve, and a
    /// model that declined are not credential problems: the same sign-in works for another model.
    static func kind(of error: Error) -> Kind? {
        // Only a failure that ends this candidate alone can be its credential.
        guard ModelFallbackChain.classify(error) == .terminalForCandidate else { return nil }
        if case LLMError.missingAPIKey = error { return .missing }
        if case LLMError.apiError(_, let status, _, let rejection) = error {
            if rejection?.reason == .credentialNotAccepted { return .refused }
            // A 401/403 the classifier could not name is the service refusing the caller. One it
            // could name for something else (`modelNotAvailable` arrives as a 403 too) is not.
            if status == 401 || status == 403, rejection == nil || rejection?.reason == .other {
                return .refused
            }
        }
        return nil
    }

    /// Which credential a provider's models are sent with, or nil for an on-device provider.
    /// Mirrors the request builders: an explicit key wins where a provider takes either.
    static func credential(for provider: LLMProvider, hasKey: Bool) -> Credential? {
        switch provider {
        case .local, .appleOnDevice:
            return nil
        case .chatgpt, .geminiVertex:
            return .account
        case .anthropic, .xai:
            return hasKey ? .key : .account
        case .openai, .gemini, .groq, .deepseek, .mistral, .zai, .qwen, .minimax, .openrouter, .custom:
            return .key
        }
    }

    /// A key that is only whitespace was never a key.
    static func hasKey(_ model: ModelConfig) -> Bool {
        !model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Wording

    /// The gap as the reason half of a sentence, starting lower-case: "you're not signed in to
    /// ChatGPT", "Groq didn't accept the key".
    var reason: String {
        switch (kind, credential) {
        case (.missing, .account): return "you're not signed in to \(serviceName)"
        case (.missing, .key): return "there's no working key for \(serviceName)"
        case (.refused, .account): return "\(serviceName) didn't accept the sign-in"
        case (.refused, .key): return "\(serviceName) didn't accept the key"
        }
    }

    /// The same reason opening a sentence.
    var sentenceOpening: String {
        guard let first = reason.first else { return reason }
        return first.uppercased() + reason.dropFirst()
    }
}

// MARK: - Said once per process

/// Whether a credential gap has already been said this process (Plan KL P0, decision 2).
///
/// A missing sign-in stays missing, so a notice limited to once per turn was heard before every
/// answer. This remembers, per service, the credential state the notice was said for; the same gap
/// is said again only after that state changes — signed in or out, a key added, removed or edited.
/// A key goes in only as its process-seeded `hashValue`, never as text. Held for the process, never
/// persisted.
struct CredentialNoticeLatch: Equatable {

    /// The credential state a notice was said for.
    struct Fingerprint: Hashable, Sendable {
        let accountConnected: Bool
        let hasKey: Bool
        /// Tells one key from the next, so a refused key replaced by another is said again.
        let keyDigest: Int

        init(accountConnected: Bool, hasKey: Bool, keyDigest: Int = 0) {
            self.accountConnected = accountConnected
            self.hasKey = hasKey
            self.keyDigest = keyDigest
        }

        /// The state of `provider`'s own account, given each account's connected flag.
        init(provider: LLMProvider, hasKey: Bool, keyDigest: Int = 0, claudeConnected: Bool,
             chatgptConnected: Bool, googleConnected: Bool, xaiConnected: Bool) {
            let connected: Bool
            switch provider {
            case .anthropic: connected = claudeConnected
            case .chatgpt: connected = chatgptConnected
            case .geminiVertex: connected = googleConnected
            case .xai: connected = xaiConnected
            default: connected = false
            }
            self.init(accountConnected: connected, hasKey: hasKey, keyDigest: keyDigest)
        }
    }

    private var said: [LLMProvider: Fingerprint] = [:]

    /// True the first time a service's gap is seen, false while its credential state is unchanged,
    /// and true again once it changes. Records the state either way.
    mutating func shouldNarrate(_ gap: CredentialGap, fingerprint: Fingerprint) -> Bool {
        if said[gap.provider] == fingerprint { return false }
        said[gap.provider] = fingerprint
        return true
    }
}

// MARK: - The status card's sign-in row

/// What the home status card offers while the assistant model has no usable credential (Plan KL P0):
/// "Sign in to ChatGPT" or "Add a key for Groq", opening the AI model settings.
struct CredentialSignInPrompt: Equatable {
    let provider: LLMProvider
    let credential: CredentialGap.Credential

    var title: String {
        switch credential {
        case .account: return String(localized: "Sign in to \(provider.serviceName)")
        case .key: return String(localized: "Add a key for \(provider.serviceName)")
        }
    }

    var accessibilityHint: String {
        String(localized: "Opens the AI model settings")
    }

    /// The prompt for the assistant model, or nil when it is ready. Readiness is the model list's
    /// own badge, so the card and the list never disagree: a custom server's optional key, and an
    /// on-device model, show nothing.
    static func resolve(model: ModelConfig?, claudeConnected: Bool, chatgptConnected: Bool,
                        googleConnected: Bool, xaiConnected: Bool) -> CredentialSignInPrompt? {
        guard let model else { return nil }
        let provider = model.llmProvider
        let hasKey = CredentialGap.hasKey(model)
        let badge = AIPersonalitySettingsScreen.modelAuthBadge(
            provider: provider, hasKey: hasKey,
            claudeConnected: claudeConnected, chatgptConnected: chatgptConnected,
            googleConnected: googleConnected, xaiConnected: xaiConnected)
        guard !badge.isReady,
              let credential = CredentialGap.credential(for: provider, hasKey: hasKey) else { return nil }
        return CredentialSignInPrompt(provider: provider, credential: credential)
    }
}

extension LLMProvider {
    /// The service's own short name, for a sentence about its sign-in or key ("ChatGPT", "Groq").
    /// Not `displayName`, which describes the choice in a picker ("ChatGPT (Subscription)").
    var serviceName: String {
        switch self {
        case .chatgpt: return "ChatGPT"
        case .anthropic: return "Claude"
        case .openai: return "OpenAI"
        case .gemini, .geminiVertex: return "Gemini"
        case .groq: return "Groq"
        case .deepseek: return "DeepSeek"
        case .mistral: return "Mistral"
        case .zai: return "Z.ai"
        case .qwen: return "Qwen"
        case .minimax: return "MiniMax"
        case .xai: return "xAI"
        case .openrouter: return "OpenRouter"
        case .custom: return "your custom server"
        case .local: return "the on-device model"
        case .appleOnDevice: return "Apple Intelligence"
        }
    }
}
