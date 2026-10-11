import Foundation
import NaturalLanguage

/// Writes symbols out as words before text reaches a voice engine.
///
/// "22°C", "80 km/h", "5–10 min", "Settings > Voice" are display forms. What a voice makes of
/// them depends on the engine and the voice: a letter read out on its own, the sign skipped, the
/// name of the punctuation mark, or the whole thing swallowed. A reply is spoken far more often
/// than it is read here, so the words are supplied rather than left to chance. Only the copy
/// handed to the engine changes — the transcript and the in-lens text keep the symbols.
///
/// The words are English only. Another language needs its own words and its own number
/// agreement, and an English "degrees" dropped into a Spanish sentence is worse than the symbol
/// it replaced. Two things hold in every language: subscript digits (CO₂) are flattened, and
/// Markdown is taken out — the prompt asks the model not to write it, models write it anyway,
/// and an engine either reads the asterisks aloud or trips over them.
///
/// Unit abbreviations in plain letters (km, kg, mph, GB) are written out too, but only behind a
/// number: "5 km" is five kilometers, a bare "km" could be anything.
///
/// A Markdown table is read a row at a time, each cell behind its column's name.
///
/// Deliberately not here: single-letter units (m, g, s, V, A, L) and "in", which mean too many
/// other things — "5m" is metres, minutes or millions; and currency and percent signs, which
/// engines read well.
enum SpokenSymbolExpander {

    // MARK: - Entry points

    /// The copy of `text` to hand a voice engine.
    static func spokenForm(of text: String) -> String {
        // Checked first: language detection is not free, and most replies carry no symbol.
        guard needsWork(text) else { return SpeechPronunciation.spokenForm(of: text) }
        let phone = Locale.preferredLanguages.first
            .flatMap { Locale.Language(identifier: $0).languageCode?.identifier } ?? "en"
        return SpeechPronunciation.spokenForm(
            of: expand(text, languageCode: languageCode(of: text, fallback: phone)))
    }

    static func expand(_ text: String, languageCode: String) -> String {
        guard needsWork(text) else { return text }
        var result = String(text.map { subscripts[$0] ?? $0 })
        for rule in markdownRules { result = rule(result) }
        if languageCode == "en" {
            for rule in englishRules { result = rule(result) }
        }
        // The rules pad their words with spaces; where a symbol already had one, two are left.
        return result == text ? text : tidied(result)
    }

    /// The language a reply is written in, which is not always the phone's: the model answers in
    /// the language it was asked in. A reply too short or too mixed to call falls back to the
    /// phone's first language.
    static func languageCode(of text: String, fallback: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.6 {
            return best.key.rawValue
        }
        return fallback
    }

    // MARK: - Tables

    private static let triggers = CharacterSet(charactersIn: "°℃℉×÷±≈≤≥≠→›><~–—&#½¼¾²³µμΩ/₀₁₂₃₄₅₆₇₈₉*_`[•|")

    /// A "- item" or "+ item" line: the one piece of Markdown made only of characters that are
    /// too common to be triggers.
    private static let bulletTrigger = try! NSRegularExpression(pattern: #"(?m)^[ \t]*[-+][ \t]+\S"#)

    private static let subscripts: [Character: Character] = [
        "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4",
        "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9",
    ]

    /// Units that carry a symbol, as (one, many). Longest first where one is a prefix of another.
    private static let units: [(symbol: String, one: String, many: String)] = [
        ("km/h", "kilometer per hour", "kilometers per hour"),
        ("m/s", "meter per second", "meters per second"),
        ("km²", "square kilometer", "square kilometers"),
        ("cm²", "square centimeter", "square centimeters"),
        ("mm²", "square millimeter", "square millimeters"),
        ("ft²", "square foot", "square feet"),
        ("m²", "square meter", "square meters"),
        ("cm³", "cubic centimeter", "cubic centimeters"),
        ("ft³", "cubic foot", "cubic feet"),
        ("m³", "cubic meter", "cubic meters"),
        ("µF", "microfarad", "microfarads"), ("μF", "microfarad", "microfarads"),
        ("µm", "micrometer", "micrometers"), ("μm", "micrometer", "micrometers"),
        ("µg", "microgram", "micrograms"), ("μg", "microgram", "micrograms"),
        ("µA", "microamp", "microamps"), ("μA", "microamp", "microamps"),
        ("kΩ", "kilohm", "kilohms"),
        ("MΩ", "megohm", "megohms"),
        ("Ω", "ohm", "ohms"),
    ]

    /// Abbreviations in plain letters, as (one, many). Matched by exact case, behind a number.
    private static let letterUnits: [(symbol: String, one: String, many: String)] = [
        // Length and speed
        ("km", "kilometer", "kilometers"), ("cm", "centimeter", "centimeters"),
        ("mm", "millimeter", "millimeters"), ("ft", "foot", "feet"), ("yd", "yard", "yards"),
        ("mi", "mile", "miles"),
        ("mph", "mile per hour", "miles per hour"),
        ("kph", "kilometer per hour", "kilometers per hour"),
        ("kmh", "kilometer per hour", "kilometers per hour"),
        // Weight and volume
        ("kg", "kilogram", "kilograms"), ("mg", "milligram", "milligrams"),
        ("lb", "pound", "pounds"), ("lbs", "pound", "pounds"), ("oz", "ounce", "ounces"),
        ("ml", "milliliter", "milliliters"), ("mL", "milliliter", "milliliters"),
        ("gal", "gallon", "gallons"),
        // Time
        ("ms", "millisecond", "milliseconds"), ("sec", "second", "seconds"),
        ("secs", "second", "seconds"), ("min", "minute", "minutes"), ("mins", "minute", "minutes"),
        ("hr", "hour", "hours"), ("hrs", "hour", "hours"),
        // Electrical, pressure, sound
        ("kWh", "kilowatt hour", "kilowatt hours"), ("kW", "kilowatt", "kilowatts"),
        ("MW", "megawatt", "megawatts"), ("kV", "kilovolt", "kilovolts"),
        ("mV", "millivolt", "millivolts"), ("mA", "milliamp", "milliamps"),
        ("Hz", "hertz", "hertz"), ("kHz", "kilohertz", "kilohertz"),
        ("MHz", "megahertz", "megahertz"), ("GHz", "gigahertz", "gigahertz"),
        ("kPa", "kilopascal", "kilopascals"), ("hPa", "hectopascal", "hectopascals"),
        ("inWC", "inch of water column", "inches of water column"),
        ("dB", "decibel", "decibels"),
        // Health
        ("bpm", "beat per minute", "beats per minute"),
        ("mmHg", "millimeter of mercury", "millimeters of mercury"),
        ("mg/dL", "milligram per deciliter", "milligrams per deciliter"),
        ("mmol/L", "millimole per liter", "millimoles per liter"),
        ("kcal", "kilocalorie", "kilocalories"),
        // Data
        ("KB", "kilobyte", "kilobytes"), ("kB", "kilobyte", "kilobytes"),
        ("MB", "megabyte", "megabytes"), ("GB", "gigabyte", "gigabytes"),
        ("TB", "terabyte", "terabytes"),
        ("kbps", "kilobit per second", "kilobits per second"),
        ("Mbps", "megabit per second", "megabits per second"),
        ("Gbps", "gigabit per second", "gigabits per second"),
    ]

    /// A number, then one of `letterUnits`, ending there: not "5 kmart", and not the first half
    /// of a compound this table does not know ("5 mg/kg").
    private static let letterUnitPattern: String = {
        let symbols = letterUnits.map(\.symbol).sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return #"(?<![\p{L}\p{N}])(\#(number))\#(gap)(\#(symbols))(?![\p{L}\p{N}/])"#
    }()
    private static let letterUnitTrigger = try! NSRegularExpression(pattern: letterUnitPattern)

    /// Whether any rule could apply. Checked before language detection, which is not free.
    private static func needsWork(_ text: String) -> Bool {
        if text.unicodeScalars.contains(where: triggers.contains) { return true }
        let whole = NSRange(location: 0, length: (text as NSString).length)
        return letterUnitTrigger.firstMatch(in: text, range: whole) != nil
            || bulletTrigger.firstMatch(in: text, range: whole) != nil
    }

    private static let number = #"[-−]?\d+(?:[.,]\d+)?"#
    private static let gap = #"[   ]?"#

    // MARK: - Markdown

    /// Markup taken out, text kept. Every language.
    private static let markdownRules: [(String) -> String] = [
        // Tables first, while their rows are still whole lines.
        { flattenedTables($0) },
        // Code fences, with their language tag. What is inside is still read.
        rule(#"(?m)^[ \t]*```[^\n]*\n?"#) { _, _ in "" },
        // [text](url) and ![alt](url): the words, not the address.
        rule(#"!?\[([^\]\n]+)\]\([^)\n]+\)"#) { groups, _ in groups[1] ?? "" },
        // A rule line: ---, ***, ___.
        rule(#"(?m)^[ \t]*([-*_])(?:[ \t]?\1){2,}[ \t]*$\n?"#) { _, _ in "" },
        // # Heading
        rule(#"(?m)^[ \t]{0,3}#{1,6}[ \t]+"#) { _, _ in "" },
        // > quoted. Not "> 5", which is a comparison.
        rule(#"(?m)^[ \t]*>[ \t]+(?=\D)"#) { _, _ in "" },
        // - item, * item, + item, • item
        rule(#"(?m)^[ \t]*[-*+•][ \t]+(?=\S)"#) { _, _ in "" },
        // **bold**, __bold__, ~~struck~~
        rule(#"(\*\*|__|~~)(?=\S)(.+?)(?<=\S)\1"#) { groups, _ in groups[2] ?? "" },
        // *italic* and _italic_. Not snake_case, and not 2*3*4.
        rule(#"(?<![\p{L}\p{N}*])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\p{L}\p{N}*])"#) { groups, _ in groups[1] ?? "" },
        rule(#"(?<![\p{L}\p{N}_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\p{L}\p{N}_])"#) { groups, _ in groups[1] ?? "" },
        // `code`
        rule(#"`+"#) { _, _ in "" },
        // Asterisks left over — an unclosed pair in a reply spoken a sentence at a time, a
        // footnote mark. Kept between two numbers, where it is a multiplication.
        rule(#"(?<![\d*])(?<!\d[ \t])\*++|\*++(?![ \t]?\d)"#) { _, _ in "" },
    ]

    // MARK: - Tables

    /// The row under a table's header: `|---|:---:|`. A rule line with no pipe in it is not one.
    private static let delimiterRow = try! NSRegularExpression(
        pattern: #"^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$"#)

    private static func isDelimiterRow(_ line: String) -> Bool {
        line.contains("|") && delimiterRow.firstMatch(
            in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    private static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// One row as a sentence: "Part: Bolt, Qty: 4." An empty cell is skipped, and a cell with no
    /// column name is read on its own.
    private static func sentence(row: [String], header: [String]) -> String {
        let parts = row.enumerated().compactMap { index, value -> String? in
            guard !value.isEmpty else { return nil }
            let name = index < header.count ? header[index] : ""
            return name.isEmpty ? value : "\(name): \(value)"
        }
        let joined = parts.joined(separator: ", ")
        guard let last = joined.last else { return "" }
        return ".!?:;".contains(last) ? joined : joined + "."
    }

    /// A table has no spoken form, but its rows do. Under a header each row is read as
    /// "Column: value, Column: value."; a row of cells with no header — which is all an utterance
    /// holds when a reply is spoken a line at a time — is read as its cells.
    private static func flattenedTables(_ text: String) -> String {
        guard text.contains("|") else { return text }
        let lines = text.components(separatedBy: "\n")
        var spoken: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if index + 1 < lines.count, line.contains("|"), !isDelimiterRow(line), isDelimiterRow(lines[index + 1]) {
                let header = cells(line)
                index += 2
                var rows = 0
                while index < lines.count, lines[index].contains("|") {
                    spoken.append(sentence(row: cells(lines[index]), header: header))
                    rows += 1
                    index += 1
                }
                if rows == 0 { spoken.append(sentence(row: header, header: [])) }
            } else if isDelimiterRow(line) {
                index += 1
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("|"),
                      line.trimmingCharacters(in: .whitespaces).hasSuffix("|"),
                      line.trimmingCharacters(in: .whitespaces).count > 1 {
                spoken.append(sentence(row: cells(line), header: []))
                index += 1
            } else {
                spoken.append(line)
                index += 1
            }
        }
        return spoken.joined(separator: "\n")
    }

    // MARK: - English

    private static let englishRules: [(String) -> String] = [
        // 22°C, -5 °F, ℃, 45°. The scale letter must end there, so "°Cool" is not Celsius.
        rule(#"(?:(\#(number))\#(gap))?(?:°[  ]?([CcFf])(?![\p{L}\p{N}])|([℃℉])|°)"#) { groups, next in
            let scale: String?
            if let letter = groups[2] {
                scale = letter.uppercased() == "C" ? "Celsius" : "Fahrenheit"
            } else if let sign = groups[3] {
                scale = sign == "℃" ? "Celsius" : "Fahrenheit"
            } else {
                scale = nil
            }
            let words = [groups[1], isOne(groups[1]) ? "degree" : "degrees", scale]
                .compactMap { $0 }.joined(separator: " ")
            // "36°50′" must not become "36 degrees50′".
            return words + (next.map(isWordCharacter) == true ? " " : "")
        },
        // 80 km/h, 12 m², 45 µF, 10 kΩ — and the same units with no number in front.
        rule(#"(?<![\p{L}\p{N}])(?:(\#(number))\#(gap))?(\#(units.map { NSRegularExpression.escapedPattern(for: $0.symbol) }.joined(separator: "|")))(?![\p{L}\p{N}])"#) { groups, _ in
            guard let symbol = groups[2], let unit = units.first(where: { $0.symbol == symbol }) else { return groups[0] ?? "" }
            guard let amount = groups[1] else { return unit.many }
            return amount + " " + (isOne(amount) ? unit.one : unit.many)
        },
        // 5 km, 72 bpm, 16 GB. After the units above, so "35 km/h" is already words.
        rule(letterUnitPattern) { groups, _ in
            guard let amount = groups[1], let symbol = groups[2],
                  let unit = letterUnits.first(where: { $0.symbol == symbol }) else { return groups[0] ?? "" }
            return amount + " " + (isOne(amount) ? unit.one : unit.many)
        },
        // 1½, 2¼ — then the fractions standing alone.
        rule(#"(\d)\#(gap)([½¼¾])"#) { groups, _ in
            (groups[1] ?? "") + " and " + (["½": "a half", "¼": "a quarter", "¾": "three quarters"][groups[2] ?? ""] ?? "")
        },
        rule(#"[½¼¾]"#) { groups, _ in
            ["½": "one half", "¼": "one quarter", "¾": "three quarters"][groups[0] ?? ""] ?? ""
        },
        // x², 5³ once the units above have taken theirs.
        rule(#"(?<=[\p{L}\p{N}])([²³])"#) { groups, next in
            (groups[1] == "²" ? " squared" : " cubed") + (next.map(isWordCharacter) == true ? " " : "")
        },
        // 5–10 minutes, 2020—2024.
        rule(#"(?<=\d)\#(gap)[–—]\#(gap)(?=\d)"#) { _, _ in " to " },
        // ~5 minutes, ≈ 20.
        rule(#"~(?=\d)"#) { _, _ in "about " },
        rule(#"[ \t]*≈[ \t]*"#) { _, _ in " approximately " },
        // Arithmetic and comparison.
        rule(#"[ \t]*×[ \t]*"#) { _, _ in " times " },
        rule(#"(?<=\d)[ \t]*\*[ \t]*(?=\d)"#) { _, _ in " times " },
        rule(#"[ \t]*÷[ \t]*"#) { _, _ in " divided by " },
        rule(#"±[ \t]*"#) { _, _ in "plus or minus " },
        rule(#"[ \t]*≤[ \t]*"#) { _, _ in " less than or equal to " },
        rule(#"[ \t]*≥[ \t]*"#) { _, _ in " greater than or equal to " },
        rule(#"[ \t]*≠[ \t]*"#) { _, _ in " not equal to " },
        rule(#"(?<=\d)[ \t]*<[ \t]*(?=\d)"#) { _, _ in " is less than " },
        rule(#"(?<=\d)[ \t]*>[ \t]*(?=\d)"#) { _, _ in " is greater than " },
        rule(#"(?<![\p{L}\p{N}])<[ \t]?(?=\d)"#) { _, _ in "less than " },
        rule(#"(?<![\p{L}\p{N}])>[ \t]?(?=\d)"#) { _, _ in "greater than " },
        // Settings > Voice, Settings › Voice: a path, read as steps. An arrow is a journey.
        rule(#"(?<=\S)[ \t]+[>›][ \t]+(?=\S)"#) { _, _ in ", then " },
        rule(#"[ \t]*→[ \t]*"#) { _, _ in " to " },
        // Services & Integrations. Left alone inside a name: AT&T, R&D.
        rule(#"(?<=[\p{L}\p{N}])[ \t]+&[ \t]+(?=[\p{L}\p{N}])"#) { _, _ in " and " },
        // #3, but not a colour or a tag.
        rule(#"(?<![\p{L}\p{N}])#(?=\d+(?![\p{L}\p{N}]))"#) { _, _ in "number " },
    ]

    // MARK: - Machinery

    /// A rule: every match of `pattern` replaced by what `words` returns for its groups (index 0
    /// is the whole match) and the character that follows it.
    private static func rule(_ pattern: String,
                             _ words: @escaping (_ groups: [String?], _ next: Character?) -> String) -> (String) -> String {
        let expression = try! NSRegularExpression(pattern: pattern)
        return { text in
            let ns = text as NSString
            let matches = expression.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return text }
            var result = ""
            var cursor = 0
            for match in matches {
                result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                cursor = match.range.location + match.range.length
                let groups = (0..<match.numberOfRanges).map { index -> String? in
                    let range = match.range(at: index)
                    return range.location == NSNotFound ? nil : ns.substring(with: range)
                }
                result += words(groups, cursor < ns.length ? ns.substring(from: cursor).first : nil)
            }
            return result + ns.substring(from: cursor)
        }
    }

    private static func isOne(_ amount: String?) -> Bool {
        amount?.trimmingCharacters(in: CharacterSet(charactersIn: "-−")) == "1"
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static let doubledSpaces = try! NSRegularExpression(pattern: #" {2,}"#)
    private static let spaceBeforeStop = try! NSRegularExpression(pattern: #" +(?=[.,;:!?](?:\s|$))"#)

    private static func tidied(_ text: String) -> String {
        var result = text
        for expression in [doubledSpaces, spaceBeforeStop] {
            result = expression.stringByReplacingMatches(
                in: result, range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: expression === doubledSpaces ? " " : "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
