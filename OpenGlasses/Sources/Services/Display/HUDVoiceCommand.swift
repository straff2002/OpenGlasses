import Foundation

/// Maps a spoken phrase to a HUD task action (Display Phase 3 / Plan X). These are
/// common words, so the match is deliberately **strict** — only tight whole-phrase
/// matches fire, and the caller (`HUDRouter`) only consults this while a Now/Next card
/// is actually on the glasses. A leading filler ("ok", "hey", …) is tolerated.
enum HUDVoiceCommand: Equatable {
    case complete   // "done" / "next" / "complete" / "finished"
    case skip       // "skip"
    case back       // "back" / "previous"
    case briefing   // "what's new" / "catch me up" / "briefing" (Plan BZ — digest glance)

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
        case "whats new", "what is new", "catch me up", "briefing", "my briefing",
             "anything for me", "anything new", "show briefing":
            return .briefing
        default:
            return nil
        }
    }
}

/// The answer card's paging words (Plan KP §3, "Other input"). A separate parse from
/// `HUDVoiceCommand`: `HUDRouter` consults it only while the frame on the glasses is an answer
/// card, so "next" keeps meaning "step done" on a task card. Whole short utterances only — the
/// same strict, filler-tolerant matching — so "next" inside a sentence is never taken.
/// "Repeat", "save that" and "send that" are not here: they stay ordinary requests.
enum HUDAnswerVoiceCommand: Equatable {
    case next   // "next" / "next page"
    case back   // "back" / "previous"
    case close  // "close" / "clear"

    static func parse(_ text: String) -> HUDAnswerVoiceCommand? {
        let stripped = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
        let words = stripped.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let filler: Set<String> = ["ok", "okay", "hey", "please", "uh", "um", "yeah", "yep", "now"]
        let core = words.drop(while: { filler.contains($0) }).joined(separator: " ")

        switch core {
        case "next", "next page":
            return .next
        case "back", "go back", "previous", "previous page":
            return .back
        case "close", "clear", "close that", "clear that", "close it", "dismiss":
            return .close
        default:
            return nil
        }
    }
}
