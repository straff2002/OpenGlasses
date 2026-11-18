import Foundation

/// Maps a spoken phrase to a HUD task action (Display Phase 3 / Plan X). These are
/// common words, so the match is deliberately **strict** — only tight whole-phrase
/// matches fire, and the caller (`HUDRouter`) only consults this while a Now/Next card
/// is actually on the glasses. A leading filler ("ok", "hey", …) is tolerated.
enum HUDVoiceCommand: Equatable {
    case complete   // "done" / "next" / "complete" / "finished"
    case skip       // "skip"
    case back       // "back" / "previous"
    case briefing   // "what's new" / "catch me up" / "what's ready" (Plan BZ digest glance; Plan KT cards)

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
             "anything for me", "anything new", "show briefing",
             // Plan KT §6.2: the same words open the day's cards on the lens when there are any.
             "whats ready", "what is ready", "whats next", "what is next", "anything ready":
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

/// The words that bring the last answer back to the lens (Plan MG §7): after the glasses' Back
/// gesture, the card's lifetime or **Close**, "show that again" puts the card up again, on the page
/// the wearer was reading. Consulted anywhere, not only while a card is up — that is the point —
/// so the match is the strictest of the lens's words: the whole utterance, a leading filler and a
/// trailing "please" only. "Show me the page" stays the page view's, "repeat" stays a request to
/// say it again, and "show that again on the phone" is a sentence for the model.
///
/// Spoken words only: text typed on the phone never reaches the lens's voice commands, so a typed
/// "show that again" is a message to the assistant like any other.
enum HUDReopenCommand {
    static let phrases: Set<String> = [
        "show that again", "show it again", "show me that again", "show me it again", "show me again",
        "show the answer", "show the answer again", "show me the answer", "show me the answer again",
        "show the last answer", "show me the last answer",
        "back to the answer", "go back to the answer",
        "show the conversation", "show me the conversation",
        "bring it back", "bring that back", "bring the answer back",
    ]

    static func matches(_ text: String) -> Bool {
        let stripped = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
        let words = stripped.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let filler: Set<String> = ["ok", "okay", "hey", "please", "uh", "um", "yeah", "yep", "now"]
        var core = Array(words.drop(while: { filler.contains($0) }))
        if core.last == "please" { core.removeLast() }
        return phrases.contains(core.joined(separator: " "))
    }
}

/// The reading view's words (Plan MG §2): "earlier" or "previous answer" opens the turn before the
/// one at the top, "latest" goes back to the newest, and "say that again" says the top answer
/// again. Consulted only while an answer is on the lens, and only whole utterances, with a leading
/// filler and a trailing "please" allowed, so "what was the earlier reading" goes to the model.
/// "Show the conversation" is `HUDReopenCommand`'s, which brings the view back; none of these is a
/// page, paging, task or reopen word, and a test keeps it that way.
///
/// Spoken words only: text typed on the phone never reaches the lens's voice commands.
enum HUDReadingCommand: Equatable {
    case earlier
    case latest
    case sayAgain

    static let phrases: [String: HUDReadingCommand] = [
        "earlier": .earlier, "earlier answer": .earlier, "the earlier answer": .earlier,
        "previous answer": .earlier, "the previous answer": .earlier,
        "show the previous answer": .earlier, "show me the previous answer": .earlier,
        "go to the previous answer": .earlier, "the answer before": .earlier, "answer before that": .earlier,
        "latest": .latest, "the latest": .latest, "latest answer": .latest, "the latest answer": .latest,
        "show the latest answer": .latest, "show me the latest answer": .latest,
        "back to the latest": .latest, "back to the latest answer": .latest,
        "newest": .latest, "the newest answer": .latest,
        "say that again": .sayAgain, "say it again": .sayAgain, "say again": .sayAgain,
    ]

    static func parse(_ text: String) -> HUDReadingCommand? {
        let stripped = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
        let words = stripped.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let filler: Set<String> = ["ok", "okay", "hey", "please", "uh", "um", "yeah", "yep", "now"]
        var core = Array(words.drop(while: { filler.contains($0) }))
        if core.last == "please" { core.removeLast() }
        return phrases[core.joined(separator: " ")]
    }
}
