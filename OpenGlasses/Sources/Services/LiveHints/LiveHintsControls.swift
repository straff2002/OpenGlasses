import Foundation

// The controls a session answers without the phone (Plan MO §6, P2): temple taps and media buttons,
// the Live Activity's buttons, and the fixed spoken phrases. Pure, so what each one means while a
// session runs, and that nothing changes when none does, is tested headlessly.

/// What a temple tap or a Bluetooth media button does while a session runs (§6, decision 10).
///
/// The tap count is the one `MediaTriggerService` decoded through `TempleCalibration` (which media
/// command each count arrives as); this decides what the count means to a session. While one
/// runs, every tap is the session's and none reaches the wake word or the temple-tap assignments.
/// With no session it is not this policy's, and the wearer's own mapping applies unchanged.
enum LiveHintsTapPolicy {

    enum Outcome: Equatable, Sendable {
        /// No session: the tap goes to the wearer's own temple-tap mapping.
        case notOurs
        case repeatHint
        case skipHint
        /// The session took the tap and has nothing to do with it (the refused tone).
        case ignored
    }

    /// - Parameters:
    ///   - hintPlaying: a hint is being spoken, or is waiting for quiet to be spoken.
    static func resolve(_ gesture: TempleGesture, sessionRunning: Bool, hintPlaying: Bool) -> Outcome {
        guard sessionRunning else { return .notOurs }
        switch gesture {
        // One tap: skip the hint playing, else say (or show) the last one again.
        case .one: return hintPlaying ? .skipHint : .repeatHint
        // Two taps: skip, whatever is playing.
        case .two: return hintPlaying ? .skipHint : .ignored
        // Three taps are not assigned during a session: a stray tap must never stop it.
        case .three: return .ignored
        }
    }

    /// The tone that confirms the tap, so a wearer with the phone away hears it was taken.
    static func earcon(for outcome: Outcome) -> TempleEarcon? {
        switch outcome {
        case .notOurs: return nil
        case .repeatHint, .skipHint: return .accepted
        case .ignored: return .refused
        }
    }
}

/// The fixed phrases a session answers (§1, §6, P2). Whole utterances only, a leading filler and a
/// trailing "please" allowed, the same strict matching as the lens's words (`HUDReopenCommand`), so
/// "how do I start live hints" is a question for the assistant, not a command.
///
/// Spoken words only: typed text never reaches these.
enum LiveHintsVoiceCommand: Equatable, Sendable {
    case start
    case stop
    /// Bring a hint the wearer dismissed back to the lens.
    case show
    /// "hint me about the warranty": add a keyword for the session.
    case addKeyword(String)

    static let startPhrases: Set<String> = [
        "start live hints", "start hints", "start the hints", "turn on live hints", "turn live hints on",
        "live hints on", "hint me in this meeting", "start hinting",
    ]
    static let stopPhrases: Set<String> = [
        "stop hints", "stop live hints", "stop the hints", "turn off live hints", "turn live hints off",
        "live hints off", "end live hints", "stop hinting",
    ]
    static let showPhrases: Set<String> = [
        "show hints", "show the hints", "show hints again", "show the hint", "show me the hint",
        "show the hint again", "show me the hints", "bring the hints back",
    ]
    static let keywordOpeners: [[String]] = [
        ["hint", "me", "about"], ["give", "me", "hints", "about"], ["hint", "me", "on"],
    ]
    /// A keyword longer than this is a sentence, not a name or a term.
    static let maximumKeywordWords = 5

    private static let fillers: Set<String> = ["ok", "okay", "hey", "please", "uh", "um", "yeah", "yep", "now", "so"]

    static func parse(_ text: String) -> LiveHintsVoiceCommand? {
        let words = tokens(text)
        var core = Array(words.drop { fillers.contains($0.lowercased()) })
        if core.last?.lowercased() == "please" { core.removeLast() }
        guard !core.isEmpty else { return nil }
        let folded = core.map { $0.lowercased() }
        let phrase = folded.joined(separator: " ")
        if startPhrases.contains(phrase) { return .start }
        if stopPhrases.contains(phrase) { return .stop }
        if showPhrases.contains(phrase) { return .show }
        for opener in keywordOpeners where folded.count > opener.count && Array(folded.prefix(opener.count)) == opener {
            var rest = Array(core.dropFirst(opener.count))
            if rest.first?.lowercased() == "the" { rest.removeFirst() }
            guard !rest.isEmpty, rest.count <= maximumKeywordWords else { return nil }
            return .addKeyword(rest.joined(separator: " "))
        }
        return nil
    }

    /// The utterance's words with punctuation stripped and the case kept, so a keyword keeps the
    /// spelling the recogniser gave it ("Tecumseh").
    private static func tokens(_ text: String) -> [String] {
        let cleaned = text.replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "'-")).inverted)
            .joined()
        return cleaned.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }
}
