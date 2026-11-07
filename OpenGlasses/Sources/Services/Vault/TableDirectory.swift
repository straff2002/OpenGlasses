import Foundation

/// Which of a vault's read tables a question asked in plain words may be about (Plan JW P1b).
///
/// A technician asks for a tabulated value without the table's number ("what does a size-4 widget
/// carry with three in a housing?"). The table's row passages are mostly numbers, so the passage
/// search rarely finds them; the words that tell one table from another are in its **title**, its
/// column and row-key headings and its units. This scores every table against the question on
/// those words alone and offers the best one or two, with a score and a margin, only when they
/// clear a threshold. The per-turn manual block names them (`hint(for:in:)`) so the model reads
/// the value with `table_lookup`, and `table_lookup` resolves a `table` given as words through the
/// same score (`TableLookup.resolveTable`).
///
/// Lexical and deterministic: [[LexicalSupport]]'s content terms ("-ies" read as "-y", so a plural
/// title meets a singular question), a number with its unit as one term ("30 °C", "30 degrees"),
/// and a unit named on its own. Each shared term counts by how few of the vault's tables print it
/// (inverse document frequency over the tables), so the words every table's title carries ("table",
/// "rating", the book's subject) weigh little and the words that set one table apart weigh most. A
/// title word counts in full, a heading or unit word for `headingWeight`. Pure.
enum TableDirectory {

    /// A table the question may be about.
    struct Candidate: Equatable {
        let entry: TableReference.Entry
        /// The summed weight of the terms the question shares with the table: each term's rarity
    /// among the tables (1 for a term one table prints), a heading's scaled by `headingWeight`.
        let score: Double
        /// How far ahead of the next table it scored (its whole score when it is the only one).
        let margin: Double
        /// How many distinct terms it shares with the question.
        let shared: Int
    }

    /// A heading or unit word, against a title word.
    static let headingWeight = 0.6
    /// The least score a candidate is offered at: about two thirds of one word only that table
    /// prints, so with `minimumShared` two rare words clear it, or several common ones.
    static let minimumScore = 0.65
    /// The least number of distinct shared terms a candidate is offered at: one word in common is
    /// coincidence.
    static let minimumShared = 2
    /// A second candidate is offered beside the first only when it scores at least this share of
    /// the first's.
    static let secondShare = 0.6
    /// How much of a title the hint says.
    static let titleLimit = 90

    // MARK: - Ranking

    /// Every table sharing a term with the question, best first — ties in catalogue order. One
    /// entry per document and label: a table continued on later pages under the same caption is one
    /// table, its title the first non-empty one and its headings all of theirs.
    ///
    /// `asTechnicianSaid` (the hint's ranking, Plan KR P3) reads the question as a technician says
    /// it rather than as a model names a table: a word the trade says for what a book prints
    /// (`printedFor`) counts as the printed word too, and a table set in kilovolt bands weighs
    /// `unaskedBandShare` of its score when the question names no voltage — a question that says
    /// none is about the ordinary band. `table_lookup`'s words are the model's, read as written.
    static func ranked(_ question: String, in catalogue: [TableReference.Entry],
                       asTechnicianSaid: Bool = false) -> [Candidate] {
        let tables = merged(catalogue)
        guard !tables.isEmpty else { return [] }
        // "Table" says the question wants a table, not which: titles that mention other tables
        // ("multipliers for Tables 97 and 99") would otherwise gain from it. The question's terms
        // are cut under each table's document's rule (Plan JY P0).
        var askedByRule: [TermRule: Set<String>] = [:]
        for rule in Set(tables.map(\.termRule)).union([.english]) {
            var asked = terms(question, rule: rule).subtracting(tableWords(rule))
            if asTechnicianSaid, rule == .english {
                for (said, printed) in printedForTerms where !asked.isDisjoint(with: said) { asked.formUnion(printed) }
            }
            askedByRule[rule] = asked
        }
        let demotesBands = asTechnicianSaid && !namesVoltage(question)
        guard askedByRule.values.contains(where: { !$0.isEmpty }) else { return [] }
        let fields = tables.map { (title: terms($0.title, rule: $0.termRule),
                                   headings: headingTerms($0.headings, rule: $0.termRule)) }
        var frequency: [String: Int] = [:]
        for field in fields {
            for term in field.title.union(field.headings) { frequency[term, default: 0] += 1 }
        }
        // A term's rarity, scaled so a term only one table prints weighs 1 whatever the vault's
        // size: the threshold then means the same for a manual with five tables and a code book
        // with two hundred.
        let count = Double(tables.count)
        let rarest = log(1 + (count - 0.5) / 1.5)
        func rarity(_ term: String) -> Double {
            let df = Double(frequency[term] ?? 0)
            return log(1 + (count - df + 0.5) / (df + 0.5)) / rarest
        }
        var scored: [(index: Int, score: Double, shared: Int)] = []
        for (index, field) in fields.enumerated() {
            var score = 0.0
            var shared = 0
            for term in askedByRule[tables[index].termRule] ?? [] {
                let weight = field.title.contains(term) ? 1.0 : (field.headings.contains(term) ? headingWeight : 0)
                guard weight > 0 else { continue }
                score += weight * rarity(term)
                shared += 1
            }
            if demotesBands, isKilovoltBand(tables[index]) { score *= unaskedBandShare }
            if shared > 0 { scored.append((index, score, shared)) }
        }
        let order = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return order.enumerated().map { position, item in
            let next = position + 1 < order.count ? order[position + 1].score : 0
            return Candidate(entry: tables[item.index], score: item.score, margin: item.score - next, shared: item.shared)
        }
    }

    /// The one or two tables worth offering for a question: the best, when it clears
    /// `minimumScore` and `minimumShared`, and the next when it clears them too and scores at least
    /// `secondShare` of the best. Empty when nothing does. The same label in another document (a
    /// second edition of the book) is the same table, not a second candidate: it is skipped, so the
    /// second place goes to a different table, and `hint` names every document that prints it.
    static func candidates(for question: String, in catalogue: [TableReference.Entry], limit: Int = 2) -> [Candidate] {
        let ranked = Self.ranked(question, in: catalogue, asTechnicianSaid: true)
        guard let best = ranked.first, clears(best) else { return [] }
        var out = [best]
        for next in ranked.dropFirst() where out.count < limit {
            if out.contains(where: { $0.entry.label.lowercased() == next.entry.label.lowercased() }) { continue }
            guard clears(next), next.score >= best.score * secondShare else { break }
            out.append(next)
        }
        return out
    }

    private static func clears(_ candidate: Candidate) -> Bool {
        candidate.score >= minimumScore && candidate.shared >= minimumShared
    }

    /// One entry per document and label, in first-seen order.
    static func merged(_ catalogue: [TableReference.Entry]) -> [TableReference.Entry] {
        var order: [String] = []
        var byKey: [String: TableReference.Entry] = [:]
        for entry in catalogue {
            let key = (entry.documentName ?? "") + "#" + entry.label.lowercased()
            guard var existing = byKey[key] else {
                order.append(key)
                byKey[key] = entry
                continue
            }
            let title = existing.title.trimmingCharacters(in: .whitespaces).isEmpty ? entry.title : existing.title
            existing = TableReference.Entry(label: existing.label, title: title, documentName: existing.documentName,
                                            headings: existing.headings + entry.headings, termRule: existing.termRule)
            byKey[key] = existing
        }
        return order.compactMap { byKey[$0] }
    }

    // MARK: - Terms

    /// The terms a question or a table is compared on: content terms, a number with its unit, and
    /// a unit named on its own.
    ///
    /// Under a rule other than `.english` (Plan JY P0) the content terms are that rule's, without
    /// the English "-ies" fix; the units read are still the English spellings (localised unit
    /// words are Plan JY P4), and a number with "°C" or "%" reads alike in any language.
    static func terms(_ text: String, rule: TermRule = .english) -> Set<String> {
        var out = rule == .english
            ? Set(LexicalSupport.contentTerms(text).map(singularY)).subtracting(unitTerms)
            : LexicalSupport.contentTerms(text, rule: rule).subtracting(unitTerms)
        let lower = text.lowercased()
        let ns = lower as NSString
        for match in measured.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
            guard let unit = unitWords[ns.substring(with: match.range(at: 2)).replacingOccurrences(of: " ", with: "")]
            else { continue }
            let number = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: ".")
            out.insert("\(Double(number).map(spelled) ?? number)\(unit)")
            out.insert("unit:" + unit)
        }
        for match in unitAlone.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
            if let unit = unitWords[ns.substring(with: match.range(at: 1)).replacingOccurrences(of: " ", with: "")] {
                out.insert("unit:" + unit)
            }
        }
        return out
    }

    /// The terms of a table's headings: each heading's, and a heading that is a unit by itself
    /// ("A", "mm") as that unit.
    static func headingTerms(_ headings: [String], rule: TermRule = .english) -> Set<String> {
        var out = Set<String>()
        for heading in Set(headings) {
            out.formUnion(terms(heading, rule: rule))
            let bare = heading.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "()[]"))
            if let unit = unitWords[bare] { out.insert("unit:" + unit) }
        }
        return out
    }

    // MARK: - As the technician said it (Plan KR P3)

    /// Words the trade says for what a book prints: "conduit" for the raceway a book's title names,
    /// "wire" for its conductors. Generic trade words only; English.
    static let printedFor: [(said: String, printed: String)] = [
        ("conduit", "raceway"), ("wire", "conductor"), ("wires", "conductors"),
    ]

    private static let printedForTerms: [(Set<String>, Set<String>)] = printedFor.map {
        (LexicalSupport.contentTerms($0.said).map(singularY).reduce(into: Set<String>()) { $0.insert($1) },
         LexicalSupport.contentTerms($0.printed).map(singularY).reduce(into: Set<String>()) { $0.insert($1) })
    }

    /// What a kilovolt-band table scores against a question that names no voltage.
    static let unaskedBandShare = 0.5

    /// Whether the words name a voltage: a number of volts or kilovolts, or the word itself.
    static func namesVoltage(_ text: String) -> Bool {
        let found = terms(text)
        if found.contains("unit:v") || found.contains("unit:kv") { return true }
        return text.range(of: #"(?<![\p{L}])(voltage|volts?|kv|kilovolts?)(?![\p{L}])"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Whether a table is set in kilovolt bands: its title or a heading prints a kV value, or says
    /// medium or high voltage.
    static func isKilovoltBand(_ entry: TableReference.Entry) -> Bool {
        ([entry.title] + entry.headings).contains { text in
            text.range(of: #"\d\s*kv(?![\p{L}])|(?<![\p{L}])(medium|high)[\s-]voltage(?![\p{L}])"#,
                       options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// One condition a table's title says it holds under.
    struct Condition: Equatable {
        enum Kind: String, CaseIterable {
            case material = "conductor material"
            case voltage = "voltage"
            case run = "where the conductors run"
            case count = "how many conductors"
            case ambient = "ambient temperature"
        }
        let kind: Kind
        /// As the title prints it, or shortened: "aluminum", "not over 900 V", "in free air".
        let text: String
    }

    /// The conditions a table's title — and, for its voltage band, its headings — says it holds
    /// under (Plan KR P3), in `Condition.Kind` order. A title shortened for the hint can lose them,
    /// and two tables offered alike often differ only in one. Generic electrical conditions: none
    /// for a table that prints none.
    static func conditions(of entry: TableReference.Entry) -> [Condition] {
        let title = entry.title
        let lower = title.lowercased()
        var out: [Condition] = []
        func match(_ pattern: String, in text: String) -> String? {
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]).map {
                String(text[$0]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
            }
        }
        let copper = lower.range(of: #"(?<![\p{L}])copper(?![\p{L}])"#, options: .regularExpression) != nil
        let aluminum = lower.range(of: #"(?<![\p{L}])alumin(?:um|ium)(?![\p{L}])"#, options: .regularExpression) != nil
        if copper != aluminum { out.append(Condition(kind: .material, text: copper ? "copper" : "aluminum")) }
        let volts = #"\d[\d ,.]*\s*k?v(?![\p{L}])"#
        if let voltage = match(#"(?:(?:not more than|not over|no more than|up to|over|above|exceeding|rated)\s+)?"# + volts
                               + #"(?:\s*(?:to|-|\x{2013})\s*"# + volts + ")?", in: title) {
            out.append(Condition(kind: .voltage, text: voltage))
        } else if let band = entry.headings.lazy.compactMap({ match(volts + #"(?:\s*(?:to|-|\x{2013})\s*"# + volts + ")?", in: $0) })
            .first(where: { $0.lowercased().contains("kv") }) {
            out.append(Condition(kind: .voltage, text: band + " bands"))
        }
        let runs = [#"in buried conduit"#, #"direct(?:ly)? buried"#, #"direct burial"#, #"underground"#,
                    #"in free air"#, #"free air"#, #"in (?:a )?raceways? or cables?"#, #"in (?:a )?cables? or raceways?"#,
                    #"in (?:a )?raceways?"#, #"in (?:a )?conduit"#, #"in (?:a )?cable tray"#]
        if let run = runs.lazy.compactMap({ match(#"(?<![\p{L}])"# + $0 + #"(?![\p{L}])"#, in: title) }).first {
            out.append(Condition(kind: .run, text: run))
        }
        let conductorAfter = #"(?=[^,;()]{0,40}?(?<![\p{L}])(?:conductors?|cables?)(?![\p{L}]))"#
        if let count = match(#"(?<![\p{L}])(?:(?:not more than|no more than|up to)\s+(?:one|two|three|four|five|six|\d+)|single|(?:one|two|three|four|\d+)\s+sets\s+of\s+(?:two|three|four|\d+))(?![\p{L}])"#
                             + conductorAfter, in: title) {
            out.append(Condition(kind: .count, text: count))
        }
        if let ambient = match(#"(?<![\p{L}\p{N}])\d+\s*°\s*c(?=\*?\s+ambient)|(?<=ambient temperature of )\d+\s*°\s*c|(?<=ambient of )\d+\s*°\s*c"#,
                               in: title) {
            out.append(Condition(kind: .ambient, text: ambient + " ambient"))
        }
        return out
    }

    /// The kinds of condition every one of the tables prints, and not all alike, in
    /// `Condition.Kind` order. A kind one table leaves unsaid decides nothing between them.
    static func differingKinds(_ sets: [[Condition]]) -> [Condition.Kind] {
        guard sets.count > 1 else { return [] }
        return Condition.Kind.allCases.filter { kind in
            let texts = sets.map { set in set.first { $0.kind == kind }?.text.lowercased() }
            return !texts.contains(nil) && Set(texts.compactMap { $0 }).count > 1
        }
    }

    private static let tableWords = LexicalSupport.contentTerms("table tables")

    /// The table words under `rule`.
    private static func tableWords(_ rule: TermRule) -> Set<String> {
        rule == .english ? tableWords : LexicalSupport.contentTerms("table tables", rule: rule)
    }

    /// The content terms the unit spellings make, left out of the plain terms: a unit counts as
    /// a unit, once.
    private static let unitTerms = Set(LexicalSupport.contentTerms(unitWords.keys.joined(separator: " ")).map(singularY))

    /// "batteries" → "batterie" (LexicalSupport) → "battery", so a plural title meets a singular
    /// question.
    private static func singularY(_ term: String) -> String {
        term.hasSuffix("ie") && term.count >= 5 ? String(term.dropLast(2)) + "y" : term
    }

    private static func spelled(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e9 ? String(Int(value)) : String(value)
    }

    /// Unit spellings, folded to one name each. Generic units of measure only.
    private static let unitWords: [String: String] = [
        "°c": "°c", "°": "°c", "degree": "°c", "degrees": "°c", "deg": "°c", "celsius": "°c", "c": "°c",
        "°f": "°f", "fahrenheit": "°f",
        "%": "%", "percent": "%", "per cent": "%", "percentage": "%",
        "a": "a", "amp": "a", "amps": "a", "ampere": "a", "amperes": "a",
        "v": "v", "volt": "v", "volts": "v", "kv": "kv",
        "w": "w", "watt": "w", "watts": "w", "kw": "kw",
        "hp": "hp", "horsepower": "hp",
        "mm": "mm", "millimetre": "mm", "millimetres": "mm", "millimeter": "mm", "millimeters": "mm",
        "m": "m", "metre": "m", "metres": "m", "meter": "m", "meters": "m",
        "kg": "kg", "nm": "nm", "psi": "psi", "kpa": "kpa", "bar": "bar",
    ]

    /// A number and the unit printed or said after it: "30 °C", "30°", "75 degrees C", "40%",
    /// "600 V". A "degrees" with a "C" or "Celsius" after it is one unit.
    private static let measured = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}.])(\d+(?:[.,]\d+)?)\s*(°\s*[cf]?|degrees?|deg|celsius|fahrenheit|per cent|percent(?:age)?|%|amps?|amperes?|volts?|kv|watts?|kw|hp|horsepower|millimet(?:re|er)s?|met(?:re|er)s?|mm|m|kg|nm|psi|kpa|bar|[avwc])(?![\p{L}\p{N}])"#)

    /// A unit named on its own, as a word: "degrees", "amps", "volts", "percent" (not single letters,
    /// which are words or row labels as often as units).
    private static let unitAlone = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])(°c|°f|%|degrees?|celsius|fahrenheit|per cent|percent(?:age)?|amps?|amperes?|volts?|watts?|horsepower)(?![\p{L}\p{N}])"#)

    // MARK: - The hint

    /// Whether a turn asks for a value a table would hold: how many or how much, a rating, a
    /// factor, a size, a limit, a value with a unit. Generic words only — the table directory
    /// decides which table, and nothing is offered unless one clears the threshold.
    static func asksForValue(_ turn: String) -> Bool {
        let lower = turn.lowercased().replacingOccurrences(of: "’", with: "'")
        if valuePhrases.contains(where: { lower.contains($0) }) { return true }
        let words = Set(lower.split { !$0.isLetter }.map(String.init))
        if !words.isDisjoint(with: valueWords) { return true }
        let ns = lower as NSString
        return measured.firstMatch(in: lower, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static let valuePhrases = [
        "how many", "how much", "how far", "how deep", "how big", "how long", "how large", "how wide", "how high",
        "how hot", "how close", "what size", "no more than", "not more than", "at least", "up to", "good for",
    ]

    private static let valueWords: Set<String> = [
        "rating", "ratings", "rated", "factor", "factors", "size", "sizes", "sized", "maximum", "minimum", "max", "min",
        "allowable", "allowed", "permitted", "permissible", "limit", "limits", "value", "values", "tabulated",
        "capacity", "clearance", "clearances", "spacing", "distance", "depth", "radius", "diameter", "dimension",
        "dimensions", "derate", "derating", "correction", "fill", "carry", "load", "setting", "multiplier",
        // A rating a book tabulates under its own name (Plan KR P3): "aluminum conductors in a
        // raceway ampacity" asks for one as surely as "what size" does.
        "ampacity", "ampacities", "amperage",
    ]

    /// The line the per-turn manual block carries for a value question that names no table, or nil:
    /// the one or two tables the directory offers, each by label, title (shortened) and — when the
    /// tables come from more than one document — the document, and what to do with them.
    static func hint(for turn: String, in catalogue: [TableReference.Entry]) -> String? {
        guard !catalogue.isEmpty, asksForValue(turn),
              TableReference.references(in: turn, catalogue: catalogue).isEmpty else { return nil }
        let offered = candidates(for: turn, in: catalogue)
        guard !offered.isEmpty else { return nil }
        let documents = Set(catalogue.compactMap(\.documentName))
        let offeredConditions = offered.map { Self.conditions(of: $0.entry) }
        let named = zip(offered, offeredConditions).map { candidate, held -> String in
            let title = shortened(candidate.entry.title)
            // The conditions the table holds under, which a shortened title can lose (Plan KR P3).
            let assumes = held.isEmpty ? "" : " [holds for: " + held.map(\.text).joined(separator: "; ") + "]"
            guard documents.count > 1 else { return candidate.entry.label + (title.isEmpty ? "" : " — " + title) + assumes }
            // Every document that prints the label, the best-scoring one first.
            var printing: [String] = candidate.entry.documentName.map { [$0] } ?? []
            for entry in catalogue where entry.label.lowercased() == candidate.entry.label.lowercased() {
                if let name = entry.documentName, !printing.contains(name) { printing.append(name) }
            }
            let document = printing.isEmpty ? "" : " (" + printing.joined(separator: ", ") + ")"
            return candidate.entry.label + (title.isEmpty ? "" : " — " + title) + document + assumes
        }
        return "Tables that may answer this: " + named.joined(separator: "; ") + "."
            + conditionsLine(offeredConditions)
            + " Read the value with table_lookup (table, row, column), and ask the technician for any input the table needs."
    }

    /// What the model does with the tables' conditions (Plan KR P3, owner decision 4): say the table
    /// it read and the conditions it took to hold; when the offered tables differ in one, read the
    /// one the technician's words settle, and ask only that one condition when they settle none.
    /// Empty when no offered table prints a condition.
    static func conditionsLine(_ conditions: [[Condition]]) -> String {
        guard conditions.contains(where: { !$0.isEmpty }) else { return "" }
        var line = " Say which table you read and the conditions you took to hold."
        let differ = differingKinds(conditions)
        if !differ.isEmpty {
            line += " These tables differ in " + differ.map(\.rawValue).joined(separator: ", ")
                + ": read the one the technician's words fit; if their words fit both, ask the one condition that "
                + "decides, then read it."
        }
        return line
    }

    /// A title as the hint says it: a trailing "(See …)" or "[See …]" cross-reference left out,
    /// then cut on a word boundary at `titleLimit` characters.
    static func shortened(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: #"\s*[\(\[]\s*see\b[^\(\)\[\]]*[\)\]]\.?\s*$"#,
                                  options: [.regularExpression, .caseInsensitive]) {
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard text.count > titleLimit else { return text }
        let cut = text.prefix(titleLimit)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:(—-")) + "…"
    }
}
