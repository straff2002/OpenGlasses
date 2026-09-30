import Foundation

/// Plan GH — reads level / space / zone from the OCR lines of a car-park sign.
///
/// Pure: it takes the text the on-device OCR already produced, never pixels. Signs are noisier than
/// speech — pillar codes, height limits, exit arrows, opening hours — so every reading carries a
/// score and the parser says when it is unsure. The assistant then asks "I read level 2, space 41 —
/// right?" instead of saving a guess as fact.
///
/// Scoring, highest first: a value next to its keyword (LEVEL 2, BAY 41) → 1.0; a compact code
/// (P3, L2) → 0.85; a basement code (B2) → 0.7; a letter-and-digits code with no keyword (B12) →
/// 0.6; a number alone on its line → 0.5 as a space (0.4 as a level when it is a single digit); a
/// colour alone on its line → 0.45 as a zone.
enum ParkingSignParser {

    enum Field: String, Equatable { case level, space, zone }

    struct Candidate: Equatable {
        let field: Field
        let value: String
        let score: Double
    }

    struct Reading: Equatable {
        /// The best value per field.
        var fields: ParkingFields
        /// Every candidate found, best first.
        var candidates: [Candidate]
        /// The lowest score among the chosen fields; 0 when nothing was read.
        var confidence: Double
        /// Whether the wearer should be asked to confirm before the reading is trusted.
        var needsConfirmation: Bool

        var isEmpty: Bool { fields.level == nil && fields.space == nil && fields.zone == nil }
    }

    /// Below this, a chosen field is a guess and the reading asks for confirmation.
    static let confirmationThreshold = 0.75

    static func parse(lines: [String]) -> Reading {
        let tokens = tokenize(lines)
        var consumed = Set<Int>()
        var candidates: [Candidate] = []

        func add(_ field: Field, _ value: String, _ score: Double, consuming indices: [Int]) {
            candidates.append(Candidate(field: field, value: value, score: score))
            consumed.formUnion(indices)
        }

        // Pass 1: keyword-adjacent values, which win outright.
        for (i, token) in tokens.enumerated() where !consumed.contains(i) {
            guard i + 1 < tokens.count, !consumed.contains(i + 1) else { continue }
            let next = tokens[i + 1].text
            if levelKeywords.contains(token.text), let value = levelValue(next) {
                add(.level, value, 1.0, consuming: [i, i + 1])
            } else if token.text == "P", let n = Int(next), (0...99).contains(n) {
                add(.level, "\(n)", 0.9, consuming: [i, i + 1])
            } else if spaceKeywords.contains(token.text), let value = spaceValue(next) {
                add(.space, value, 1.0, consuming: [i, i + 1])
            } else if zoneKeywords.contains(token.text), let value = zoneValue(next) {
                add(.zone, token.text == "ROW" ? "Row \(value)" : "Zone \(value)", 1.0, consuming: [i, i + 1])
            } else if colours.contains(token.text), levelKeywords.contains(next) {
                add(.level, token.text.capitalized, 0.9, consuming: [i, i + 1])
            } else if colours.contains(token.text), zoneKeywords.contains(next) {
                add(.zone, token.text.capitalized, 1.0, consuming: [i, i + 1])
            }
        }

        // Pass 2: codes and isolated values that stand without a keyword.
        for (i, token) in tokens.enumerated() where !consumed.contains(i) {
            let text = token.text
            if let digits = ParkingUtteranceParser.firstCapture(#"^(?:P|L)(-?\d{1,2})$"#, in: text) {
                add(.level, digits, 0.85, consuming: [i])
            } else if let digit = ParkingUtteranceParser.firstCapture(#"^B(\d)$"#, in: text) {
                add(.level, "B\(digit)", 0.7, consuming: [i])
            } else if text.range(of: #"^[A-Z]{1,2}\d{2,4}$"#, options: .regularExpression) != nil {
                add(.space, text, 0.6, consuming: [i])
            } else if token.isAloneOnLine, !token.lineHasNoiseWord,
                      text.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil {
                if text.count == 1 {
                    add(.level, text, 0.4, consuming: [i])
                } else {
                    add(.space, String(Int(text) ?? 0), 0.5, consuming: [i])
                }
            } else if token.isAloneOnLine, colours.contains(text) {
                add(.zone, text.capitalized, 0.45, consuming: [i])
            }
        }

        return reading(from: candidates)
    }

    // MARK: - Choosing

    static func reading(from candidates: [Candidate]) -> Reading {
        // Stable sort: equal scores keep sign order, so the first-read value wins a tie.
        let sorted = candidates.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score
                                                           : $0.offset < $1.offset }
            .map(\.element)
        var fields = ParkingFields()
        var chosenScores: [Double] = []
        var conflict = false

        for field in [Field.level, .space, .zone] {
            let ofField = sorted.filter { $0.field == field }
            guard let best = ofField.first else { continue }
            switch field {
            case .level: fields.level = best.value
            case .space: fields.space = best.value
            case .zone: fields.zone = best.value
            }
            chosenScores.append(best.score)
            if ofField.dropFirst().contains(where: { $0.value != best.value && best.score - $0.score < 0.1 }) {
                conflict = true
            }
        }

        let confidence = chosenScores.min() ?? 0
        let needsConfirmation = chosenScores.isEmpty ? false
            : (confidence < confirmationThreshold || conflict)
        return Reading(fields: fields, candidates: sorted, confidence: confidence,
                       needsConfirmation: needsConfirmation)
    }

    // MARK: - Vocabulary

    static let levelKeywords: Set<String> = ["LEVEL", "FLOOR", "DECK", "LVL", "STOREY", "TIER"]
    static let spaceKeywords: Set<String> = ["BAY", "SPACE", "SPOT", "STALL", "SLOT", "NO", "#"]
    static let zoneKeywords: Set<String> = ["ZONE", "ROW", "SECTION", "AREA", "SECTOR", "AISLE"]
    static let colours: Set<String> = ["RED", "ORANGE", "YELLOW", "GREEN", "BLUE", "PURPLE", "PINK",
                                       "WHITE", "BLACK", "GREY", "GRAY", "BROWN", "GOLD", "SILVER",
                                       "VIOLET", "TEAL"]
    /// A line with one of these is not a bay marker, so a lone number on it is not a space.
    static let noiseWords: Set<String> = ["EXIT", "ENTRY", "ENTRANCE", "MAX", "HEIGHT", "CLEARANCE",
                                          "KM", "KMH", "MPH", "TEL", "PHONE", "OPEN", "HOURS", "LIFT",
                                          "STAIRS", "PAY", "TICKET", "SPEED", "LIMIT"]

    // MARK: - Values

    static func levelValue(_ text: String) -> String? {
        if let n = Int(text), (-9...99).contains(n) { return "\(n)" }
        if text == "G" || text == "GROUND" { return "G" }
        if text == "ROOF" || text == "ROOFTOP" { return "Roof" }
        if colours.contains(text) { return text.capitalized }
        if let digits = ParkingUtteranceParser.firstCapture(#"^(?:P|L)(-?\d{1,2})$"#, in: text) { return digits }
        if text.range(of: #"^(B\d{1,2}|[A-Z]|\d{1,2}[A-Z])$"#, options: .regularExpression) != nil { return text }
        return nil
    }

    static func spaceValue(_ text: String) -> String? {
        if let n = Int(text), n >= 0 { return "\(n)" }
        if text.range(of: #"^[A-Z]{0,2}\d{1,4}[A-Z]?$"#, options: .regularExpression) != nil { return text }
        return nil
    }

    static func zoneValue(_ text: String) -> String? {
        if let n = Int(text), n >= 0 { return "\(n)" }
        if colours.contains(text) { return text.capitalized }
        if text.range(of: #"^[A-Z]\d{0,2}$"#, options: .regularExpression) != nil { return text }
        return nil
    }

    // MARK: - Tokens

    struct Token {
        let text: String
        let line: Int
        let isAloneOnLine: Bool
        let lineHasNoiseWord: Bool
    }

    static func tokenize(_ lines: [String]) -> [Token] {
        var tokens: [Token] = []
        for (lineIndex, raw) in lines.enumerated() {
            var line = raw.uppercased()
            // Separators to spaces, but keep a decimal point inside a number ("2.1M" stays one
            // token and is ignored as a height, not read as level 2).
            line = line.replacingOccurrences(of: #"[:;,|·•→←↑↓()\[\]"']"#, with: " ", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\.(?!\d)"#, with: " ", options: .regularExpression)
            line = line.replacingOccurrences(of: "#", with: " # ")
            line = line.replacingOccurrences(of: #"(?<=[A-Z])-(?=\d)"#, with: "", options: .regularExpression)
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            let noisy = words.contains { noiseWords.contains($0) }
            for word in words {
                tokens.append(Token(text: word, line: lineIndex, isAloneOnLine: words.count == 1,
                                    lineHasNoiseWord: noisy))
            }
        }
        return tokens
    }
}
