import Foundation

/// Fetches available models from an LLM provider's API to validate keys and let users pick models.
enum ModelFetcher {

    struct RemoteModel: Identifiable, Hashable {
        let id: String      // model ID sent to the API
        let name: String    // display-friendly label
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

    /// Fetch models for a provider. Returns an empty array on failure.
    static func fetchModels(provider: LLMProvider, apiKey: String, baseURL: String) async -> [RemoteModel] {
        // Local OpenAI-compatible servers (Ollama, llama.cpp, LM Studio, vLLM…) usually
        // need no API key, so let the custom provider list models without one.
        guard !apiKey.isEmpty || provider == .custom || provider == .anthropic || provider == .chatgpt else { return [] }

        switch provider {
        case .chatgpt:
            // Subscription auth serves a fixed codex catalog — no key-based listing endpoint.
            return ChatGPTOAuth.modelCatalog.map { RemoteModel(id: $0, name: $0) }
        case .anthropic:
            return await fetchAnthropic(apiKey: apiKey)
        case .gemini:
            return await fetchGemini(apiKey: apiKey)
        case .qwen:
            return await fetchQwen(apiKey: apiKey, baseURL: baseURL)
        case .minimax:
            return await fetchMiniMax(apiKey: apiKey, baseURL: baseURL)
        case .openai, .groq, .zai, .xai, .openrouter, .custom:
            return await fetchOpenAICompatible(apiKey: apiKey, baseURL: baseURL)
        case .geminiVertex:
            return []  // OAuth-only; no key-based listing endpoint (type the model ID)
        case .local, .appleOnDevice:
            return []  // Local/Apple models are managed separately
        }
    }

    // MARK: - OpenAI-compatible (/v1/models)

    /// Derive the `/models` listing endpoint from a chat-completions base URL.
    /// Pure (no I/O) so it's unit-testable — the network call stays in the caller.
    /// - `…/v1/chat/completions` → `…/v1/models`
    /// - `…/v1`                  → `…/v1/models`
    /// - bare host (any trailing slashes trimmed) → `…/models`
    static func modelsEndpoint(from baseURL: String) -> String {
        if let range = baseURL.range(of: "/v1/", options: .backwards) {
            return String(baseURL[baseURL.startIndex..<range.upperBound]) + "models"
        } else if baseURL.hasSuffix("/v1") {
            return baseURL + "/models"
        } else {
            let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return trimmed + "/models"
        }
    }

    private static func fetchOpenAICompatible(apiKey: String, baseURL: String) async -> [RemoteModel] {
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

            return models.compactMap { dict -> RemoteModel? in
                guard let id = dict["id"] as? String else { return nil }
                return RemoteModel(id: id, name: id)
            }
            .sorted { $0.id < $1.id }
        } catch {
            return []
        }
    }

    // MARK: - Qwen (Coding Plan)

    private static func fetchQwen(apiKey: String, baseURL: String) async -> [RemoteModel] {
        // First try the standard OpenAI-compatible /models endpoint
        let openAIResult = await fetchOpenAICompatible(apiKey: apiKey, baseURL: baseURL)
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
            "model": "qwen3.5-plus",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return [] }

            // Key works — return known Qwen Coding Plan models
            return [
                RemoteModel(id: "qwen3.5-plus", name: "Qwen 3.5 Plus (vision)"),
                RemoteModel(id: "qwen3.5-max", name: "Qwen 3.5 Max (vision)"),
                RemoteModel(id: "qwen-plus", name: "Qwen Plus (vision)"),
                RemoteModel(id: "qwen-max", name: "Qwen Max (vision)"),
                RemoteModel(id: "qwen-turbo", name: "Qwen Turbo"),
                RemoteModel(id: "qwen-long", name: "Qwen Long"),
            ]
        } catch {
            return []
        }
    }

    // MARK: - MiniMax

    private static func fetchMiniMax(apiKey: String, baseURL: String) async -> [RemoteModel] {
        // First try the standard OpenAI-compatible /models endpoint
        let openAIResult = await fetchOpenAICompatible(apiKey: apiKey, baseURL: baseURL)
        if !openAIResult.isEmpty { return openAIResult }

        // MiniMax Coding Plan may not expose /models — validate the key with a
        // minimal chat request and return known models if the key works.
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
        let knownModels = [
            ("MiniMax-M2.7", "MiniMax-M2.7 (reasoning)"),
            ("MiniMax-M1", "MiniMax-M1 (reasoning)"),
            ("MiniMax-Text-01", "MiniMax-Text-01"),
        ]

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
                    available.append(RemoteModel(id: modelId, name: displayName))
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

            return models.compactMap { dict -> RemoteModel? in
                // Gemini returns "models/gemini-2.0-flash" — strip prefix for the model ID
                guard let fullName = dict["name"] as? String else { return nil }
                let id = fullName.replacingOccurrences(of: "models/", with: "")
                let displayName = (dict["displayName"] as? String) ?? id
                // Filter to generateContent-capable models only
                let methods = dict["supportedGenerationMethods"] as? [String] ?? []
                guard methods.contains("generateContent") else { return nil }
                return RemoteModel(id: id, name: displayName)
            }
            .sorted { $0.id < $1.id }
        } catch {
            return []
        }
    }
}
