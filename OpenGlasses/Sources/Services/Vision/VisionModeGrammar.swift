import Foundation

/// The spoken way in and out of vision mode.
///
/// Deliberately narrow. While the mode is on there is no wake word, so **every utterance is a
/// candidate command** — and "stop video" said in passing ("I had to stop video calls at work")
/// must not end the mode. The phrases are therefore matched as a whole utterance rather than
/// searched for inside one, which is the same trade `VoiceCommandParser` already makes for the
/// commands that can destroy something.
enum VisionModeGrammar {

    enum Command: Equatable {
        case start
        case stop
    }

    /// Whole-utterance phrases. Kept short and few: a wearer cannot discover a grammar they have to
    /// remember, so these are the obvious things a person says, and nothing clever.
    static let startPhrases = [
        "start video", "start vision", "start looking", "look with me", "watch this"
    ]

    static let stopPhrases = [
        "stop video", "stop vision", "stop looking", "stop watching"
    ]

    /// Match a complete utterance. Returns nil for anything that is not, in its entirety, one of
    /// the phrases — including an utterance that merely *contains* one.
    static func command(for utterance: String) -> Command? {
        let normalised = normalise(utterance)
        guard !normalised.isEmpty else { return nil }
        if startPhrases.contains(normalised) { return .start }
        if stopPhrases.contains(normalised) { return .stop }
        return nil
    }

    /// Lowercase, strip punctuation and collapse whitespace, so "Stop video." and "stop  video"
    /// are the same utterance. Nothing is dropped from the middle — that would reintroduce the
    /// substring matching this type exists to avoid.
    static func normalise(_ text: String) -> String {
        let stripped = text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0)
        }
        return String(String.UnicodeScalarView(stripped))
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
