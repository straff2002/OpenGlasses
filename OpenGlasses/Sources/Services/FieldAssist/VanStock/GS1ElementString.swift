import Foundation

/// The fields of a GS1 element string, as a carton's 2D code (Data Matrix) or GS1-128 barcode
/// carries them (Plan MY §5). Pure.
///
/// It reads the product number (AI `01`, a GTIN-14 with its check digit), the expiry (AI `17`,
/// YYMMDD), the lot (AI `10`, up to 20 characters) and the serial (AI `21`, up to 20), in any
/// order, with the FNC1 separator (ASCII 29, GS) ending a variable-length field. A few other
/// healthcare AIs are read only so they can be stepped over. It refuses rather than guesses: a bad
/// check digit, an impossible date, a truncated or overlong field, an AI given twice, or an AI it
/// does not know (whose length it cannot know) refuses the whole code.
struct GS1ElementString: Equatable, Sendable {
    /// The GTIN-14, check digit included.
    var gtin: String?
    var expiry: StockDay?
    /// Exactly as encoded.
    var lot: String?
    var serial: String?

    enum Failure: Error, Equatable, Sendable {
        case empty
        /// An AI this reader does not know, so where its field ends cannot be known.
        case unknownAI(String)
        /// A field cut off before its length.
        case truncated(ai: String)
        /// A variable-length field longer than GS1 allows: usually a missing separator.
        case tooLong(ai: String)
        /// A numeric field with something other than digits in it.
        case notDigits(ai: String)
        case badCheckDigit
        case impossibleDate(ai: String)
        case repeatedAI(String)
        /// A field with a control character or nothing in it.
        case badCharacters(ai: String)

        /// Why, in a few English words for the model.
        var sentence: String {
            switch self {
            case .empty: return "the code is empty"
            case .unknownAI(let ai): return "it holds a field (\(ai)) this reader does not know"
            case .truncated(let ai): return "field \(ai) is cut short"
            case .tooLong(let ai): return "field \(ai) is longer than it may be"
            case .notDigits(let ai): return "field \(ai) should be digits only"
            case .badCheckDigit: return "the product number's check digit is wrong"
            case .impossibleDate(let ai): return "field \(ai) is not a real date"
            case .repeatedAI(let ai): return "field \(ai) appears twice"
            case .badCharacters(let ai): return "field \(ai) holds characters a label cannot"
            }
        }
    }

    /// The group separator that stands for FNC1 between fields.
    static let groupSeparator: Character = "\u{1D}"

    /// How a field is read.
    private enum Field {
        case fixed(Int, numeric: Bool)
        case variable(max: Int, numeric: Bool)
    }

    /// The AIs this reader knows. The four the plan names, and the common healthcare ones it
    /// steps over so a real carton is not refused for carrying them.
    private static let known: [String: Field] = [
        "00": .fixed(18, numeric: true),    // SSCC
        "01": .fixed(14, numeric: true),    // GTIN
        "02": .fixed(14, numeric: true),    // GTIN of contained items
        "10": .variable(max: 20, numeric: false), // lot
        "11": .fixed(6, numeric: true),     // production date
        "13": .fixed(6, numeric: true),     // packaging date
        "15": .fixed(6, numeric: true),     // best before
        "16": .fixed(6, numeric: true),     // sell by
        "17": .fixed(6, numeric: true),     // expiry
        "21": .variable(max: 20, numeric: false), // serial
        "30": .variable(max: 8, numeric: true),   // count
        "240": .variable(max: 30, numeric: false), // additional product id
        "241": .variable(max: 30, numeric: false), // customer part number
        "710": .variable(max: 20, numeric: false), // national healthcare reimbursement numbers
        "711": .variable(max: 20, numeric: false),
        "712": .variable(max: 20, numeric: false),
        "713": .variable(max: 20, numeric: false),
        "714": .variable(max: 20, numeric: false),
        "715": .variable(max: 20, numeric: false),
    ]

    /// Symbology identifiers a scanner may put in front: Data Matrix, GS1-128, QR, DotCode.
    private static let symbologyPrefixes = ["]d2", "]C1", "]Q3", "]J1", "]e0"]

    /// Read `raw`. Two-digit years are placed in a century by GS1's own rule: within 49 years
    /// ahead of `referenceYear` or 50 behind.
    static func parse(_ raw: String, referenceYear: Int) -> Result<GS1ElementString, Failure> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The human-readable form, "(01)…(17)…(10)…", as a label prints it under the code and as
        // `scan_code` hands it on: each field is bracketed, so no separator can be lost on the way.
        if trimmed.hasPrefix("(") {
            guard let unbracketed = unbracketed(trimmed) else { return .failure(.unknownAI(String(trimmed.prefix(4)))) }
            return parse(unbracketed, referenceYear: referenceYear)
        }
        var text = Substring(trimmed)
        for prefix in symbologyPrefixes where text.hasPrefix(prefix) {
            text = text.dropFirst(prefix.count)
            break
        }
        while text.first == groupSeparator { text = text.dropFirst() }
        guard !text.isEmpty else { return .failure(.empty) }

        var result = GS1ElementString()
        var seen: Set<String> = []
        while !text.isEmpty {
            guard let (ai, field) = aiAt(text) else {
                return .failure(.unknownAI(String(text.prefix(2))))
            }
            text = text.dropFirst(ai.count)
            guard !seen.contains(ai) else { return .failure(.repeatedAI(ai)) }
            seen.insert(ai)

            let value: Substring
            switch field {
            case .fixed(let length, _):
                guard text.count >= length else { return .failure(.truncated(ai: ai)) }
                value = text.prefix(length)
                text = text.dropFirst(length)
                // Some encoders put a separator after a fixed field too.
                if text.first == groupSeparator { text = text.dropFirst() }
            case .variable(let max, _):
                let end = text.firstIndex(of: groupSeparator) ?? text.endIndex
                value = text[text.startIndex..<end]
                text = end == text.endIndex ? text[end...] : text[text.index(after: end)...]
                guard !value.isEmpty else { return .failure(.truncated(ai: ai)) }
                guard value.count <= max else { return .failure(.tooLong(ai: ai)) }
            }
            let numeric: Bool
            switch field {
            case .fixed(_, let n), .variable(_, let n): numeric = n
            }
            if numeric, !value.allSatisfy(\.isASCIIDigit) { return .failure(.notDigits(ai: ai)) }
            if !numeric, !value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) {
                return .failure(.badCharacters(ai: ai))
            }

            switch ai {
            case "01":
                guard checkDigitIsValid(String(value)) else { return .failure(.badCheckDigit) }
                result.gtin = String(value)
            case "17":
                guard let day = day(String(value), referenceYear: referenceYear) else {
                    return .failure(.impossibleDate(ai: ai))
                }
                result.expiry = day
            case "11", "13", "15", "16":
                guard day(String(value), referenceYear: referenceYear) != nil else {
                    return .failure(.impossibleDate(ai: ai))
                }
            case "10": result.lot = String(value)
            case "21": result.serial = String(value)
            default: break
            }
        }
        return .success(result)
    }

    /// "(01)02000000000015(10)ZZ1001(21)S1" as the element string it stands for, with a separator
    /// after each variable-length field but the last. Nil when a bracket holds no AI this reader
    /// knows. A field runs to the next bracketed known AI, so a lot may hold brackets of its own.
    static func unbracketed(_ text: String) -> String? {
        var fields: [(ai: String, value: String)] = []
        var rest = Substring(text)
        func knownAI(at index: Substring.Index, in string: Substring) -> (String, Substring.Index)? {
            guard string[index...].first == "(" else { return nil }
            let open = string.index(after: index)
            guard let close = string[open...].firstIndex(of: ")") else { return nil }
            let ai = String(string[open..<close])
            guard (2...4).contains(ai.count), known[ai] != nil else { return nil }
            return (ai, string.index(after: close))
        }
        guard let (firstAI, firstStart) = knownAI(at: rest.startIndex, in: rest) else { return nil }
        var ai = firstAI
        rest = rest[firstStart...]
        while true {
            var end = rest.endIndex
            var next: (String, Substring.Index)?
            var index = rest.startIndex
            while index < rest.endIndex {
                if rest[index] == "(", let found = knownAI(at: index, in: rest) {
                    end = index
                    next = found
                    break
                }
                index = rest.index(after: index)
            }
            fields.append((ai, String(rest[rest.startIndex..<end])))
            guard let (nextAI, nextStart) = next else { break }
            ai = nextAI
            rest = rest[nextStart...]
        }
        var out = ""
        for (offset, field) in fields.enumerated() {
            out += field.ai + field.value
            if case .variable = known[field.ai], offset < fields.count - 1 { out.append(groupSeparator) }
        }
        return out
    }

    /// This code in the human-readable form: "(01)02000000000015(17)271130(10)ZZ1001".
    var bracketed: String {
        var out = ""
        if let gtin { out += "(01)\(gtin)" }
        if let expiry {
            out += String(format: "(17)%02d%02d%02d", expiry.year % 100, expiry.month, expiry.day)
        }
        if let lot { out += "(10)\(lot)" }
        if let serial { out += "(21)\(serial)" }
        return out
    }

    /// The AI at the start of `text`, longest known first.
    private static func aiAt(_ text: Substring) -> (String, Field)? {
        for length in [2, 3, 4] where text.count >= length {
            let candidate = String(text.prefix(length))
            if let field = known[candidate] { return (candidate, field) }
        }
        return nil
    }

    /// A YYMMDD date. Day `00` is the last day of the month (Plan MY §4).
    static func day(_ yymmdd: String, referenceYear: Int) -> StockDay? {
        guard yymmdd.count == 6, yymmdd.allSatisfy(\.isASCIIDigit) else { return nil }
        let digits = Array(yymmdd)
        guard let yy = Int(String(digits[0...1])), let mm = Int(String(digits[2...3])),
              let dd = Int(String(digits[4...5])) else { return nil }
        let year = fullYear(yy, referenceYear: referenceYear)
        if dd == 0 { return StockDay.lastDay(ofMonth: mm, year: year) }
        return StockDay(year: year, month: mm, day: dd)
    }

    /// GS1 General Specifications §7.12: a two-digit year is the one within 49 years ahead of the
    /// reference year or 50 behind it.
    static func fullYear(_ yy: Int, referenceYear: Int) -> Int {
        let century = referenceYear - referenceYear % 100
        let difference = yy - referenceYear % 100
        if difference >= 51 { return century - 100 + yy }
        if difference <= -50 { return century + 100 + yy }
        return century + yy
    }

    /// The GS1 mod-10 check on a GTIN of any length (8, 12, 13 or 14 digits): weights 3 and 1
    /// alternate from the digit next to the check digit.
    static func checkDigitIsValid(_ digits: String) -> Bool {
        guard [8, 12, 13, 14].contains(digits.count), digits.allSatisfy(\.isASCIIDigit) else { return false }
        let numbers = digits.compactMap(\.wholeNumberValue)
        return checkDigit(for: numbers.dropLast()) == numbers.last
    }

    /// The check digit for the digits before it.
    static func checkDigit<C: Collection>(for body: C) -> Int where C.Element == Int {
        var sum = 0
        for (offset, digit) in body.reversed().enumerated() {
            sum += digit * (offset % 2 == 0 ? 3 : 1)
        }
        return (10 - sum % 10) % 10
    }

    /// A GTIN of 8, 12, 13 or 14 digits as the GTIN-14 it stands for, left-padded with zeros. Nil
    /// for anything that is not a GTIN with a good check digit.
    static func gtin14(_ code: String) -> String? {
        let digits = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard checkDigitIsValid(digits) else { return nil }
        return String(repeating: "0", count: 14 - digits.count) + digits
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// A code scanned from a carton, as the stock list reads it (Plan MY §5). Pure.
///
/// Either a GS1 element string, whose product number, lot and expiry are kept, or a plain code (an
/// EAN on a box, a code the list already knows) kept verbatim. `code` is what a line's `codes`
/// are matched against: the GTIN-14 for a GS1 code or a plain GTIN, otherwise the code as read.
struct StockScan: Equatable, Sendable {
    let raw: String
    let code: String
    var gtin: String?
    var lot: String?
    var expiry: StockDay?
    var serial: String?

    /// Read a scanned code. A code that looks like GS1 and fails its checks is refused, never read
    /// as a plain code: a misread carton must be scanned again, not filed under a wrong number.
    static func read(_ raw: String, referenceYear: Int) -> Result<StockScan, GS1ElementString.Failure> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        // A plain retail barcode: 8, 12, 13 or 14 digits with a good check digit.
        if let gtin = GS1ElementString.gtin14(trimmed) {
            return .success(StockScan(raw: raw, code: gtin, gtin: gtin))
        }
        switch GS1ElementString.parse(trimmed, referenceYear: referenceYear) {
        case .success(let fields):
            return .success(StockScan(raw: raw, code: fields.gtin ?? trimmed, gtin: fields.gtin, lot: fields.lot,
                                      expiry: fields.expiry, serial: fields.serial))
        case .failure(let failure):
            guard looksLikeGS1(trimmed) else { return .success(StockScan(raw: raw, code: trimmed)) }
            return .failure(failure)
        }
    }

    /// Whether `text` was meant as a GS1 element string: it carries a separator or a symbology
    /// identifier, or opens with the product number's AI and digits.
    static func looksLikeGS1(_ text: String) -> Bool {
        if text.contains(GS1ElementString.groupSeparator) || text.hasPrefix("]") || text.hasPrefix("(") { return true }
        guard text.hasPrefix("01") || text.hasPrefix("02") else { return false }
        return text.dropFirst(2).prefix(14).allSatisfy { ("0"..."9").contains($0) } && text.count >= 16
    }

    /// The forms a line may have stored this GTIN under: the GTIN-14, and the shorter GTIN it
    /// pads (a 13-digit EAN typed from the box).
    static func forms(of gtin14: String) -> [String] {
        var forms = [gtin14]
        var trimmed = Substring(gtin14)
        for length in [13, 12, 8] {
            while trimmed.count > length, trimmed.first == "0" { trimmed = trimmed.dropFirst() }
            if trimmed.count == length { forms.append(String(trimmed)) }
        }
        return forms
    }

    /// The fields, for `scan_code`'s answer: "product number 02000000000015, lot ZZ1001, expiry
    /// 30 November 2027".
    var described: String {
        var parts: [String] = []
        if let gtin { parts.append("product number \(gtin)") }
        if let lot { parts.append("lot \(lot)") }
        if let expiry { parts.append("expiry \(expiry.spoken)") }
        if let serial { parts.append("serial \(serial)") }
        return parts.joined(separator: ", ")
    }
}
