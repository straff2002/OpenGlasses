import Foundation

/// Fetches available models from an LLM provider's API to validate keys and let users pick models.
enum ModelFetcher {

    struct RemoteModel: Identifiable, Hashable {
        let id: String      // model ID sent to the API
        let name: String    // display-friendly label
        let isDefault: Bool
        let inputModalities: Set<String>
        /// What the model is for (`ModelKindClassifier`). Pickers offer only `.chat` as the
        /// assistant and show the rest labelled, where they can't be chosen.
        let kind: ModelKind
        /// The day the provider shuts it down, where the list says (OpenAI's `shutdown_date`).
        /// A model past its day can't be chosen; one within `ModelShutdownCalendar.warningDays`
        /// says when it goes.
        let shutdown: ModelShutdown?

        init(id: String, name: String, isDefault: Bool = false, inputModalities: Set<String> = [],
             kind: ModelKind = .chat, shutdown: ModelShutdown? = nil) {
            self.id = id
            self.name = name
            self.isDefault = isDefault
            self.inputModalities = inputModalities
            self.kind = kind
            self.shutdown = shutdown
        }
    }

    /// Outcome of a lightweight "can I reach this endpoint?" probe (siri-and-local-server plan).
    enum ConnectionTestResult: Equatable {
        case ok(latencyMs: Int, modelCount: Int)
        case httpError(Int)
        case unreachable(String)
        case insecure          // http:// blocked by App Transport Security

        var isSuccess: Bool { if case .ok = self { return true }; return false }
    }

    /// Pure status → result mapping (no I/O) so it's unit-testable.
    static func classify(statusCode: Int, modelCount: Int, latencyMs: Int) -> ConnectionTestResult {
        (200...299).contains(statusCode) ? .ok(latencyMs: latencyMs, modelCount: modelCount)
                                         : .httpError(statusCode)
    }

    /// Probe the provider's `/models` endpoint: reachable? how fast? how many models? The result
    /// classification is the pure `classify(...)`; only the GET + error mapping live here.
    static func testConnection(provider: LLMProvider, apiKey: String, baseURL: String) async -> ConnectionTestResult {
        guard MedicalEgressGuard.allows(.providerModelCatalog) else {
            return .unreachable(MedicalEgressRefusal.userMessage)
        }
        guard let url = URL(string: modelsEndpoint(from: baseURL)) else { return .unreachable("Invalid URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 15

        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = response as? HTTPURLResponse else { return .unreachable("No HTTP response") }
            return classify(statusCode: http.statusCode, modelCount: modelCount(in: data), latencyMs: latencyMs)
        } catch let error as URLError {
            if error.code == .appTransportSecurityRequiresSecureConnection { return .insecure }
            return .unreachable(error.localizedDescription)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    /// Count models in a `/models` (OpenAI `data[]`) or `/api/tags` (Ollama `models[]`) response.
    private static func modelCount(in data: Data) -> Int {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        if let models = json["data"] as? [[String: Any]] { return models.count }
        if let models = json["models"] as? [[String: Any]] { return models.count }
        return 0
    }

    /// The model a picker starts on after a list loads: the list's own default, then the first of
    /// `preferred` the list offers, then the first with no shutdown day, then the first — chat
    /// models still answering only, so a list that leads with a speech, embedding or retired model
    /// never starts the wearer on it. Pure.
    static func initialChoice(in models: [RemoteModel], preferring preferred: [String],
                              today: Date = Date()) -> String? {
        let chat = models.filter { $0.kind.isChat && !($0.shutdown?.hasPassed(on: today) ?? false) }
        if let listDefault = chat.first(where: \.isDefault) { return listDefault.id }
        for id in preferred where chat.contains(where: { $0.id == id }) { return id }
        return (chat.first { $0.shutdown == nil } ?? chat.first)?.id
    }

    /// Fetch models for a provider. Returns an empty array on failure.
    static func fetchModels(provider: LLMProvider, apiKey: String, baseURL: String) async -> [RemoteModel] {
        uniqueByID(await fetchListing(provider: provider, apiKey: apiKey, baseURL: baseURL))
    }

    /// The first model under each id, in the order the provider listed them. The model pickers
    /// are SwiftUI lists keyed by id, and a list with two rows under one id can crash UIKit when it
    /// updates; a provider's `/models` is not promised to list each id once.
    static func uniqueByID(_ models: [RemoteModel]) -> [RemoteModel] {
        var seen = Set<String>()
        return models.filter { seen.insert($0.id).inserted }
    }

    private static func fetchListing(provider: LLMProvider, apiKey: String, baseURL: String) async -> [RemoteModel] {
        guard MedicalEgressGuard.allows(.providerModelCatalog) else { return [] }
        // An xAI model with no key lists what the signed-in account can use: its token carries
        // `api:access`, so the public `/v1/models` takes it as a bearer like a key.
        var apiKey = apiKey
        if provider == .xai, XAIAuth.usesAccountSignIn(apiKey: apiKey) {
            apiKey = await XAIAuth.resolveCredential(apiKey: apiKey, account: .shared)
        }
        // Local OpenAI-compatible servers (Ollama, llama.cpp, LM Studio, vLLM…) usually
        // need no API key, so let the custom provider list models without one.
        guard !apiKey.isEmpty || provider == .custom || provider == .anthropic || provider == .chatgpt else { return [] }

        switch provider {
        case .chatgpt:
            return await fetchChatGPT()
        case .anthropic:
            return await fetchAnthropic(apiKey: apiKey)
        case .gemini:
            return await fetchGemini(apiKey: apiKey)
        case .qwen:
            return await fetchQwen(apiKey: apiKey, baseURL: baseURL)
        case .minimax:
            return await fetchMiniMax(apiKey: apiKey, baseURL: baseURL)
        case .xai, .openai, .groq, .deepseek, .mistral, .zai, .openrouter, .custom:
            // Lists that also carry speech, image, embedding and other models are labelled by
            // `ModelKindClassifier`, not filtered: the pickers show them where they can't be chosen.
            return await fetchOpenAICompatible(provider: provider, apiKey: apiKey, baseURL: baseURL)
        case .geminiVertex:
            return []  // OAuth-only; no key-based listing endpoint (type the model ID)
        case .local, .appleOnDevice:
            return []  // Local/Apple models are managed separately
        }
    }

    // MARK: - ChatGPT subscription (account-scoped Codex catalog)

    /// Fetch the catalog enabled for the connected ChatGPT account. This deliberately uses the
    /// account-scoped Codex endpoint rather than the public API's `/v1/models`: subscription
    /// credentials and API keys belong to different products and are not interchangeable.
    private static func fetchChatGPT() async -> [RemoteModel] {
        if case .models(let models) = await fetchChatGPTCatalog() { return models }
        return []
    }

    /// Why a ChatGPT catalog fetch produced no models. The backend is a private surface that
    /// drifts (the 2026-08-31 catalog rotation returned empty lists to stale clients), so the
    /// failure modes must stay distinguishable or every drift reads as "check the sign-in".
    enum ChatGPTCatalogResult: Equatable {
        case models([RemoteModel])
        /// No stored account, or the token refresh failed — `signedIn` separates the two.
        case tokenUnavailable(signedIn: Bool)
        case httpError(Int)
        case networkError(String)
        /// The request succeeded but the account's catalog parsed to zero visible models.
        case emptyCatalog
    }

    static func fetchChatGPTCatalog() async -> ChatGPTCatalogResult {
        guard MedicalEgressGuard.allows(.providerModelCatalog) else {
            return .networkError(MedicalEgressRefusal.userMessage)
        }
        guard let token = await ChatGPTOAuthService.shared.validAccessToken() else {
            return .tokenUnavailable(signedIn: await ChatGPTOAuthService.shared.isConnected)
        }
        var request = URLRequest(url: URL(string: ChatGPTOAuth.backendModelsRequestURL)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let accountID = await ChatGPTOAuthService.shared.accountID
        ChatGPTAuth.apply(credential: token, accountID: accountID, to: &request)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                PrivacyLog.requestFailed(.modelCatalog, .http(status: code))
                return .httpError(code)
            }
            await ChatGPTContextCatalog.update(data: data, accountID: accountID)
            let models = parseChatGPTModels(data)
            return models.isEmpty ? .emptyCatalog : .models(models)
        } catch {
            PrivacyLog.requestFailed(.modelCatalog, SafeErrorSummary(error))
            return .networkError(error.localizedDescription)
        }
    }

    /// Parse both the current account endpoint (`models`) and App Server's documented
    /// `model/list` envelope (`data`). Field aliases keep the iOS client tolerant of the
    /// snake_case upstream payload and camelCase App Server projection.
    static func parseChatGPTModels(_ data: Data) -> [RemoteModel] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let rows = (json["models"] as? [[String: Any]]) ?? (json["data"] as? [[String: Any]]) ?? []
        var seen = Set<String>()

        return rows.compactMap { row in
            guard !boolean(row, keys: ["hidden", "is_hidden"]),
                  let id = string(row, keys: ["id", "model", "slug"]),
                  !id.isEmpty,
                  seen.insert(id).inserted else {
                return nil
            }
            let name = string(row, keys: ["displayName", "display_name", "name"]) ?? id
            let modalities = stringArray(
                row,
                keys: ["inputModalities", "input_modalities", "supported_input_modalities"]
            )
            return RemoteModel(
                id: id,
                name: name,
                isDefault: boolean(row, keys: ["isDefault", "is_default", "default"]),
                inputModalities: Set(modalities)
            )
        }
    }

    private static func string(_ dictionary: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { dictionary[$0] as? String }.first
    }

    private static func boolean(_ dictionary: [String: Any], keys: [String]) -> Bool {
        for key in keys {
            if let value = dictionary[key] as? Bool { return value }
            if let value = dictionary[key] as? NSNumber { return value.boolValue }
        }
        return false
    }

    private static func stringArray(_ dictionary: [String: Any], keys: [String]) -> [String] {
        keys.lazy.compactMap { dictionary[$0] as? [String] }.first ?? []
    }

    // MARK: - OpenAI-compatible (/v1/models)

    /// Derive the `/models` listing endpoint from a chat-completions base URL.
    /// Pure (no I/O) so it's unit-testable — the network call stays in the caller.
    /// - `…/v1/chat/completions` → `…/v1/models`
    /// - `…/v1`                  → `…/v1/models`
    /// - `…/chat/completions` with no `/v1` (DeepSeek, Z.ai) → `…/models`
    /// - bare host (any trailing slashes trimmed) → `…/models`
    static func modelsEndpoint(from baseURL: String) -> String {
        if let range = baseURL.range(of: "/v1/", options: .backwards) {
            return String(baseURL[baseURL.startIndex..<range.upperBound]) + "models"
        } else if baseURL.hasSuffix("/v1") {
            return baseURL + "/models"
        } else {
            let slashes = CharacterSet(charactersIn: "/")
            var trimmed = baseURL.trimmingCharacters(in: slashes)
            if trimmed.hasSuffix("/chat/completions") {
                trimmed = String(trimmed.dropLast("/chat/completions".count))
                    .trimmingCharacters(in: slashes)
            }
            return trimmed + "/models"
        }
    }

    private static func fetchOpenAICompatible(provider: LLMProvider, apiKey: String,
                                              baseURL: String) async -> [RemoteModel] {
        let modelsURL = modelsEndpoint(from: baseURL)
        guard let url = URL(string: modelsURL) else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Keyless local servers don't want an Authorization header at all.
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else { return [] }

            return openAICompatibleModels(models, provider: provider)
        } catch {
            return []
        }
    }

    /// The rows of an OpenAI-shaped `data[]` list, each labelled with its kind. Pure.
    static func openAICompatibleModels(_ rows: [[String: Any]], provider: LLMProvider) -> [RemoteModel] {
        rows.compactMap { dict -> RemoteModel? in
            guard let id = dict["id"] as? String else { return nil }
            let metadata = ModelListMetadata(row: dict)
            return RemoteModel(id: id, name: id,
                               kind: ModelKindClassifier.kind(provider: provider, id: id, metadata: metadata),
                               shutdown: metadata.shutdown)
        }
        .sorted { $0.id < $1.id }
    }

    // MARK: - Qwen (Coding Plan)

    /// The models the Qwen Coding Plan serves, in the order its help page lists them
    /// (recommended first, then "more models"), read from Alibaba Cloud Model Studio's Coding
    /// Plan page (last updated 2026-09-28) on 2026-10-10. The page says "Models not listed above
    /// are not supported", so the plan refuses anything else (the general `qwen-plus`,
    /// `qwen-max`, `qwen-turbo`, `qwen-long`, `qwen3.5-max`). Vision is exactly the four the
    /// page marks: a name ends in "(vision)" if and only if `ModelConfig.qwenCodingPlanVisionModels`
    /// holds its id.
    static let qwenCodingPlanModels: [RemoteModel] = [
        RemoteModel(id: "qwen3.7-plus", name: "Qwen 3.7 Plus (vision)"),
        RemoteModel(id: "qwen3.6-plus", name: "Qwen 3.6 Plus (vision)"),
        RemoteModel(id: "kimi-k2.5", name: "Kimi K2.5 (vision)"),
        RemoteModel(id: "glm-5", name: "GLM-5"),
        RemoteModel(id: "MiniMax-M2.5", name: "MiniMax M2.5"),
        RemoteModel(id: "qwen3.5-plus", name: "Qwen 3.5 Plus (vision)"),
        RemoteModel(id: "qwen3-max-2026-01-23", name: "Qwen3 Max (2026-01-23)"),
        RemoteModel(id: "qwen3-coder-next", name: "Qwen3 Coder Next"),
        RemoteModel(id: "qwen3-coder-plus", name: "Qwen3 Coder Plus"),
        RemoteModel(id: "glm-4.7", name: "GLM-4.7"),
    ]

    private static func fetchQwen(apiKey: String, baseURL: String) async -> [RemoteModel] {
        // First try the standard OpenAI-compatible /models endpoint
        let openAIResult = await fetchOpenAICompatible(provider: .qwen, apiKey: apiKey, baseURL: baseURL)
        if !openAIResult.isEmpty { return openAIResult }

        // Coding Plan API doesn't expose /models — validate the key with a
        // minimal chat request and return known models if the key works.
        let chatURL: String
        if baseURL.hasSuffix("/chat/completions") {
            chatURL = baseURL
        } else {
            chatURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"
        }

        guard let url = URL(string: chatURL) else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": LLMProvider.qwen.defaultModel,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return [] }

            // Key works — return the models the plan accepts
            return qwenCodingPlanModels
        } catch {
            return []
        }
    }

    // MARK: - MiniMax

    /// The models a key is tried against when MiniMax's documented `GET /v1/models` answers with
    /// nothing: its current chat models (models page, read 2026-10-30), then `MiniMax-M2.7`, which
    /// the list endpoint's example still shows, for plans that kept it.
    static let miniMaxProbeModels: [(String, String)] = [
        ("MiniMax-M3", "MiniMax-M3"),
        ("MiniMax-M3.1-Flash", "MiniMax-M3.1 Flash"),
        ("MiniMax-M2.7", "MiniMax-M2.7 (reasoning)"),
    ]

    private static func fetchMiniMax(apiKey: String, baseURL: String) async -> [RemoteModel] {
        // MiniMax documents an OpenAI-shaped `GET /v1/models` (API reference, read 2026-10-30).
        let openAIResult = await fetchOpenAICompatible(provider: .minimax, apiKey: apiKey, baseURL: baseURL)
        if !openAIResult.isEmpty { return openAIResult }

        // An endpoint that answers it with nothing (a custom base URL, a plan without it) —
        // validate the key with a minimal chat request and return known models if the key works.
        let chatURL: String
        if baseURL.contains("/chat/completions") || baseURL.contains("/chatcompletion") {
            chatURL = baseURL
        } else {
            chatURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"
        }

        guard let url = URL(string: chatURL) else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        // Test each known model to find which ones the plan supports
        let knownModels = miniMaxProbeModels

        var available: [RemoteModel] = []
        for (modelId, displayName) in knownModels {
            let body: [String: Any] = [
                "model": modelId,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "hi"]]
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }

                if (200...299).contains(http.statusCode) {
                    available.append(RemoteModel(id: modelId, name: displayName,
                                                 kind: ModelKindClassifier.kind(provider: .minimax, id: modelId)))
                } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let error = json["error"] as? [String: Any],
                          let msg = error["message"] as? String,
                          msg.contains("not support model") {
                    // Key is valid but model not on plan — skip but keep checking others
                    continue
                }
            } catch {
                continue
            }
        }

        return available
    }

    // MARK: - Anthropic

    private static func fetchAnthropic(apiKey: String) async -> [RemoteModel] {
        guard let url = URL(string: "https://api.anthropic.com/v1/models") else { return [] }
        let credential = await AnthropicAuth.resolveCredential(apiKey: apiKey)
        guard !credential.isEmpty else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        AnthropicAuth.apply(credential: credential, to: &request)
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else { return [] }

            return models.compactMap { dict -> RemoteModel? in
                guard let id = dict["id"] as? String else { return nil }
                let displayName = (dict["display_name"] as? String) ?? id
                return RemoteModel(id: id, name: displayName)
            }
            .sorted { $0.id < $1.id }
        } catch {
            return []
        }
    }

    // MARK: - Gemini

    private static func fetchGemini(apiKey: String) async -> [RemoteModel] {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return [] }

            return geminiModels(models)
        } catch {
            return []
        }
    }

    /// The rows of Gemini's `models` list, each labelled with its kind. Speech, live-audio,
    /// embedding, image and video models are kept and labelled (`ModelKindClassifier`); the
    /// pickers show them where they can't be chosen as the assistant. Pure.
    static func geminiModels(_ rows: [[String: Any]]) -> [RemoteModel] {
        rows.compactMap { dict -> RemoteModel? in
            // Gemini returns "models/gemini-2.0-flash" — strip prefix for the model ID
            guard let fullName = dict["name"] as? String else { return nil }
            let id = fullName.replacingOccurrences(of: "models/", with: "")
            let displayName = (dict["displayName"] as? String) ?? id
            return RemoteModel(id: id, name: displayName, kind: ModelKindClassifier.kind(
                provider: .gemini, id: id, metadata: ModelListMetadata(row: dict)))
        }
        .sorted { $0.id < $1.id }
    }

    /// Whether a Gemini id is a model a conversation can use. Kept for its callers and tests;
    /// the rule is `ModelKindClassifier`'s.
    static func isGeminiChatModel(_ id: String) -> Bool {
        ModelKindClassifier.kind(provider: .gemini, id: id).isChat
    }
}
