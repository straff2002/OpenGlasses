import Foundation

/// Maps a spoken phrase to a HUD task action (Display Phase 3 / Plan X). These are
/// common words, so the match is deliberately **strict** — only tight whole-phrase
/// matches fire, and the caller (`HUDRouter`) only consults this while a Now/Next card
/// is actually on the glasses. A leading filler ("ok", "hey", …) is tolerated.
enum HUDVoiceCommand: Equatable {
    case complete   // "done" / "next" / "complete" / "finished"
    case skip       // "skip"
    case back       // "back" / "previous"

    static func parse(_ text: String) -> HUDVoiceCommand? {
        // Lowercase, strip punctuation, collapse whitespace.
        let stripped = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
        let words = stripped.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let filler: Set<String> = ["ok", "okay", "hey", "please", "uh", "um", "yeah", "yep", "now"]
        let core = words.drop(while: { filler.contains($0) }).joined(separator: " ")

        switch core {
        case "done", "next", "complete", "completed", "finish", "finished",
             "next step", "mark done", "mark complete", "done with this", "next one":
            return .complete
        case "skip", "skip this", "skip step", "skip this step":
            return .skip
        case "back", "go back", "previous", "previous step", "step back":
            return .back
        default:
            return nil
        }
    }
}
