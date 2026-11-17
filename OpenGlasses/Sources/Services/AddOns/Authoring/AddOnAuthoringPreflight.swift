import Foundation

/// Before anything is searched or fetched: can an add-on be the answer to this goal at all? Pure.
///
/// In order:
/// 1. It needs the wearer's contacts, camera, health data, messages, calendar, photos or
///    microphone → refused. No add-on can reach them; they are not permissions the format has.
/// 2. It needs arithmetic, loops or repeated checks → refused: add-ons have no arithmetic, no
///    loops and no scheduled runs, so it would need a built-in tool.
/// 3. A native tool or an installed add-on already does it → "I can already do that". The match
///    is an injected similarity (`Matcher`) against a fixed threshold; the default is a lexical
///    one that also counts a capability as covering a goal that names everything in its name.
enum AddOnAuthoringPreflight {

    struct Capability: Equatable, Sendable {
        /// A native tool's name, or an installed add-on's.
        let name: String
        /// One line about what it does.
        let summary: String
    }

    enum PrivateSource: String, CaseIterable, Equatable, Sendable {
        case contacts, camera, health, messages, calendar, photos, microphone
    }

    enum Verdict: Equatable, Sendable {
        case proceed
        case covered(Capability)
        case reachesPrivateData(PrivateSource)
        case needsBuiltIn
        case empty
    }

    /// How well `capability` already serves `goal`, 0…1.
    typealias Matcher = (_ goal: String, _ capability: Capability) -> Double

    static let coverageThreshold = 0.6
    static let maxGoalLength = 200

    /// Native tools never counted as covering a goal: they are general (searching the web finds
    /// pages, not answers) or are this feature's own plumbing.
    static let notCoverage: Set<String> = [
        "web_search", "get_news", "discover_capabilities", "lookup_tools", "build_addon",
        "new_topic", "save_note", "list_notes", "brain", "memory_search", "open_app",
    ]

    static func check(goal: String, native: [Capability], installed: [Capability],
                      matcher: Matcher = lexicalMatch) -> Verdict {
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        let phrase = normalisedPhrase(text)
        // With and without apostrophes, so "my contacts' birthdays" still names contacts.
        let forms = [" " + phrase + " ",
                     " " + phrase.replacingOccurrences(of: "'", with: " ").split(separator: " ").joined(separator: " ") + " "]
        func mentions(_ phrases: [String]) -> Bool { phrases.contains { p in forms.contains { $0.contains(p) } } }
        for source in PrivateSource.allCases where mentions(privatePhrases[source, default: []]) {
            return .reachesPrivateData(source)
        }
        if mentions(builtInPhrases) { return .needsBuiltIn }

        let candidates = native.filter { !notCoverage.contains($0.name) } + installed
        var best: (Capability, Double)?
        for capability in candidates {
            let score = matcher(text, capability)
            if score >= coverageThreshold, score > (best?.1 ?? 0) { best = (capability, score) }
        }
        if let best { return .covered(best.0) }
        return .proceed
    }

    /// What the wearer is told when the session ends here.
    static func message(for verdict: Verdict) -> String? {
        switch verdict {
        case .proceed: return nil
        case .empty: return String(localized: "Tell me what the add-on should do.")
        case .covered(let capability):
            return String(localized: "I can already do that: \(capability.summary)")
        case .reachesPrivateData:
            return String(localized: "An add-on can never reach your contacts, camera, health data, messages, calendar, photos or microphone, so I can't build that one.")
        case .needsBuiltIn:
            return String(localized: "That needs a built-in tool; I can't build it as an add-on.")
        }
    }

    // MARK: - Phrases (matched with a space either side, on lowercased text)

    static let privatePhrases: [PrivateSource: [String]] = [
        .contacts: [" contact ", " contacts ", " address book ", " phone number of ", " my friends "],
        .camera: [" camera ", " what i'm looking at ", " what i am looking at ", " what i see ",
                  " take a picture ", " take a photo "],
        .health: [" health ", " heart rate ", " my steps ", " step count ", " sleep data ",
                  " blood pressure ", " my workouts ", " my medication "],
        .messages: [" my messages ", " text messages ", " my texts ", " imessage ", " sms ", " my email ",
                    " my emails ", " my inbox ", " whatsapp messages "],
        .calendar: [" calendar ", " my meetings ", " my appointments ", " my schedule "],
        .photos: [" photos ", " photo library ", " my pictures ", " camera roll "],
        .microphone: [" microphone ", " record audio ", " listen to what ", " recording of "],
    ]

    static let builtInPhrases: [String] = [
        " calculate ", " add up ", " sum of ", " average ", " total of ", " multiply ", " divide ",
        " percentage of ", " for each ", " loop ", " repeat ", " keep checking ", " every hour ",
        " every day ", " every morning ", " every minute ", " each time ", " count how many ",
    ]

    // MARK: - The default matcher

    /// Coverage of the goal's content words by the capability's name and summary, after light
    /// stemming and a few folded concepts (a currency name counts as "currency"). A capability
    /// whose name words all appear in the goal covers it fully: "convert fifty euros to dollars"
    /// names both words of `convert_currency`.
    static func lexicalMatch(_ goal: String, _ capability: Capability) -> Double {
        let goalWords = contentWords(goal)
        guard !goalWords.isEmpty else { return 0 }
        let nameWords = contentWords(capability.name.replacingOccurrences(of: "_", with: " "))
        if !nameWords.isEmpty, nameWords.isSubset(of: goalWords) { return 1 }
        let capabilityWords = nameWords.union(contentWords(capability.summary))
        return Double(goalWords.intersection(capabilityWords).count) / Double(goalWords.count)
    }

    static func contentWords(_ text: String) -> Set<String> {
        let words = normalisedPhrase(text).split(separator: " ").map(String.init)
        var out = Set<String>()
        for word in words where word.count > 1 && !stopWords.contains(word) && Int(word) == nil {
            let stemmed = stem(word)
            guard !stopWords.contains(stemmed) else { continue }
            out.insert(concepts[stemmed] ?? stemmed)
        }
        return out
    }

    static func normalisedPhrase(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "'" ? Character(scalar) : " "
        }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    static func stem(_ word: String) -> String {
        if word.count > 4, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    static let concepts: [String: String] = [
        "euro": "currency", "dollar": "currency", "yen": "currency", "sterling": "currency",
        "franc": "currency", "rupee": "currency", "peso": "currency", "exchange": "currency",
        "forecast": "weather", "rain": "weather", "temperature": "weather",
    ]

    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "for", "from", "by", "with",
        "what", "what's", "whats", "is", "are", "was", "be", "it", "its", "it's", "me", "my", "i",
        "you", "your", "this", "that", "how", "when", "where", "which", "who", "can", "could",
        "please", "tell", "get", "set", "show", "give", "find", "look", "up", "lookup", "check",
        "use", "using", "into", "about", "now", "today", "current", "live", "latest", "some",
        "one", "two", "three", "four", "five", "ten", "twenty", "fifty", "hundred", "thousand",
        "skill", "tool", "add", "addon", "build", "make", "yourself", "do", "does", "will",
        "need", "needed", "no", "key", "api",
    ]
}
