import Foundation

/// How an answer reached the app (Plan MN §5). It is the `Provenance.method` of the answer's field
/// in the record. A camera reading (Plan GX) adds `camera` later.
enum ProcedureAnswerMethod: String, Codable, CaseIterable {
    case typed, spoken, lens, scanned, photo
}

/// Whether a reading is inside the step's `spec` (§1). Absent when the answer has no spec.
enum SpecStatus: String, Codable {
    case `in`
    case out
}

/// One answer as the app read it (Plan MN §1): what was entered, kept as entered, and the value
/// the rules compare. A number is an exact `Decimal` rounded to the step's places, never a `Double`.
struct ProcedureAnswerValue: Equatable {
    let kind: StepAnswer.Kind
    /// What was typed, said or scanned, trimmed. For photos, the ids joined by commas.
    let entered: String
    /// A number, rounded to the step's `decimals`.
    let number: Decimal?
    /// A choice option id, or "yes" / "no".
    let option: String?
    /// Text or a code, as kept.
    let text: String?
    /// Job photo ids, for a photo answer.
    let photoIds: [String]
    let specStatus: SpecStatus?

    init(kind: StepAnswer.Kind, entered: String, number: Decimal? = nil, option: String? = nil,
         text: String? = nil, photoIds: [String] = [], specStatus: SpecStatus? = nil) {
        self.kind = kind
        self.entered = entered
        self.number = number
        self.option = option
        self.text = text
        self.photoIds = photoIds
        self.specStatus = specStatus
    }

    /// The value with its unit, as the record prints it: "4.60 pH", "Good", "yes", "2 photos".
    func display(for answer: StepAnswer) -> String {
        switch kind {
        case .number:
            let value = number.map { ExactDecimal.text($0, places: answer.places) } ?? entered
            return answer.unit.map { "\(value) \($0)" } ?? value
        case .choice, .yesNo:
            return option.map(answer.optionLabel) ?? entered
        case .text, .code:
            return text ?? entered
        case .photo:
            return photoIds.count == 1 ? "1 photo" : "\(photoIds.count) photos"
        }
    }

    /// The value alone, without a unit: "4.60", an option id, the text.
    func valueText(for answer: StepAnswer) -> String {
        switch kind {
        case .number: return number.map { ExactDecimal.text($0, places: answer.places) } ?? entered
        case .choice, .yesNo: return option ?? entered
        case .text, .code: return text ?? entered
        case .photo: return photoIds.joined(separator: ",")
        }
    }
}

/// What reading an answer produced.
enum AnswerReading: Equatable {
    /// Read; the caller records it.
    case accepted(ProcedureAnswerValue)
    /// Not read, or not plausible: say this and ask again. Nothing is recorded (decision 1).
    case askAgain(String)
}

/// Reads a typed, spoken or scanned answer for a step (Plan MN §1). Pure and deterministic: the
/// same text, answer and locale always read the same way, and nothing here guesses.
enum AnswerReader {

    /// Read `raw` as an answer of `answer`'s kind. `locale` decides the decimal separator: "4,2"
    /// is four point two where the locale writes a decimal comma, and is asked again where it
    /// does not.
    static func read(_ raw: String, for answer: StepAnswer,
                     locale: Locale = .current) -> AnswerReading {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kind = answer.kind else {
            return .askAgain("This step's answer is of a kind this version of the app doesn't read.")
        }
        guard !trimmed.isEmpty || kind == .photo else {
            return .askAgain("I didn't catch the \(answer.displayLabel). \(prompt(for: answer))")
        }
        switch kind {
        case .number: return readNumber(trimmed, for: answer, locale: locale)
        case .choice: return readChoice(trimmed, for: answer)
        case .yesNo: return readYesNo(trimmed, for: answer)
        case .text: return readText(trimmed, for: answer)
        case .code: return readCode(trimmed, for: answer)
        case .photo:
            let ids = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return readPhotos(ids, for: answer)
        }
    }

    /// Photos are attached through the job photo path and listed here by id (§5). They are
    /// evidence, never assessed.
    static func readPhotos(_ ids: [String], for answer: StepAnswer) -> AnswerReading {
        var seen = Set<String>()
        let unique = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        let bounds = answer.photoBounds
        if unique.count < bounds.min {
            let needed = bounds.min == 1 ? "a photo" : "\(bounds.min) photos"
            return .askAgain("This step needs \(needed); \(unique.count == 0 ? "none" : "\(unique.count)") taken so far.")
        }
        if unique.count > bounds.max {
            return .askAgain("This step takes at most \(bounds.max) photo\(bounds.max == 1 ? "" : "s"); \(unique.count) were given.")
        }
        return .accepted(ProcedureAnswerValue(kind: .photo, entered: unique.joined(separator: ","),
                                              photoIds: unique))
    }

    /// One line asking for the answer, for a re-ask and for the voice loop: "Say or type the pH."
    static func prompt(for answer: StepAnswer) -> String {
        switch answer.kind {
        case .choice:
            let labels = (answer.options ?? []).map(\.label)
            return "Say one of: \(labels.joined(separator: ", "))."
        case .yesNo: return "Say yes or no."
        case .photo: return "Take the photo for this step."
        case .code: return "Scan or type the code."
        default: return "Say or type the \(answer.displayLabel)."
        }
    }

    // MARK: - Number

    /// The result of finding a number in text.
    enum NumberText: Equatable {
        case number(Decimal)
        case none
        /// More than one number, or a separator the locale does not use as a decimal point.
        case unclear(String)
    }

    private static func readNumber(_ text: String, for answer: StepAnswer, locale: Locale) -> AnswerReading {
        let label = answer.displayLabel
        let parsed: Decimal
        switch number(in: text, locale: locale) {
        case .number(let value): parsed = value
        case .none: return .askAgain("I need a number for the \(label). \(prompt(for: answer))")
        case .unclear(let why): return .askAgain("\(why) \(prompt(for: answer))")
        }
        let value = ExactDecimal.rounded(parsed, places: answer.places)
        if let plausible = answer.plausibleRange, !plausible.contains(value) {
            // Decision 1: outside what a reading can be at all is taken as misheard or mistyped.
            return .askAgain("\(label) \(ExactDecimal.text(value))? That's outside what it can read "
                             + "(\(ExactDecimal.text(plausible.lowerBound)) to \(ExactDecimal.text(plausible.upperBound))). Read it again.")
        }
        let status: SpecStatus? = answer.specRange.map { $0.contains(value) ? .in : .out }
        return .accepted(ProcedureAnswerValue(kind: .number, entered: text, number: value, specStatus: status))
    }

    /// The one number in `text`: digits ("4.2", "4,2" by locale, "-1.5"), digits joined by a
    /// spoken "point" ("4 point 2"), or words ("four point two", `SpokenNumber`).
    static func number(in text: String, locale: Locale = .current) -> NumberText {
        let separator = locale.decimalSeparator ?? "."
        var working = text.replacingOccurrences(of: "\u{2212}", with: "-")
        // "4 point 2", as some recognisers write a spoken decimal.
        working = working.replacingOccurrences(of: #"(\d+)\s+point\s+(\d+)"#, with: "$1.$2",
                                               options: [.regularExpression, .caseInsensitive])
        let pattern = #"(?<![A-Za-z])[-+]?\d[\d.,]*"#
        let tokens = matches(of: pattern, in: working)
        if tokens.isEmpty {
            guard let spoken = SpokenNumber.decimal(in: working) else { return .none }
            switch spoken {
            case .number(let digits):
                return ExactDecimal.parse(digits).map(NumberText.number) ?? .none
            case .several:
                return .unclear("I heard more than one number.")
            }
        }
        guard tokens.count == 1, var token = tokens.first else { return .unclear("I heard more than one number.") }
        while let last = token.last, last == "." || last == "," { token.removeLast() }
        guard let normalised = normalise(token, decimalSeparator: separator) else {
            return .unclear("I couldn't tell where the decimal point is in \(token).")
        }
        let negative = !normalised.hasPrefix("-") && Self.saysNegative(before: tokens[0], in: working)
        guard let value = ExactDecimal.parse(negative ? "-" + normalised : normalised) else {
            return .unclear("I couldn't read \(token) as a number.")
        }
        return .number(value)
    }

    /// Digits with the locale's separators turned into plain "1234.5". Nil when a separator is one
    /// the locale doesn't use as a decimal point and isn't a thousands group.
    static func normalise(_ token: String, decimalSeparator: String) -> String? {
        var t = token
        if t.hasPrefix("+") { t.removeFirst() }
        let hasComma = t.contains(","), hasDot = t.contains(".")
        let commaGroups = #"^-?\d{1,3}(,\d{3})+(\.\d+)?$"#
        let dotGroups = #"^-?\d{1,3}(\.\d{3})+(,\d+)?$"#
        if decimalSeparator == "," {
            if hasDot && (hasComma || t.range(of: dotGroups, options: .regularExpression) != nil) {
                guard t.range(of: dotGroups, options: .regularExpression) != nil else { return nil }
                t = t.replacingOccurrences(of: ".", with: "")
            }
            t = t.replacingOccurrences(of: ",", with: ".")
        } else {
            if hasComma {
                guard t.range(of: commaGroups, options: .regularExpression) != nil else { return nil }
                t = t.replacingOccurrences(of: ",", with: "")
            }
        }
        return t.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil ? t : nil
    }

    private static func saysNegative(before token: String, in text: String) -> Bool {
        guard let range = text.range(of: token) else { return false }
        let before = text[..<range.lowerBound].lowercased()
        let words = before.split { !$0.isLetter }.map(String.init)
        guard let last = words.last else { return false }
        return last == "minus" || last == "negative"
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    // MARK: - Choice, yes/no, text, code

    private static func readChoice(_ text: String, for answer: StepAnswer) -> AnswerReading {
        let options = answer.options ?? []
        var says: [String: [String]] = [:]
        for option in options { says[option.id] = [option.label] + (option.says ?? []) }
        let phrase = text.trimmingCharacters(in: .punctuationCharacters)
        guard let id = CaptureFlowRunner.resolveOption(phrase, options: options.map(\.id), says: says) else {
            return .askAgain("I didn't catch which one. \(prompt(for: answer))")
        }
        return .accepted(ProcedureAnswerValue(kind: .choice, entered: text, option: id))
    }

    /// The fixed words for yes and no (§1). A phrase with words from both lists ("not done") or
    /// from neither is asked again.
    static let yesWords: Set<String> = ["yes", "yeah", "yep", "yup", "y", "done", "pass", "passed",
                                        "ok", "okay", "correct"]
    static let noWords: Set<String> = ["no", "nope", "n", "fail", "failed", "not", "didn't", "didnt",
                                       "isn't", "isnt", "wasn't", "wasnt"]

    private static func readYesNo(_ text: String, for answer: StepAnswer) -> AnswerReading {
        let words = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0 == "'") }
            .map(String.init)
        let saysYes = words.contains(where: yesWords.contains)
        let saysNo = words.contains(where: noWords.contains)
        guard saysYes != saysNo else {
            return .askAgain("I need a plain yes or no for the \(answer.displayLabel).")
        }
        return .accepted(ProcedureAnswerValue(kind: .yesNo, entered: text, option: saysYes ? "yes" : "no"))
    }

    private static func readText(_ text: String, for answer: StepAnswer) -> AnswerReading {
        let bounds = answer.textBounds
        if text.count < bounds.min {
            return .askAgain("That's shorter than the \(answer.displayLabel) needs (at least \(bounds.min) characters).")
        }
        if text.count > bounds.max {
            return .askAgain("That's longer than the \(answer.displayLabel) takes (at most \(bounds.max) characters).")
        }
        return .accepted(ProcedureAnswerValue(kind: .text, entered: text, text: text))
    }

    private static func readCode(_ text: String, for answer: StepAnswer) -> AnswerReading {
        let status: SpecStatus?
        if let expected = answer.expected, !expected.isEmpty {
            status = squeezed(expected) == squeezed(text) ? .in : .out
        } else {
            status = nil
        }
        return .accepted(ProcedureAnswerValue(kind: .code, entered: text, text: text, specStatus: status))
    }

    private static func squeezed(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }
}

/// English number words read as a decimal (Plan MN §1): "four point two" → "4.2", "minus twelve" →
/// "-12", "one hundred and five" → "105". Pure. Beside `SpokenNumber.read`, which finds a whole
/// number where it starts in a sentence for a page or a table; this reads the one number a reading
/// was said as, with its decimals and sign. Other languages are read from digits, which is what
/// on-device recognition writes for them.
extension SpokenNumber {
    enum DecimalResult: Equatable {
        case number(String)
        /// Two separate runs of number words.
        case several
    }

    private static let decimalUnits: [String: Int] = [
        "zero": 0, "oh": 0, "o": 0, "nought": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let decimalTens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]

    /// The one number spoken in `text`, as plain digits. Nil when there is none.
    static func decimal(in text: String) -> DecimalResult? {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        var runs: [[String]] = []
        var current: [String] = []
        for (index, word) in words.enumerated() {
            if isNumberWord(word, previous: current.last, next: index + 1 < words.count ? words[index + 1] : nil) {
                current.append(word)
            } else if !current.isEmpty {
                runs.append(current); current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        // A run that is only a sign or "and" or "point" is no number.
        let numeric = runs.filter { run in run.contains { decimalUnits[$0] != nil || decimalTens[$0] != nil } }
        guard !numeric.isEmpty else { return nil }
        guard numeric.count == 1, let digits = digits(numeric[0]) else { return .several }
        return .number(digits)
    }

    private static func isNumberWord(_ word: String, previous: String?, next: String?) -> Bool {
        if word == "o" || word == "oh" {
            // Only a zero after "point" or another digit word: "four point oh five".
            return previous != nil
        }
        if decimalUnits[word] != nil || decimalTens[word] != nil { return true }
        if word == "hundred" || word == "thousand" { return previous != nil }
        // "point" only before a digit word: "point five", "four point two".
        if word == "point" { return next.map { decimalUnits[$0] != nil || decimalTens[$0] != nil } ?? false }
        if word == "minus" || word == "negative" { return next.map { decimalUnits[$0] != nil || decimalTens[$0] != nil } ?? false }
        if word == "and" { return previous != nil && (previous == "hundred" || previous == "thousand") }
        return false
    }

    private static func digits(_ run: [String]) -> String? {
        var negative = false
        var words = run[...]
        if let first = words.first, first == "minus" || first == "negative" {
            negative = true; words = words.dropFirst()
        }
        var whole: [String] = []
        var fraction: [String] = []
        var seenPoint = false
        for word in words {
            if word == "point" {
                guard !seenPoint else { return nil }
                seenPoint = true
            } else if seenPoint {
                fraction.append(word)
            } else {
                whole.append(word)
            }
        }
        if seenPoint && fraction.isEmpty { return nil }
        let wholeText: String
        if whole.isEmpty {
            guard seenPoint else { return nil }
            wholeText = "0"
        } else {
            guard let value = integer(whole) else { return nil }
            wholeText = String(value)
        }
        var text = wholeText
        if seenPoint {
            guard let fractionDigits = fractionDigits(fraction) else { return nil }
            text += "." + fractionDigits
        }
        return negative ? "-" + text : text
    }

    /// "one hundred and five" → 105; "twenty one" → 21; "four" → 4.
    private static func integer(_ words: [String]) -> Int? {
        var total = 0
        var current = 0
        var sawValue = false
        for word in words {
            if let value = decimalUnits[word] {
                current += value; sawValue = true
            } else if let value = decimalTens[word] {
                current += value; sawValue = true
            } else if word == "hundred" {
                current = Swift.max(current, 1) * 100; sawValue = true
            } else if word == "thousand" {
                total += Swift.max(current, 1) * 1000; current = 0; sawValue = true
            } else if word == "and" {
                continue
            } else {
                return nil
            }
        }
        return sawValue ? total + current : nil
    }

    /// The digits after "point": "two" → "2", "oh five" → "05", "twenty five" → "25".
    private static func fractionDigits(_ words: [String]) -> String? {
        var out = ""
        var index = 0
        while index < words.count {
            let word = words[index]
            if let ten = decimalTens[word] {
                if index + 1 < words.count, let unit = decimalUnits[words[index + 1]], unit > 0, unit < 10 {
                    out += String(ten + unit); index += 2; continue
                }
                out += String(ten)
            } else if let unit = decimalUnits[word] {
                out += String(unit)
            } else {
                return nil
            }
            index += 1
        }
        return out.isEmpty ? nil : out
    }
}
