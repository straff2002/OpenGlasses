import Foundation

/// Routes an Assistive Mode (A3) frame to the right analysis mode and supplies the system prompt.
///
/// Scene mode = situational awareness of the environment. Social mode = understanding the emotional
/// state of a person the user is looking at. Routing is keyword-based on the latest user
/// transcription (if any); with no transcription it defaults to proactive Scene mode.
/// Prompts are adapted from the neurobridge project.
enum AssistiveRouter {

    enum Mode: String, Equatable {
        case scene
        case social
    }

    /// Words that indicate the user cares about a person / interaction → Social mode.
    private static let socialKeywords = ["person", "people", "face", "emotion", "feel", "feeling",
                                         "mood", "conversation", "talking", "they", "him", "her",
                                         "angry", "happy", "sad", "upset"]

    /// Choose a mode from the latest transcription. Empty/nil → proactive Scene mode.
    static func route(transcription: String?) -> Mode {
        guard let text = transcription?.lowercased(), !text.isEmpty else { return .scene }
        let tokens = Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted))
        return socialKeywords.contains(where: tokens.contains) ? .social : .scene
    }

    /// Shared JSON-contract instruction appended to every mode prompt.
    private static let jsonContract = """
    Respond ONLY in valid JSON with this exact shape: \
    {"advice": string (<15 words, one sentence), "urgency": "low"|"medium"|"high", \
    "followup": string (<10 words, optional)}. No markdown, no extra text.
    """

    static func systemPrompt(for mode: Mode) -> String {
        switch mode {
        case .scene:
            return """
            You are an assistive AI for neurodivergent users. Provide calm, clear, grounded \
            real-time support based on what the user sees. One sentence under 15 words. Identify \
            the most useful information proactively. Assign urgency. \(jsonContract)
            """
        case .social:
            return """
            You are an assistive AI for neurodivergent users. Help the user understand the emotional \
            state of the person they are looking at — calmly, concisely, in real time. Urgency: \
            low = calm/positive, medium = unease, high = distress. If no person is visible, suggest \
            repositioning. \(jsonContract)
            """
        }
    }

    /// The user-message text accompanying the frame for a given mode.
    static func userText(for mode: Mode, transcription: String?) -> String {
        if let transcription, !transcription.isEmpty {
            return transcription
        }
        switch mode {
        case .scene: return "What's the most useful thing to know about what I'm looking at right now?"
        case .social: return "How is the person I'm looking at feeling right now?"
        }
    }
}
