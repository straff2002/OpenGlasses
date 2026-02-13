import Foundation

/// Service for communicating with Claude API
@MainActor
class ClaudeAPIService: ObservableObject {
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let model = Config.claudeModel

    @Published var isProcessing: Bool = false

    /// Conversation history for multi-turn context
    private var conversationHistory: [[String: String]] = []
    private let maxHistoryTurns = 10  // Keep last 10 exchanges

    private static let systemPrompt = """
    You are Claude, a voice assistant running on Ray-Ban Meta smart glasses. Your responses will be spoken aloud via text-to-speech, so follow these rules:

    RESPONSE STYLE:
    - Keep responses SHORT — 1-3 sentences max. The user is listening, not reading.
    - Be conversational and natural, like talking to a friend.
    - Never use markdown, bullet points, numbered lists, or special formatting — it sounds terrible when read aloud.
    - Never say "I don't have access to..." — instead, give the best answer you can and suggest a quick alternative if needed.
    - Avoid filler phrases like "Great question!" or "That's interesting!"

    CONTEXT:
    - The user is wearing smart glasses and talking to you hands-free while going about their day.
    - Speech recognition may mishear words — interpret the user's intent generously.
    - If a question is ambiguous, give your best answer rather than asking for clarification.
    - You have conversational memory within this session, so you can reference previous exchanges.

    KNOWLEDGE:
    - For time/weather/location questions, give helpful general advice since you can't access real-time data. For example: "I can't check live weather, but you could ask Siri or check your weather app."
    - For factual questions, answer confidently from your training knowledge.
    - For opinions or recommendations, be direct and give a clear answer.
    """

    func sendMessage(_ text: String) async throws -> String {
        isProcessing = true
        defer { isProcessing = false }

        // Read API key fresh each time (in case user updated it in Settings)
        let apiKey = Config.anthropicAPIKey
        guard !apiKey.isEmpty else {
            throw ClaudeError.missingAPIKey
        }

        // Add user message to history
        conversationHistory.append(["role": "user", "content": text])

        // Trim history if too long
        if conversationHistory.count > maxHistoryTurns * 2 {
            conversationHistory = Array(conversationHistory.suffix(maxHistoryTurns * 2))
        }

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 300,  // Short responses for voice
            "system": Self.systemPrompt,
            "messages": conversationHistory.map { $0 as [String: Any] }
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Try to get error message from response
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMsg = (errorJson["error"] as? [String: Any])?["message"] as? String {
                print("❌ Claude API error \(statusCode): \(errorMsg)")
            }
            throw ClaudeError.apiError(statusCode: statusCode)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]],
              let responseText = content.first?["text"] as? String else {
            throw ClaudeError.invalidResponse
        }

        // Add assistant response to history
        conversationHistory.append(["role": "assistant", "content": responseText])

        return responseText
    }

    /// Clear conversation history (e.g. when starting fresh)
    func clearHistory() {
        conversationHistory.removeAll()
    }
}

enum ClaudeError: LocalizedError {
    case missingAPIKey, invalidResponse, apiError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "API key not configured"
        case .invalidResponse: return "Invalid response"
        case .apiError(let code): return "API error: \(code)"
        }
    }
}
