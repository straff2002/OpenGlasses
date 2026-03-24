import Foundation

/// Fetches available models from an LLM provider's API to validate keys and let users pick models.
enum ModelFetcher {

    struct RemoteModel: Identifiable, Hashable {
        let id: String      // model ID sent to the API
        let name: String    // display-friendly label
    }

    /// Fetch models for a provider. Returns an empty array on failure.
    static func fetchModels(provider: LLMProvider, apiKey: String, baseURL: String) async -> [RemoteModel] {
        guard !apiKey.isEmpty else { return [] }

        switch provider {
        case .anthropic:
            return await fetchAnthropic(apiKey: apiKey)
        case .gemini:
            return await fetchGemini(apiKey: apiKey)
        case .qwen:
            return await fetchQwen(apiKey: apiKey, baseURL: baseURL)
        case .openai, .groq, .zai, .minimax, .openrouter, .custom:
            return await fetchOpenAICompatible(apiKey: apiKey, baseURL: baseURL)
        case .local, .appleOnDevice:
            return []  // Local/Apple models are managed separately
        }
    }

    // MARK: - OpenAI-compatible (/v1/models)

    private static func fetchOpenAICompatible(apiKey: String, baseURL: String) async -> [RemoteModel] {
        // Derive models endpoint from chat completions URL
        // e.g. "https://api.openai.com/v1/chat/completions" → "https://api.openai.com/v1/models"
        let modelsURL: String
        if let range = baseURL.range(of: "/v1/", options: .backwards) {
            modelsURL = String(baseURL[baseURL.startIndex..<range.upperBound]) + "models"
        } else if baseURL.hasSuffix("/v1") {
            modelsURL = baseURL + "/models"
        } else {
            // Try appending /models to whatever base we have
            let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            modelsURL = trimmed + "/models"
        }

        guard let url = URL(string: modelsURL) else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

    // MARK: - Anthropic

    private static func fetchAnthropic(apiKey: String) async -> [RemoteModel] {
        guard let url = URL(string: "https://api.anthropic.com/v1/models") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
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
