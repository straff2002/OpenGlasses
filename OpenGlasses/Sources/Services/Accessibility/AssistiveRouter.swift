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

// MARK: - Narration commands (Plan CV P2)

extension AssistiveRouter {

    /// What the wearer asked continuous scene narration to do.
    ///
    /// Maps onto `NarrationSessionPolicy.Event`, but deliberately does not *use* that type: this is
    /// parsing, and keeping it separate means the phrase table can change without touching the
    /// state machine (and the state machine stays testable without a string in sight).
    enum NarrationCommand: String, Equatable, CaseIterable {
        /// Watch silently — the cheap half, and the default the mode starts in.
        case start
        /// Watch and speak.
        case startNarrating
        /// Stop speaking, keep watching. Grounding continues.
        case stopNarrating
        /// Leave the mode entirely.
        case stop
    }

    /// Phrases per command, checked in `NarrationCommand.allCases` order.
    ///
    /// The order is the substance, not an implementation detail: *"stop narrating"* contains
    /// *"narrating"*, so every stop form has to be matched before every start form or the wearer
    /// asking for quiet gets more speech. `allCases` puts the two start forms first, so the table
    /// is walked in a deliberately different order below — spelled out rather than relying on the
    /// enum's declaration order, which exists to read well in the state machine.
    private static let narrationPhrases: [(NarrationCommand, [String])] = [
        (.stopNarrating, ["stop narrating", "stop describing", "stop talking about what you see",
                          "quiet narration", "stop the narration", "stop narration"]),
        (.stop, ["stop watching", "stop looking", "stop scene narration", "turn off narration",
                 "turn off watching", "stop watching the scene"]),
        (.startNarrating, ["start narrating", "start describing", "narrate what you see",
                           "describe as i go", "describe what you see", "tell me what you see as i go",
                           "start narration", "narrate the scene"]),
        (.start, ["start watching", "watch the scene", "keep an eye out", "start scene narration",
                  "watch what i see", "keep watching"]),
    ]

    /// Parse a narration command out of a transcription, or nil if it isn't one.
    ///
    /// Substring matching on a normalised string rather than exact equality, because this arrives
    /// from ASR inside a longer utterance ("hey, start narrating please"). Nil is the common and
    /// correct answer — almost nothing the wearer says is one of these.
    static func narrationCommand(in transcription: String?) -> NarrationCommand? {
        guard let transcription else { return nil }
        let text = normalisedForCommands(transcription)
        guard !text.isEmpty else { return nil }

        for (command, phrases) in narrationPhrases {
            if phrases.contains(where: { text.contains($0) }) { return command }
        }
        return nil
    }

    /// Lowercased, punctuation-stripped, single-spaced — so "Stop narrating!" and "stop  narrating"
    /// both match the one table entry.
    private static func normalisedForCommands(_ text: String) -> String {
        let stripped = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(stripped).split(separator: " ").joined(separator: " ")
    }
}

// MARK: - Narration prompt (Plan CV P2)

extension AssistiveRouter {

    /// The description prompt for continuous scene narration.
    ///
    /// Deliberately **not** `systemPrompt(for: .scene)`: that one returns JSON advice with an
    /// urgency field, which is the on-demand assistive shape. Narration wants one plain spoken
    /// sentence, because it is read straight out and because `NarrationGate` scores the words that
    /// come back — JSON scaffolding would be scored as content and inflate the similarity between
    /// two genuinely different scenes.
    ///
    /// "Describe what changed" is not asked for here. The loop only generates on a scene `FrameGate`
    /// already called distinct, and a model asked what changed will invent a change to report.
    static let narrationSystemPrompt = """
    You describe what a wearer of smart glasses is looking at, for someone who cannot see it.

    Reply with ONE plain sentence, under 20 words, describing the space and what matters in it: \
    where things are relative to the wearer, obstacles, people, exits, signage. Lead with what \
    would matter to someone moving through this space.

    Do not open with "the image shows" or "I see" — say the thing itself. No markdown, no lists, \
    no preamble: this is spoken aloud.
    """

    /// The user-message text accompanying a narration frame.
    static let narrationUserText = "Describe what I'm looking at."
}
