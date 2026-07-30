import Foundation

/// Pure recognition of the pre-LLM voice commands the conversation flow handles before falling
/// through to the model (docs/plans/BG-spine-refactor.md, P2 groundwork).
///
/// This lifts the stop / goodbye / photo phrase matching and the persona-wake-prefix stripping out
/// of `AppState.handleTranscription` into a deterministic, headless-testable unit. It holds no state
/// and touches no services — `AppState` keeps owning the side effects; this only decides *what* a
/// transcript is.
struct VoiceCommandParser {

    let stopPhrases: [String]
    let goodbyePhrases: [String]
    let photoPhrases: [String]

    /// The phrase sets currently used by the live flow. Kept here as the single source so the
    /// matching rules and the phrases live together.
    static let `default` = VoiceCommandParser(
        stopPhrases: ["stop", "nevermind", "never mind", "cancel", "shut up", "be quiet", "quiet"],
        goodbyePhrases: ["goodbye", "good bye", "bye", "that's all", "thats all",
                         "thanks claude", "thank you claude", "i'm done", "im done",
                         "end conversation", "go to sleep"],
        photoPhrases: ["take a picture", "take a photo", "take photo", "take picture",
                       "capture photo", "snap a photo", "snap a picture", "take a snap"]
    )

    // MARK: - The disambiguation rule

    /// The commands this parser recognises.
    enum Command: String {
        case stop, goodbye, photo
    }

    /// Why a phrase match was demoted to ordinary speech.
    ///
    /// A phrase match makes a command a *candidate*, not a decision. Both of the cases below have
    /// the command phrase genuinely present as whole tokens, so tokenisation alone does not help —
    /// the rules are about the **shape of the utterance**.
    enum DemotionRule: String {
        /// The utterance opens with a question lead-in about method or cause, and the phrase begins
        /// at or after the end of it: `"how do i take a photo with these glasses"` is a question
        /// about the camera, not an instruction to fire it.
        case interrogativeFrame = "interrogative-frame"
        /// A sign-off must *end* the utterance. `"that's all i wanted to ask about the weather"`
        /// keeps going after `"that's all"`, so it is speech about a topic, not a farewell.
        case nonFinalClose = "non-final-close"
    }

    /// The outcome of testing one command against a transcript.
    struct CommandMatch: Equatable {
        let command: Command
        /// The rule that demoted it, or `nil` when the command stands.
        let demotedBy: DemotionRule?
        /// Whether the caller should act on this command.
        var authorises: Bool { demotedBy == nil }
    }

    /// Question lead-ins about method or cause.
    ///
    /// `"can you"`, `"could you"` and `"please"` are deliberately **absent**: they are polite
    /// imperatives, and treating them as questions would turn the politest phrasing of a real
    /// command into a no-op. The list stays narrow for the same reason — a lead-in that is only
    /// *sometimes* interrogative (`"can i"`) costs a working command when it guesses wrong.
    static let interrogativeLeadIns: [String] = [
        "how do i", "how do you", "how does", "how can i", "how would i", "how do we",
        "how to", "what happens if", "what happens when", "what does", "why does", "why do",
        "is it possible to", "do you know how to", "what's the best way to",
        "what is the best way to", "how did you", "how does it",
    ]

    /// Words allowed to trail a sign-off without breaking it: `"that's all, thanks for the help"`
    /// is still a farewell.
    static let closeTrailerWords: Set<String> = [
        "now", "then", "ok", "okay", "thanks", "thank", "you", "please", "bye", "goodbye",
        "for", "the", "help", "everything", "that", "all", "much", "very", "so", "again",
        "later", "night", "and", "have", "a", "good", "one", "day", "cheers", "it", "was",
        "great", "appreciate", "i",
    ]

    /// Test one command against a transcript. `nil` means no phrase matched at all.
    ///
    /// When several phrases match, the command stands if **any** occurrence survives the rules —
    /// `"that's all i wanted to ask about the weather, goodbye"` really is a farewell.
    func match(_ command: Command, in text: String) -> CommandMatch? {
        let tokens = PhraseMatcher.tokenize(text)
        guard !tokens.isEmpty else { return nil }

        // `.stop` is matched by the shared stop predicate and never demoted. Tightening it trades a
        // false positive for a false negative, and there the false negative means the user cannot
        // interrupt the assistant mid-sentence — the more dangerous direction.
        if command == .stop {
            guard PhraseMatcher.containsStopPhrase(text, phrases: stopPhrases, position: .utteranceEdge)
            else { return nil }
            return CommandMatch(command: .stop, demotedBy: nil)
        }

        let leadInEnd = Self.interrogativeLeadInEnd(in: tokens)
        var occurrences = 0
        var demotion: DemotionRule?

        for phrase in phrases(for: command) {
            for range in PhraseMatcher.ranges(of: phrase, in: tokens) {
                occurrences += 1

                // Rule A — interrogative frame (.photo and .goodbye).
                if let leadInEnd, range.lowerBound >= leadInEnd {
                    demotion = demotion ?? .interrogativeFrame
                    continue
                }

                // Rule B — non-final close (.goodbye only; .photo takes legitimate objects, as in
                // "take a picture of the sunset").
                if command == .goodbye {
                    let trailing = tokens[range.upperBound...]
                    if !trailing.allSatisfy({ Self.closeTrailerWords.contains($0) }) {
                        demotion = demotion ?? .nonFinalClose
                        continue
                    }
                }

                // Survived both rules — the command stands regardless of other occurrences.
                return CommandMatch(command: command, demotedBy: nil)
            }
        }

        guard occurrences > 0 else { return nil }
        return CommandMatch(command: command, demotedBy: demotion)
    }

    /// Token index just past an interrogative lead-in at the start of the utterance, or `nil`.
    private static func interrogativeLeadInEnd(in tokens: [String]) -> Int? {
        for leadIn in interrogativeLeadIns {
            let needle = PhraseMatcher.tokenize(leadIn)
            guard !needle.isEmpty, tokens.count >= needle.count else { continue }
            if Array(tokens[0..<needle.count]) == needle { return needle.count }
        }
        return nil
    }

    private func phrases(for command: Command) -> [String] {
        switch command {
        case .stop: return stopPhrases
        case .goodbye: return goodbyePhrases
        case .photo: return photoPhrases
        }
    }

    // MARK: - Command recognition

    /// "stop" and friends — whole-token match at an utterance edge, so "stop the timer" and
    /// "please stop" both count, while "nonstop music" does not and "I need peace and quiet to
    /// concentrate" is answered rather than swallowed. Never demoted; see ``match(_:in:)``.
    func isStop(_ text: String) -> Bool {
        match(.stop, in: text)?.authorises == true
    }

    /// "goodbye" and friends — whole-token match, demoted when the sign-off doesn't end the
    /// utterance or sits inside a question.
    func isGoodbye(_ text: String) -> Bool {
        match(.goodbye, in: text)?.authorises == true
    }

    /// "take a picture" and friends — whole-token match, demoted inside a question frame.
    ///
    /// The false positive this closes matters more than the others: `"how do i take a photo with
    /// these glasses"` fired the shutter and wrote a JPEG. The camera is on someone's face and the
    /// person in front of it never agreed to be photographed.
    func isPhoto(_ text: String) -> Bool {
        match(.photo, in: text)?.authorises == true
    }

    // MARK: - Persona wake-prefix

    /// A persona and the phrases that activate it (its wake phrases + aliases).
    struct PersonaPhrases {
        let id: String
        let phrases: [String]
    }

    /// Result of finding a persona wake-prefix in a transcript.
    struct PersonaMatch: Equatable {
        /// The matched persona's id.
        let personaId: String
        /// The remaining query with the wake phrase stripped, or the original text if stripping
        /// left nothing usable.
        let query: String
    }

    /// Detect a persona wake phrase anywhere in `text` (prefix or contained) and return the matched
    /// persona plus the query with the phrase removed. Mirrors the Action-Button / push-to-talk
    /// path: "Hey Claude, what's the weather" → (claude, "what's the weather").
    func detectPersona(in text: String, personas: [PersonaPhrases]) -> PersonaMatch? {
        let lower = normalize(text)
        for persona in personas {
            for phrase in persona.phrases {
                guard lower.hasPrefix(phrase) || lower.contains(phrase) else { continue }
                var query = text
                if let range = lower.range(of: phrase) {
                    query = String(text[range.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: ","))
                        .trimmingCharacters(in: .whitespaces)
                }
                if query.isEmpty { query = text }
                return PersonaMatch(personaId: persona.id, query: query)
            }
        }
        return nil
    }

    private func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
