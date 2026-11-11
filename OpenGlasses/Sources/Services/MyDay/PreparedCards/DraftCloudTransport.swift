import Foundation

// Plan KT §4.2 — the cloud half of `DraftModelCall`: one request, carrying the instructions and
// the prompt and nothing else, to the wearer's own model with their own key. Not the conversation
// path: no history, no tools, no memory, no usage or turn recording, no logging of either text.
// Cloud AI Sharing's existing approval for the host is still required (`consentedData`), as is
// Medical Compliance's egress guard, on top of the drafts' own consent and HIPAA gate.

enum DraftCloudTransportError: Error, Equatable {
    case unsupported
    case invalidEndpoint
    case missingKey
    case httpStatus(Int)
    case unreadableReply
}

enum DraftCloudTransport {
    /// A draft answer has a few seconds to arrive before the card keeps its template.
    static let requestTimeout: TimeInterval = 20

    /// The request for `config`. Pure, so the body a provider is sent is a value test.
    static func urlRequest(for config: ModelConfig, instructions: String, prompt: String,
                           maxOutputTokens: Int) throws -> URLRequest {
        guard let target = DraftCloudTarget(config: config), target.isSupported else {
            throw DraftCloudTransportError.unsupported
        }
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var request: URLRequest
        var body: [String: Any]
        switch config.llmProvider {
        case .anthropic:
            guard !key.isEmpty else { throw DraftCloudTransportError.missingKey }
            guard let url = URL(string: LLMProvider.anthropic.defaultBaseURL) else {
                throw DraftCloudTransportError.invalidEndpoint
            }
            request = URLRequest(url: url)
            AnthropicAuth.apply(credential: key, to: &request)
            body = [
                "model": config.model,
                "max_tokens": maxOutputTokens,
                "system": instructions,
                "messages": [["role": "user", "content": prompt]],
            ]
        case .gemini:
            guard !key.isEmpty else { throw DraftCloudTransportError.missingKey }
            var components = URLComponents(
                string: "https://generativelanguage.googleapis.com/v1beta/models/\(config.model):generateContent")
            components?.queryItems = [URLQueryItem(name: "key", value: key)]
            guard let url = components?.url else { throw DraftCloudTransportError.invalidEndpoint }
            request = URLRequest(url: url)
            body = [
                "systemInstruction": ["parts": [["text": instructions]]],
                "contents": [["role": "user", "parts": [["text": prompt]]]],
                "generationConfig": ["maxOutputTokens": maxOutputTokens],
            ]
        default:
            guard let url = URL(string: chatCompletionsURL(config)) else {
                throw DraftCloudTransportError.invalidEndpoint
            }
            request = URLRequest(url: url)
            let authorization: String?
            do {
                authorization = try LLMService.openAICompatibleAuthorization(provider: config.llmProvider, apiKey: key)
            } catch {
                throw DraftCloudTransportError.missingKey
            }
            if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
            body = [
                "model": config.model,
                "max_tokens": maxOutputTokens,
                "messages": [
                    ["role": "system", "content": instructions],
                    ["role": "user", "content": prompt],
                ],
            ]
            LLMService.applyGroqOneShotReasoning(to: &body, config: config)
            LLMService.applyOpenAITokenLimitShape(to: &body, provider: config.llmProvider, baseURL: url.absoluteString)
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// The saved base URL, ending in `/chat/completions`.
    static func chatCompletionsURL(_ config: ModelConfig) -> String {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = config.llmProvider.defaultBaseURL }
        if base.hasSuffix("/chat/completions") { return base }
        return base.hasSuffix("/") ? base + "chat/completions" : base + "/chat/completions"
    }

    /// The reply's text, by provider.
    static func text(from data: Data, provider: LLMProvider) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DraftCloudTransportError.unreadableReply
        }
        switch provider {
        case .anthropic:
            let blocks = json["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }
                .joined()
            guard !text.isEmpty else { throw DraftCloudTransportError.unreadableReply }
            return text
        case .gemini:
            let candidates = json["candidates"] as? [[String: Any]] ?? []
            let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw DraftCloudTransportError.unreadableReply }
            return text
        default:
            let choices = json["choices"] as? [[String: Any]] ?? []
            guard let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String, !content.isEmpty else {
                throw DraftCloudTransportError.unreadableReply
            }
            return content
        }
    }

    /// One call. Refused under Medical Compliance's Local Only by the egress guard, and without
    /// Cloud AI Sharing's approval for the host.
    @MainActor
    static func send(_ config: ModelConfig, instructions: String, prompt: String,
                     maxOutputTokens: Int) async throws -> String {
        try MedicalEgressGuard.check(.llmCompletion)
        let request = try urlRequest(for: config, instructions: instructions, prompt: prompt,
                                     maxOutputTokens: maxOutputTokens)
        let (data, response) = try await URLSession.shared.consentedData(for: request, scope: .conversation)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw DraftCloudTransportError.httpStatus(status) }
        return try text(from: data, provider: config.llmProvider)
    }
}
