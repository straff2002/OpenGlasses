import Foundation

/// Finds, in one sentence of a reply, the quantities the blind-assistance contract says must never
/// be filled in — a dose or an amount with its unit, a currency amount, a date, a clock time — and
/// says which of them the turn's reading evidence does not show (Plan NA §2).
///
/// Values are compared by value (`4.50` = `4.5`, `45` ≠ `4.5`), so a model that writes a number
/// differently from the label is not caught out. OCR confusions (`O` for `0`, `l` and `I` for `1`)
/// are folded on the evidence side only: a model that reads "5OO mg" as 500 mg is right, and the
/// reply's own text is never "corrected" into agreement. A value the wearer's own question said is
/// accepted. Numbers written as words are read in English only; digits in every language.
/// Frequencies ("twice daily") are not checked: they are words, and "twice" is not a quantity
/// the evidence's numbers could confirm.
///
/// Pure. Never sees a sentence it is not handed, and hands nothing on but the quantities' kinds.
enum ReadingQuantityReader {

    enum Kind: String, CaseIterable, Sendable {
        case dose
        case currency
        case date
        case time
    }

    struct Quantity: Equatable, Sendable {
        let kind: Kind
        /// Every number the quantity is made of: a dose's amount, a date's day and year, a time's
        /// hour and minutes.
        let values: [Decimal]
        /// A date written with a month name: the month's number.
        let month: Int?
    }

    // MARK: - Entry points

    /// The quantities in `sentence`. `english` turns on number words and month names.
    static func quantities(in sentence: String, english: Bool) -> [Quantity] {
        let text = ReplyPhraseMechanics.normalised(sentence)
        var taken: [NSRange] = []
        var found: [Quantity] = []

        func scan(_ regex: NSRegularExpression?, _ make: (NSTextCheckingResult) -> Quantity?) {
            guard let regex else { return }
            let full = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: full)
            where !taken.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                guard let quantity = make(match), !quantity.values.isEmpty || quantity.month != nil else { continue }
                taken.append(match.range)
                found.append(quantity)
            }
        }
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        func whole(_ match: NSTextCheckingResult) -> String { group(match, 0) ?? "" }

        // Dates first: a date is made of numbers a dose or a time pattern would also take.
        if english {
            scan(Patterns.monthFirstDate) { match in
                Quantity(kind: .date, values: numberValues(in: whole(match).replacingOccurrences(of: monthWordPattern, with: " ", options: .regularExpression)),
                         month: group(match, 1).flatMap(monthNumber))
            }
            scan(Patterns.dayFirstDate) { match in
                Quantity(kind: .date, values: numberValues(in: whole(match).replacingOccurrences(of: monthWordPattern, with: " ", options: .regularExpression)),
                         month: group(match, 2).flatMap(monthNumber))
            }
        }
        for pattern in Patterns.numericDates {
            // "12.05.2026" is three numbers, not 12.05 and 2026.
            scan(pattern) {
                Quantity(kind: .date,
                         values: numberValues(in: whole($0).replacingOccurrences(of: #"[./\-]"#, with: " ",
                                                                                 options: .regularExpression)),
                         month: nil)
            }
        }
        for pattern in Patterns.times {
            // "5.30 pm" is five thirty, not 5.3: a time's separator splits it into hour and minutes.
            scan(pattern) {
                Quantity(kind: .time, values: numberValues(in: whole($0).replacingOccurrences(of: ".", with: ":")),
                         month: nil)
            }
        }
        for pattern in Patterns.currencies {
            scan(pattern) { Quantity(kind: .currency, values: numberValues(in: whole($0)), month: nil) }
        }
        scan(Patterns.dose) { Quantity(kind: .dose, values: numberValues(in: group($0, 1) ?? ""), month: nil) }
        if english {
            scan(Patterns.wordDose) { match in
                wordValue(group(match, 1) ?? "").map { Quantity(kind: .dose, values: [$0], month: nil) }
            }
            scan(Patterns.wordCurrency) { match in
                wordValue(group(match, 1) ?? "").map { Quantity(kind: .currency, values: [$0], month: nil) }
            }
        }
        return found
    }

    /// The quantities in `sentence` the evidence does not show and the question did not say.
    static func ungrounded(in sentence: String, evidence: ReadingEvidence, question: String?,
                           english: Bool) -> [Quantity] {
        let asked = question.map { numberValues(in: ReplyPhraseMechanics.normalised($0)) } ?? []
        let askedText = question.map(ReplyPhraseMechanics.normalised) ?? ""
        return quantities(in: sentence, english: english).filter { quantity in
            let valuesShown = quantity.values.allSatisfy { evidence.contains($0) || asked.contains($0) }
            let monthShown = quantity.month.map { evidence.namesMonth($0) || text(askedText, namesMonth: $0) } ?? true
            return !(valuesShown && monthShown)
        }
    }

    // MARK: - Numbers

    /// Every number in `text`, by value. A thousands comma (`1,200`) reads as one number; a comma
    /// before one or two digits (`4,5`) is a decimal comma. `9:30` is two numbers.
    static func numberValues(in text: String) -> [Decimal] {
        guard let regex = Patterns.number else { return [] }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: full).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return decimal(String(text[range]))
        }
    }

    /// The evidence side's reading: every way a number in the recognised text could be read.
    /// The reply's parser, `ManualReadingCheck`'s, and every bare run of digits, so a label's
    /// "EXP03/2026" (a letter against the digits) still offers 3 and 2026.
    static func evidenceValues(in folded: String) -> [Decimal] {
        var values = numberValues(in: folded)
        values += ManualReadingCheck.numbers(in: folded)
        var run = ""
        for char in folded + " " {
            if char.isASCII, char.isNumber {
                run.append(char)
            } else if !run.isEmpty {
                if let value = decimal(run) { values.append(value) }
                run = ""
            }
        }
        var unique: [Decimal] = []
        for value in values where !unique.contains(value) { unique.append(value) }
        return unique
    }

    private static func decimal(_ written: String) -> Decimal? {
        var plain = written
        if plain.range(of: #"^\d{1,3}(,\d{3})+(\.\d+)?$"#, options: .regularExpression) != nil {
            plain = plain.replacingOccurrences(of: ",", with: "")
        } else {
            plain = plain.replacingOccurrences(of: ",", with: ".")
        }
        guard !plain.isEmpty else { return nil }
        return Decimal(string: plain, locale: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: - OCR folding (evidence side only)

    /// `O`/`o` read as `0`, and `l`, `I`, `|` read as `1`, wherever they touch a digit (or a
    /// character already folded), so "5OO mg" is 500 mg and "l2" is 12. A letter that touches no
    /// digit is left alone: "ml" stays "ml".
    static func foldOCR(_ text: String) -> String {
        var chars = Array(text)
        let zero: Set<Character> = ["o", "O"]
        // The evidence is lowercased before it is folded; the capitals are here for a caller that
        // folds raw text.
        let one: Set<Character> = ["l", "I", "|", "i"]
        func isDigitish(_ index: Int) -> Bool {
            index >= 0 && index < chars.count && chars[index].isASCII && chars[index].isNumber
        }
        var changed = true
        while changed {
            changed = false
            for index in chars.indices where zero.contains(chars[index]) || one.contains(chars[index]) {
                guard isDigitish(index - 1) || isDigitish(index + 1) else { continue }
                // A letter inside a word ("oil", "mild") is a letter: fold only where the
                // neighbour on the other side is not a letter of its own.
                let before = index > 0 ? chars[index - 1] : " "
                let after = index + 1 < chars.count ? chars[index + 1] : " "
                let lettersAround = [before, after].filter {
                    $0.isLetter && !zero.contains($0) && !one.contains($0)
                }
                guard lettersAround.isEmpty else { continue }
                chars[index] = zero.contains(chars[index]) ? "0" : "1"
                changed = true
            }
        }
        return String(chars)
    }

    // MARK: - Months

    private static let months: [(names: [String], number: Int)] = [
        (["january", "jan"], 1), (["february", "feb"], 2), (["march", "mar"], 3),
        (["april", "apr"], 4), (["may"], 5), (["june", "jun"], 6), (["july", "jul"], 7),
        (["august", "aug"], 8), (["september", "sept", "sep"], 9), (["october", "oct"], 10),
        (["november", "nov"], 11), (["december", "dec"], 12),
    ]

    private static let monthWordPattern =
        #"\b(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)\b\.?"#

    static func monthNumber(_ word: String) -> Int? {
        let clean = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return months.first(where: { $0.names.contains(clean) })?.number
    }

    /// Whether `text` (already lowercased) names `month` by a word.
    static func text(_ text: String, namesMonth month: Int) -> Bool {
        guard let entry = months.first(where: { $0.number == month }) else { return false }
        return entry.names.contains { name in
            text.range(of: #"(?<![a-z])"# + name + #"(?![a-z])"#, options: .regularExpression) != nil
        }
    }

    // MARK: - Number words (English)

    private static let smallNumbers: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Longest first, so "nineteen" is never read as "nine" and a stray "teen".
    private static let numberWordAlternation = (Array(smallNumbers.keys) + ["hundred", "thousand"])
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        .joined(separator: "|")

    /// "five hundred" → 500, "twenty-five" → 25, "one thousand two hundred" → 1200. Nil for
    /// anything that is not a whole number in words.
    static func wordValue(_ words: String) -> Decimal? {
        let tokens = words.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .map(String.init)
            .filter { $0 != "and" }
        guard !tokens.isEmpty else { return nil }
        var total = 0
        var current = 0
        for token in tokens {
            if let small = smallNumbers[token] {
                current += small
            } else if token == "hundred" {
                current = max(current, 1) * 100
            } else if token == "thousand" {
                total += max(current, 1) * 1000
                current = 0
            } else {
                return nil
            }
        }
        return Decimal(total + current)
    }

    // MARK: - Patterns

    private enum Patterns {
        static func make(_ source: String) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: source, options: [.caseInsensitive])
        }

        static let numberSource = #"\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+|,\d{1,2}(?!\d))?"#
        static let number = make(numberSource)

        /// Units of a dose or an amount, longest first so "milligrams" wins over "mg" wins over
        /// "g". A few Spanish and Japanese spellings beside the symbols every language uses.
        static let unitSource = [
            "international units?", "milligrams?", "micrograms?", "millilit(?:re|er)s?",
            "kilograms?", "grams?", "lit(?:re|er)s?", "per ?cent", "units?", "mmol/l", "mmol",
            "mcg", "µg", "μg", "ug", "mg", "ml", "kg", "iu", "g", "l", "%",
            "miligramos?", "mililitros?", "gramos?", "unidades", "por ciento",
            "ミリグラム", "ミリリットル", "グラム", "錠",
        ].joined(separator: "|")

        static let englishUnitWords = [
            "international units?", "milligrams?", "micrograms?", "millilit(?:re|er)s?",
            "kilograms?", "grams?", "lit(?:re|er)s?", "per ?cent", "units?", "mg", "ml", "mcg",
        ].joined(separator: "|")

        /// A number, then its unit. Not after a Latin letter or a digit ("x500mg" is a model
        /// number), and the unit not followed by a Latin letter ("5 go" is not five grams).
        static let dose = make(#"(?<![a-z\d.,])("# + numberSource + #")\s?(?:"# + unitSource + #")(?![a-z])"#)

        static let currencyWords = "dollars?|pounds?|euros?|cents?|pence|usd|gbp|eur|nzd|aud|cad|pesos?|dólares|円|ドル"

        static let currencies: [NSRegularExpression?] = [
            make(#"[$£€¥₹]\s?(?:"# + numberSource + #")"#),
            make(#"(?<![a-z\d.,])(?:"# + numberSource + #")\s?(?:"# + currencyWords + #")(?![a-z])"#),
        ]

        static let wordDose = make(#"\b((?:(?:"# + numberWordAlternation + #")(?:[\s-]+(?:and[\s-]+)?)?)+)\s*(?:"# + englishUnitWords + #")\b"#)
        static let wordCurrency = make(#"\b((?:(?:"# + numberWordAlternation + #")(?:[\s-]+(?:and[\s-]+)?)?)+)\s*(?:dollars?|pounds?|euros?|cents|pence)\b"#)

        static let monthSource = #"(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)\.?"#
        /// "March 5", "March 5th, 2026", "March 2026".
        static let monthFirstDate = make(#"\b"# + monthSource + #"\s+(?:\d{1,2}(?:st|nd|rd|th)?(?:,?\s+\d{4})?|\d{4})\b"#)
        /// "5 March", "5th of March 2026".
        static let dayFirstDate = make(#"\b(\d{1,2}(?:st|nd|rd|th)?)\s+(?:of\s+)?"# + monthSource + #"(?:,?\s+\d{4})?\b"#)

        static let numericDates: [NSRegularExpression?] = [
            make(#"(?<![\d.])\d{4}[/.\-]\d{1,2}[/.\-]\d{1,2}(?![\d])"#),
            make(#"(?<![\d.])\d{1,2}[/.\-]\d{1,2}[/.\-]\d{2,4}(?![\d])"#),
            // Month/year, as an expiry is printed ("03/26", "03/2026").
            make(#"(?<![\d./])\d{1,2}/\d{2,4}(?![\d/])"#),
            // 2026年3月5日, 3月5日.
            make(#"\d{1,4}\s*年(?:\s*\d{1,2}\s*月)?(?:\s*\d{1,2}\s*日)?|\d{1,2}\s*月\s*\d{1,2}\s*日"#),
        ]

        static let times: [NSRegularExpression?] = [
            make(#"(?<![\d.])\d{1,2}:\d{2}(?:\s?(?:am|pm|a\.m\.|p\.m\.))?(?![\d])"#),
            make(#"(?<![\d.:])\d{1,2}(?:\.\d{2})?\s?(?:am|pm|a\.m\.|p\.m\.)(?![a-z])"#),
            make(#"\d{1,2}\s*時(?:\s*\d{1,2}\s*分)?"#),
        ]
    }
}
