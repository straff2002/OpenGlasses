import Foundation

/// Lightweight LLM intent classifier for VAD filtering.
///
/// After speech-to-text finishes, the raw transcript is sent to a fast model
/// (gpt-4o-mini or equivalent) to determine if the user is actually talking
/// to the assistant or just having a bystander conversation, thinking aloud,
/// or saying filler words.
///
/// This prevents the assistant from responding to noise like:
///   - "um yeah so anyway" (filler)
///   - "hey did you see that game last night?" (talking to someone else)
///   - "okay let me think about that" (thinking aloud)
///
/// Only used in Direct Mode (wake word + transcription).
/// Realtime modes (Gemini Live, OpenAI Realtime) handle VAD server-side.
@MainActor
class IntentClassifier {
    /// Whether the classifier is enabled (requires an OpenAI-compatible model configured).
    var isEnabled: Bool {
        Config.intentClassifierEnabled && classifierConfig != nil
    }

    /// The model config used for classification.
    /// Prefers gpt-4o-mini, falls back to any fast OpenAI model, then any model.
    private var classifierConfig: ModelConfig? {
        let models = Config.savedModels

        // Prefer gpt-4o-mini specifically
        if let mini = models.first(where: {
            $0.llmProvider == .openai && $0.model.lowercased().contains("4o-mini") && !$0.apiKey.isEmpty
        }) {
            return mini
        }

        // Fall back to any OpenAI model with a key
        if let openai = models.first(where: {
            $0.llmProvider == .openai && !$0.apiKey.isEmpty
        }) {
            return openai
        }

        // Fall back to any configured model (Groq is fast too)
        if let groq = models.first(where: {
            $0.llmProvider == .groq && !$0.apiKey.isEmpty
        }) {
            return groq
        }

        return nil
    }

    enum IntentResult {
        case respond      // User is talking to the assistant
        case ignore       // Background noise / bystander / filler
        case uncertain    // Couldn't determine — default to respond
    }

    /// Classify whether the user's transcript is directed at the assistant.
    /// Returns quickly (typically <500ms with gpt-4o-mini).
    /// On any error, returns .uncertain (defaults to responding).
    func classify(transcript: String, recentContext: String? = nil) async -> IntentResult {
        guard isEnabled, let config = classifierConfig else {
            return .uncertain
        }

        // Skip classification for very short inputs (likely intentional)
        let wordCount = transcript.split(separator: " ").count
        if wordCount <= 3 {
            return .respond
        }

        let systemPrompt = """
        You are a voice intent classifier for a smart glasses assistant. \
        The user just spoke after saying a wake word. Your job is to decide if \
        they are talking TO the assistant or if this is background noise, \
        a bystander conversation, filler words, or thinking aloud.

        Respond with EXACTLY one word: RESPOND or IGNORE.

        Examples:
        "what's the weather like today" → RESPOND
        "yeah no I was just saying to Mike about the game" → IGNORE
        "um hmm let me think" → IGNORE
        "can you tell me about the Eiffel Tower" → RESPOND
        "hey so what time is it" → RESPOND
        "oh my god did you see that" → IGNORE
        "remind me to buy milk" → RESPOND
        "haha yeah totally" → IGNORE
        """

        var userMessage = "Transcript: \"\(transcript)\""
        if let context = recentContext {
            userMessage += "\nRecent conversation context: \(context)"
        }

        do {
            let result = try await callClassifier(
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                config: config
            )

            let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if cleaned.contains("RESPOND") {
                PrivacyLog.model(.classified, characters: transcript.count,
                                 detail: PrivacyToken(PrivacyLog.ModelClassification.respond.rawValue))
                return .respond
            } else if cleaned.contains("IGNORE") {
                PrivacyLog.model(.classified, characters: transcript.count,
                                 detail: PrivacyToken(PrivacyLog.ModelClassification.ignore.rawValue))
                return .ignore
            } else {
                // The classifier answered off-vocabulary; its answer is a rewrite of the
                // utterance as often as not, so only the verdict is recorded.
                PrivacyLog.model(.classified, characters: transcript.count,
                                 detail: PrivacyToken(PrivacyLog.ModelClassification.uncertain.rawValue))
                return .uncertain
            }
        } catch {
            PrivacyLog.model(.classificationFailed, error: SafeErrorSummary(error))
            return .uncertain
        }
    }

    // MARK: - API Call

    private func callClassifier(systemPrompt: String, userMessage: String, config: ModelConfig) async throws -> String {
        let provider = config.llmProvider

        // Use the cheapest model variant if available
        let model = config.model.lowercased().contains("4o-mini") ? config.model : config.model

        var baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .groq {
            baseURL = "https://api.groq.com/openai/v1/chat/completions"
        } else if !baseURL.hasSuffix("/chat/completions") {
            if baseURL.hasSuffix("/") {
                baseURL += "chat/completions"
            } else {
                baseURL += "/chat/completions"
            }
        }

        guard let url = URL(string: baseURL) else {
            throw IntentClassifierError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5 // Fast timeout — we need this to be quick

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 5, // We only need one word
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw IntentClassifierError.apiError(statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw IntentClassifierError.invalidResponse
        }

        return content
    }
}

enum IntentClassifierError: LocalizedError {
    case invalidURL
    case apiError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid classifier URL"
        case .apiError(let code): return "Classifier API error: \(code)"
        case .invalidResponse: return "Invalid classifier response"
        }
    }
}
