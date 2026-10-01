import Foundation

/// Requests a native tool can serve with no model at all, recognised by keyword (Plan GE P2).
///
/// When the conversation is on the phone and nothing on it can think — the phone locked in a pocket
/// is the common case — these still get an answer: the time, a timer, "remember that…", step
/// count, "where did I park", "where are my keys". Everything else is held for the cloud.
///
/// It runs first on the phone in the foreground too: a deterministic answer is faster and more
/// reliable than a small model choosing a tool. It is deliberately small; an on-device intent
/// classifier replaces it when one lands.
///
/// Every route it produces names a tool `OfflineToolPolicy` classifies as `.local` —
/// `OfflineKeywordRouterTests` pins that, so the router can never reach for the network.
enum OfflineKeywordRouter {

    struct Route: Equatable {
        let toolName: String
        let arguments: [String: String]
        /// For the timer, the argument is an integer.
        let seconds: Int?

        init(toolName: String, arguments: [String: String] = [:], seconds: Int? = nil) {
            self.toolName = toolName
            self.arguments = arguments
            self.seconds = seconds
        }

        /// Arguments as the tool router takes them.
        var toolArguments: [String: Any] {
            var args: [String: Any] = arguments
            if let seconds { args["seconds"] = seconds }
            return args
        }
    }

    static func route(_ utterance: String) -> Route? {
        let text = normalise(utterance)
        guard !text.isEmpty else { return nil }

        if let seconds = timerSeconds(text) {
            return Route(toolName: "set_timer", seconds: seconds)
        }
        if matchesAny(text, ["where did i park", "where's my car", "where is my car",
                             "where did i leave the car", "take me back to my car", "find my car"]) {
            return Route(toolName: "parking", arguments: ["action": "where"])
        }
        if matchesAny(text, ["i parked", "remember where i parked", "save my parking", "i've parked"]) {
            return Route(toolName: "parking", arguments: ["action": "save", "details": utterance.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        if let content = noteContent(text, original: utterance) {
            return Route(toolName: "save_note", arguments: ["content": content])
        }
        if let object = misplacedObject(text) {
            return Route(toolName: "object_memory", arguments: ["action": "find", "object": object])
        }
        if matchesAny(text, ["how many steps", "step count", "my steps today"]) {
            return Route(toolName: "step_count")
        }
        if matchesAny(text, ["what time is it", "what's the time", "what is the time", "the time please",
                             "what's the date", "what is the date", "what day is it", "what's today's date"]) {
            return Route(toolName: "get_datetime")
        }
        return nil
    }

    // MARK: - Rules

    /// "set a timer for five minutes", "timer for 90 seconds", "a 10 minute timer".
    static func timerSeconds(_ text: String) -> Int? {
        guard text.contains("timer") else { return nil }
        if text.contains("half an hour") || text.contains("half hour") { return 1800 }
        let words = text.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        for (index, word) in words.enumerated() {
            guard let unit = unitSeconds(word) else { continue }
            guard index > 0, let amount = number(words[index - 1]) else { continue }
            // "forty five minutes": a tens word before a units word adds up.
            if index > 1, amount < 10, let tens = number(words[index - 2]), tens >= 20, tens % 10 == 0 {
                return (tens + amount) * unit
            }
            return amount * unit
        }
        return nil
    }

    /// "remember that the gate code is 4412", "make a note that…", "note that…", "take a note…".
    static func noteContent(_ text: String, original: String) -> String? {
        let leads = ["remember that ", "please remember that ", "make a note that ", "make a note ",
                     "take a note that ", "take a note ", "note that ", "jot down "]
        guard let lead = leads.first(where: { text.hasPrefix($0) }) else { return nil }
        // Keep the wearer's own wording (case, digits) where the lead can be found in it; fall back
        // to the normalised text when punctuation inside the lead made it unfindable.
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder: String
        if let range = trimmed.range(of: lead, options: [.caseInsensitive, .anchored]) {
            remainder = String(trimmed[range.upperBound...])
        } else {
            remainder = String(text.dropFirst(lead.count))
        }
        let content = remainder
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return content.isEmpty ? nil : content
    }

    /// "where are my keys", "where did I put my wallet", "where did I leave my glasses case".
    static func misplacedObject(_ text: String) -> String? {
        let leads = ["where are my ", "where is my ", "where's my ", "where did i put my ",
                     "where did i leave my ", "where did i put the ", "where did i leave the "]
        guard let lead = leads.first(where: { text.hasPrefix($0) }) else { return nil }
        let object = String(text.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
        // The car belongs to the parking rule above; this is everything else.
        guard !object.isEmpty, object != "car" else { return nil }
        return object
    }

    // MARK: - Helpers

    private static func normalise(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: CharacterSet(charactersIn: "?!.,"))
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchesAny(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
    }

    private static func unitSeconds(_ word: String) -> Int? {
        switch word {
        case "second", "seconds", "sec", "secs": return 1
        case "minute", "minutes", "min", "mins": return 60
        case "hour", "hours": return 3600
        default: return nil
        }
    }

    private static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "ninety": 90,
    ]

    private static func number(_ word: String) -> Int? {
        if let value = Int(word), value > 0 { return value }
        return numberWords[word]
    }
}
