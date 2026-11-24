import Foundation

/// Numbers a downloaded model put in a call that nobody said (Plan MQ P3). Pure.
///
/// On the phone, Gemma 4 E2B answered "work out the voltage drop at 15 amps over 50 feet of 14
/// gauge copper" with `domain_calc` calls carrying conductor figures it made up
/// (`resistance_ohm_per_ft: "16.0"`, `area_cmil: "22030"` with a factor). The tool takes a given
/// resistance over the wire gauge, so the drop would have been worked out from invented figures and
/// spoken as the answer. `LocalToolLoop` runs every model-made call through `filter(_:grounding:)`
/// first: a top-level argument whose value is a plain number (`plainNumber(_:)`) is kept only when
/// that number appears in the grounding — the turn, the earlier conversation, this turn's tool
/// results so far, and what the caller adds (the job context the model reads in its prompt).
/// A call `LocalTurnRouter` made is not filtered: its values come from the turn.
///
/// - Matching is by value: `115` == `"115"` == `"115.0"`, `".68"` == `"0.68"`, `"1,200"` == `1200`,
///   and a number written against its unit in the text ("115V", "7.5in") counts. A sign is not
///   compared, since it is said as a word ("minus 4", "4 below"). Spelled numbers up to the
///   thousands count ("fifteen amps", "twenty-five feet"); transcription mostly gives digits.
/// - A duration grounds its seconds and minutes too ("ten minutes" grounds 600): a timer takes
///   seconds, and a technician never says them.
/// - Anything else the model converted is dropped: "50 feet" given as `length_m: 15.24` loses the
///   length, and the tool asks for one. That is accepted; the tools take the unit the technician
///   used.
/// - Never dropped: text that is not a plain number (a gauge like "1/0", a model number, an id with
///   letters), booleans, enum words, nested values, and the paging controls in `exemptKeys`.
enum LocalArgumentGrounding {

    /// Paging controls the model sets for itself ("the next page" after a result that said there
    /// are more): never a figure about the work, and dropping one would page back to the start.
    static let exemptKeys: Set<String> = ["offset", "limit"]

    /// The numbers the grounding holds, by value.
    struct Grounding {
        private(set) var values: [Double] = []

        init(_ texts: [String] = []) {
            for text in texts { add(text) }
        }

        mutating func add(_ text: String) {
            values.append(contentsOf: LocalArgumentGrounding.numbers(in: text))
        }

        func contains(_ value: Double) -> Bool {
            let magnitude = abs(value)
            return values.contains { abs($0 - magnitude) <= 1e-9 * max(1, magnitude) }
        }
    }

    struct Filtered {
        /// The arguments to run with: the model's, less the dropped ones.
        let arguments: [String: Any]
        /// The names dropped, sorted. Model-facing only (`modelNote(dropped:)`); never logged.
        let dropped: [String]
    }

    /// `arguments` without the plain numbers `grounding` does not hold. Pure.
    static func filter(_ arguments: [String: Any], grounding: Grounding) -> Filtered {
        var kept = arguments
        var dropped: [String] = []
        for (key, value) in arguments where !exemptKeys.contains(key) {
            guard let number = plainNumber(value), !grounding.contains(number) else { continue }
            kept.removeValue(forKey: key)
            dropped.append(key)
        }
        return Filtered(arguments: kept, dropped: dropped.sorted())
    }

    static func filter(_ arguments: [String: Any], groundingText: [String]) -> Filtered {
        filter(arguments, grounding: Grounding(groundingText))
    }

    /// What the model reads after the call's result when arguments were dropped, so it can ask for
    /// a value rather than make up another. Never spoken.
    static func modelNote(dropped: [String]) -> String {
        let names = dropped.prefix(8).map { String($0.prefix(64)) }
        return "Not used, because nobody said these numbers: \(names.joined(separator: ", ")). "
            + "Ask for a value rather than guess it."
    }

    // MARK: - Reading numbers

    /// The value when `value` is a plain number: a JSON number (not a boolean), or text that is one
    /// number with at most a sign and one unit word ("115", "-4", "0.68", "1,200", "115V",
    /// "7.5 inWC", "15%"). Nil for anything else: "1/0", "090XV36C", "3 bolts on the left".
    static func plainNumber(_ value: Any) -> Double? {
        if let text = value as? String { return plainNumber(text: text) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static let plainNumberPattern = try! NSRegularExpression(
        pattern: #"^[+\-−]?(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?|\.\d+)\s?(?:[A-Za-z°µΩ%"']+(?:/[A-Za-z]+)?)?$"#)

    private static func plainNumber(text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = plainNumberPattern.firstMatch(in: trimmed, range: range),
              let digits = Range(match.range(at: 1), in: trimmed),
              let magnitude = decimal(String(trimmed[digits])) else { return nil }
        return trimmed.hasPrefix("-") || trimmed.hasPrefix("\u{2212}") ? -magnitude : magnitude
    }

    private static func decimal(_ digits: String) -> Double? {
        let plain = digits.replacingOccurrences(of: ",", with: "")
        return Double(plain.hasPrefix(".") ? "0" + plain : plain)
    }

    /// Numbers, words, and any other character on its own, so punctuation ends a run of number words
    /// ("twenty-five, two hundred" is two numbers).
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d*\.\d+|\d+|[a-z]+|[^\sa-z0-9]"#)

    /// The hyphen inside a spelled number ("twenty-five"), so its two words read as one number.
    private static let wordHyphen = try! NSRegularExpression(pattern: #"(?<=[a-z])-(?=[a-z])"#)

    /// Every number `text` says, in digits or in words, unsigned, with a duration's seconds and
    /// minutes beside it. Pure.
    static func numbers(in text: String) -> [Double] {
        let cased = text.lowercased()
        let lowered = wordHyphen.stringByReplacingMatches(in: cased, range: NSRange(cased.startIndex..., in: cased),
                                                          withTemplate: " ")
        let range = NSRange(lowered.startIndex..., in: lowered)
        let tokens = tokenPattern.matches(in: lowered, range: range).compactMap { Range($0.range, in: lowered) }
            .map { String(lowered[$0]) }
        var found: [Double] = []
        var index = 0
        while index < tokens.count {
            var value: Double?
            var next = index + 1
            if let first = tokens[index].first, first.isNumber || (first == "." && tokens[index].count > 1) {
                value = decimal(tokens[index])
            } else if tokens[index] == "half", next + 1 < tokens.count, tokens[next] == "an",
                      ["hour", "hr"].contains(tokens[next + 1]) {
                value = 0.5
                next += 1
            } else if let spelled = spelledNumber(tokens, from: index) {
                found.append(contentsOf: spelled.parts)
                value = spelled.value
                next = spelled.end
            }
            if let value {
                found.append(value)
                if next < tokens.count {
                    switch tokens[next] {
                    case "minute", "minutes", "min", "mins": found.append(value * 60)
                    case "hour", "hours", "hr", "hrs": found.append(contentsOf: [value * 60, value * 3600])
                    default: break
                    }
                }
            }
            index = max(next, index + 1)
        }
        return found
    }

    private static let smallNumbers: [String: Double] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// A run of number words from `start` ("twenty five", "two hundred and fifty"): its value, each
    /// word's own value, and the index after it. Nil when `start` is not a number word.
    private static func spelledNumber(_ tokens: [String], from start: Int) -> (value: Double, parts: [Double], end: Int)? {
        var total = 0.0
        var current = 0.0
        var parts: [Double] = []
        var index = start
        var any = false
        while index < tokens.count {
            let word = tokens[index]
            if let small = smallNumbers[word] {
                current += small
                parts.append(small)
            } else if word == "hundred" {
                current = max(current, 1) * 100
                parts.append(100)
            } else if word == "thousand" {
                total += max(current, 1) * 1000
                current = 0
                parts.append(1000)
            } else if word == "and", any, index + 1 < tokens.count,
                      smallNumbers[tokens[index + 1]] != nil {
                index += 1
                continue
            } else {
                break
            }
            any = true
            index += 1
        }
        return any ? (total + current, parts, index) : nil
    }
}
