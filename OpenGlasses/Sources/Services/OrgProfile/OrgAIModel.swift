import Foundation

/// Plan CT 3a — the AI provider and model a profile names, checked.
///
/// Which provider and model to use is not a secret; the key for it is. So the profile carries this,
/// and the key is typed on the phone (or the provider signed in to) after the review. The phone
/// builds the `ModelConfig` itself: provider, model and address from here, key from the person.
struct OrgAIModel: Equatable, Sendable {
    let provider: LLMProvider
    let model: String
    /// The organisation's own address for a `custom` or `openrouter` model; nil means the
    /// provider's default. It is where the phone's prompts go, so the review sheet names its host.
    let baseURL: URL?
    let name: String?

    /// What the person has to do before the model works.
    enum Access: Equatable, Sendable {
        /// Enter the provider's API key.
        case key
        /// Sign in to the provider's account instead of entering a key.
        case signIn
        /// Nothing: an on-device model.
        case onDevice
    }

    var access: Access {
        switch provider {
        case .local, .appleOnDevice: return .onDevice
        case .chatgpt, .geminiVertex: return .signIn
        default: return provider.requiresAPIKey ? .key : .onDevice
        }
    }

    /// `Anthropic · claude-sonnet-4-5`, for the review sheet and the managed row.
    var summary: String { "\(provider.displayName) · \(model)" }

    /// The host prompts go to, when the organisation named its own address.
    var host: String? { baseURL?.host?.lowercased() }

    /// Check a profile's `aiModel`. Every way it can be wrong is a named drop, and the phone then
    /// behaves as if the profile named no model.
    static func resolve(_ spec: ConfigProfile.AIModel) -> Result<OrgAIModel, ProfileApplier.Drop.Reason> {
        guard let raw = spec.provider?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let model = spec.model?.trimmingCharacters(in: .whitespaces), !model.isEmpty else {
            return .failure(.unreadableValue)
        }
        guard let provider = LLMProvider(rawValue: raw) else {
            return .failure(.invalidValue("\u{201C}\(raw)\u{201D} is not an AI provider this version of the app knows"))
        }
        var address: URL?
        if let text = spec.baseURL?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            guard provider == .custom || provider == .openrouter else {
                return .failure(.invalidValue("only a custom or OpenRouter model may name its own address"))
            }
            guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.fragment == nil else {
                return .failure(.invalidValue("its address must be https, with no credentials"))
            }
            address = url
        } else if provider == .custom {
            return .failure(.invalidValue("a custom model needs its address"))
        }
        let name = spec.name?.trimmingCharacters(in: .whitespaces)
        return .success(OrgAIModel(provider: provider, model: model, baseURL: address,
                                   name: (name?.isEmpty ?? true) ? nil : name))
    }

    /// The format check onboarding's key page runs before anything else: a key that plainly
    /// belongs to another provider is refused with the reason. The model is fixed by the profile,
    /// so there is no model list to fetch.
    func keyProblem(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter the key." }
        switch provider {
        case .anthropic where !trimmed.hasPrefix("sk-ant-"): return "Anthropic keys start with sk-ant-"
        case .openai where !trimmed.hasPrefix("sk-"): return "OpenAI keys start with sk-"
        default: return nil
        }
    }

    /// The config the phone saves. The key comes from the person; nothing else here is theirs.
    func makeConfig(id: String, apiKey: String, organizationName: String) -> ModelConfig {
        ModelConfig(id: id,
                    name: name ?? "\(organizationName) — \(provider.displayName)",
                    provider: provider.rawValue,
                    apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: model,
                    baseURL: baseURL?.absoluteString ?? provider.defaultBaseURL)
    }
}

/// A drop reason is what `OrgAIModel.resolve` fails with, so it can sit in a `Result`.
extension ProfileApplier.Drop.Reason: Error {}
