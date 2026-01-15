import Foundation

/// Service for communicating with Claude API
class ClaudeAPIService: ObservableObject {
    private let apiKey: String
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let model = "claude-sonnet-4-20250514"
    
    @Published var isProcessing: Bool = false
    
    init() {
        self.apiKey = Config.anthropicAPIKey
    }
    
    func sendMessage(_ text: String) async throws -> String {
        isProcessing = true
        defer { isProcessing = false }
        
        guard !apiKey.isEmpty else {
            throw ClaudeError.missingAPIKey
        }
        
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": "You are a helpful voice assistant. Keep responses concise.",
            "messages": [["role": "user", "content": text]]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ClaudeError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]],
              let responseText = content.first?["text"] as? String else {
            throw ClaudeError.invalidResponse
        }
        
        return responseText
    }
}

enum ClaudeError: LocalizedError {
    case missingAPIKey, invalidResponse, apiError(statusCode: Int)
    
    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "API key not configured"
        case .invalidResponse: return "Invalid response"
        case .apiError(let code): return "API error: (code)"
        }
    }
}
