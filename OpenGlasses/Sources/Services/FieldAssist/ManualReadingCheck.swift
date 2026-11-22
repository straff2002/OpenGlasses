import Foundation

/// A model's reading of manual passages: did they answer the question, what is the answer, which
/// passage it came from and the words it relied on (Plan MP's `ManualReading`, built under Plan MQ
/// P0 so the local-model graders and MP's reader share one check).
struct ManualReading: Equatable, Sendable {
    /// The model's own claim that the passages answer the question.
    let found: Bool
    let answer: String
    /// The cited passage's id, as the passages were handed to the reader.
    let passage: String
    /// The words of the passage the answer relied on.
    let quote: String
}

/// Whether a model's answer from manual passages may be spoken as an answer (Plan MP P0, built
/// under Plan MQ P0). Pure.
///
/// The research behind both plans found abstention weak in every small model: the best decline
/// correctly about 57% of the time when nothing in front of them answers the question. So the
/// decision isn't left to the model. A reading is accepted only when
///
/// 1. the model says the passages answered it (`found`),
/// 2. it names a passage that was handed to it,
/// 3. its quote is non-empty and occurs in **that** passage (whitespace, case, dashes and quote
///    marks normalised) — a quote from a different passage is not evidence for this one — and
/// 4. every number-with-a-unit in the answer occurs in that passage: the same number (4.5 is not
///    45, though 4.50 is 4.5) and the same unit, written any of the usual ways (`in. w.c.`, `inWC`,
///    `inches w.c.`, the water-gauge `in. w.g.`; `°F`, `F`, `degrees F`). The unit may sit in a table's heading rather than
///    beside the number, so it is looked for anywhere in the passage.
///
/// Anything else is declined, and the caller says "that isn't in the manual" with the page the
/// nearest passage came from — never the answer.
enum ManualReadingCheck {

    enum Verdict: Equatable {
        case accepted
        case declined(Reason)

        var isAccepted: Bool { self == .accepted }
    }

    /// Why a reading was declined. Carries no text from the reading or the passages.
    enum Reason: String, Equatable, Sendable {
        /// The model said the passages don't answer it.
        case notFound
        /// No answer at all.
        case emptyAnswer
        /// No quote, or a quote of only whitespace and punctuation.
        case emptyQuote
        /// The cited passage wasn't one of those handed over.
        case unknownPassage
        /// The quote isn't in the cited passage.
        case quoteNotInPassage
        /// A number with a unit in the answer isn't in the cited passage.
        case numberNotInPassage
    }

    /// Check `reading` against the passages it was given, by id.
    static func check(_ reading: ManualReading, passages: [String: String]) -> Verdict {
        guard reading.found else { return .declined(.notFound) }
        guard !normalised(reading.answer).isEmpty else { return .declined(.emptyAnswer) }
        let quote = normalised(reading.quote)
        guard quote.contains(where: { $0.isLetter || $0.isNumber }) else { return .declined(.emptyQuote) }
        guard let passage = passages[reading.passage] ?? passages[passageID(reading.passage)] else {
            return .declined(.unknownPassage)
        }
        let text = normalised(passage)
        guard text.contains(quote) else { return .declined(.quoteNotInPassage) }

        let passageNumbers = Set(numbers(in: text))
        let passageUnits = units(in: text)
        for quantity in quantities(in: normalised(reading.answer)) {
            guard passageNumbers.contains(quantity.value), passageUnits.contains(quantity.unit) else {
                return .declined(.numberNotInPassage)
            }
        }
        return .accepted
    }

    // MARK: - Normalising

    /// A cited passage id as it was handed over: surrounding space, brackets and quote marks
    /// removed, and a leading "passage" dropped, so "[p1]", "(p1)" and "Passage p1" all cite `p1`.
    /// Only the wrapping goes: an id that names something else ("TABLE 39 SM p.67") still matches
    /// nothing. Gemma 4 E2B copied the brackets of the reader's old "[p1]" label into 31 of 43
    /// declined readings on the phone (Plan MQ P3).
    static func passageID(_ cited: String) -> String {
        let wrapping = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "[](){}<>\"'`\u{2018}\u{2019}\u{201C}\u{201D}:"))
        var id = cited.trimmingCharacters(in: wrapping)
        if id.lowercased().hasPrefix("passage") {
            id = String(id.dropFirst("passage".count)).trimmingCharacters(in: wrapping)
        }
        return id
    }

    /// Lowercased, whitespace collapsed, dashes and quote marks folded to ASCII, a thin or
    /// non-breaking space read as a space.
    static func normalised(_ text: String) -> String {
        var folded = text.lowercased()
        for (from, to) in [("\u{2013}", "-"), ("\u{2014}", "-"), ("\u{2212}", "-"), ("\u{2010}", "-"),
                           ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""),
                           ("\u{00A0}", " "), ("\u{2009}", " "), ("\u{202F}", " ")] {
            folded = folded.replacingOccurrences(of: from, with: to)
        }
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Numbers and units

    struct Quantity: Equatable {
        let value: Decimal
        /// The canonical unit token (`psi`, `inwc`, `f`, `v`…).
        let unit: String
    }

    /// Every number in `text` as a value, so `4.50` and `4.5` are equal and `45` is not. A thousands
    /// comma (`1,200`) reads as one number.
    static func numbers(in text: String) -> [Decimal] {
        matches(of: numberPattern, in: text).compactMap { decimal($0) }
    }

    /// Each number in `text` that a unit follows, with the unit's canonical token.
    static func quantities(in text: String) -> [Quantity] {
        let pattern = numberPattern + #"\s*(?:(?:-|to|and)\s*"# + numberPattern + #"\s*)?"# + adjacentUnitPattern
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: [Quantity] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text),
                  let unitRange = Range(match.range(at: match.numberOfRanges - 1), in: text),
                  let unit = canonicalUnit(String(text[unitRange])) else { continue }
            // Both ends of a range ("4.5 - 10.5 in. w.c.", "4.5 to 10.5") carry the unit.
            for number in numbers(in: String(text[whole])) {
                found.append(Quantity(value: number, unit: unit))
            }
        }
        return found
    }

    /// The canonical unit tokens `text` mentions: every unit written after a number, and every
    /// unambiguous unit written anywhere — a table heading's "(°F)" or "in. w.c.". A one-letter unit
    /// or "in" counts only after a number, since "a", "c" and "in" are words as well.
    static func units(in text: String) -> Set<String> {
        let scanned = matches(of: #"(?<![a-z])"# + scannedUnitPattern, in: text, group: 1).compactMap(canonicalUnit)
        return Set(scanned).union(quantities(in: text).map(\.unit))
    }

    /// A unit as written, folded to one token. Nil for a word that isn't a unit this check knows.
    static func canonicalUnit(_ written: String) -> String? {
        let token = written.lowercased()
            .replacingOccurrences(of: "°", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
        return unitAliases[token]
    }

    /// A number: digits with an optional decimal part, or a decimal part alone; not part of a word
    /// or a model number ("R410A", "v1.5").
    private static let numberPattern = #"(?<![\w.])(?:\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?|\.\d+)(?![\d])"#

    /// Spellings that are a unit wherever they appear, longest first so `in. w.c.` wins over `in`.
    private static let scannedSpellings = [
        "inches w\\.?\\s?[cg]\\.?", "inch(?:es)? of water", "in\\.?\\s?w\\.?\\s?[cg]\\.?", "iwc", "inwc",
        "\"\\s?w\\.?\\s?c\\.?", "w\\.c\\.",
        "degrees fahrenheit", "degrees celsius", "degrees f", "degrees c", "deg f", "deg c",
        "°\\s?f", "°\\s?c", "fahrenheit", "celsius",
        "psig", "psia", "psi", "kpa", "bar", "inhg", "in\\.?\\s?hg",
        "volts?", "vac", "vdc", "millivolts?", "mv", "amps?", "amperes?", "milliamps?", "ma",
        "microamps?", "µa", "ohms?", "ω", "kω", "microfarads?", "µf", "uf", "mfd",
        "hz", "rpm", "cfm", "btuh?", "mbh", "kw", "watts?",
        "ft", "feet", "inches", "mm", "cm",
        "lbs?", "pounds?", "oz", "kg",
        "seconds?", "secs?", "minutes?", "mins?", "hours?", "hrs?",
        "%", "percent",
    ]

    /// One-letter units and "inch", read only right after a number ("41 s" in a timing table).
    private static let adjacentOnlySpellings = ["inch", "in", "f", "c", "v", "a", "w", "g", "s", "h"]

    private static let scannedUnitPattern = "(" + scannedSpellings.joined(separator: "|") + ")(?![a-z0-9])"
    private static let adjacentUnitPattern =
        "(" + (scannedSpellings + adjacentOnlySpellings).joined(separator: "|") + ")(?![a-z0-9])"

    private static let unitAliases: [String: String] = {
        var table: [String: String] = [:]
        func add(_ canonical: String, _ spellings: [String]) {
            for spelling in spellings { table[spelling] = canonical }
        }
        add("inwc", ["incheswc", "incheswg", "inchesofwater", "inchofwater", "inwc", "inwg", "iwc", "\"wc", "wc"])
        add("f", ["f", "degreesfahrenheit", "degreesf", "degf", "fahrenheit"])
        add("c", ["c", "degreescelsius", "degreesc", "degc", "celsius"])
        add("psi", ["psi", "psig", "psia"])
        add("kpa", ["kpa"])
        add("bar", ["bar"])
        add("inhg", ["inhg"])
        add("v", ["v", "volt", "volts", "vac", "vdc"])
        add("mv", ["mv", "millivolt", "millivolts"])
        add("a", ["a", "amp", "amps", "ampere", "amperes"])
        add("ma", ["ma", "milliamp", "milliamps"])
        add("ua", ["ua", "µa", "microamp", "microamps"])
        add("ohm", ["ohm", "ohms", "Ω", "ω"])
        add("kohm", ["kΩ", "kω"])
        add("uf", ["uf", "µf", "mfd", "microfarad", "microfarads"])
        add("hz", ["hz"])
        add("rpm", ["rpm"])
        add("cfm", ["cfm"])
        add("btuh", ["btu", "btuh"])
        add("mbh", ["mbh"])
        add("kw", ["kw"])
        add("w", ["w", "watt", "watts"])
        add("ft", ["ft", "feet"])
        add("in", ["in", "inch", "inches"])
        add("mm", ["mm"])
        add("cm", ["cm"])
        add("lb", ["lb", "lbs", "pound", "pounds"])
        add("oz", ["oz"])
        add("kg", ["kg"])
        add("g", ["g"])
        add("s", ["s", "second", "seconds", "sec", "secs"])
        add("min", ["minute", "minutes", "min", "mins"])
        add("h", ["h", "hour", "hours", "hr", "hrs"])
        add("%", ["%", "percent"])
        return table
    }()

    private static func decimal(_ written: String) -> Decimal? {
        let plain = written.replacingOccurrences(of: ",", with: "")
        guard !plain.isEmpty else { return nil }
        return Decimal(string: plain.hasPrefix(".") ? "0" + plain : plain, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func matches(of pattern: String, in text: String, group: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: group), in: text).map { String(text[$0]) }
        }
    }
}
