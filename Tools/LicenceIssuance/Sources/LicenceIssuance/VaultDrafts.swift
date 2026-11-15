import Foundation

// Plan LW §4a — bring your own model, by copy and paste.
//
// The app provides no model. For each layer of a vault (fault codes, model map, symptoms) and each
// trade template, `PromptKit` renders the prompt an author copies into whatever model they use, with
// their own copy of the manual attached. The prompt states the exact return format. The author
// pastes the answer back and `PastedDraftParser` reads it into the same row types the phone's own
// proposal builders produce, so one review screen and one check (`DraftRowCheck`, in the app) serve
// both. Every line that does not fit the format comes back as `unparsed`, with its text: shown, never
// dropped. `IndexRowWriter` writes a kept row into the vault's file, citing the manual by the key the
// export's `expects` carries, so Plan LV's revision check can read it.
//
// Foundation only, self-contained with `TradeTemplate.swift` and `VaultStarter.swift` (see there).
// The prompts are written for this app; none of their words come from a manual.

// MARK: - The rows

public enum DraftLayer: String, CaseIterable, Sendable {
    case faultCodes = "fault_codes"
    case modelMap = "model_map"
    case symptoms
}

/// The page a row cites: as written (`cited`, which a pasted reply gives as printed or PDF page, the
/// check finds out which), and the PDF page when it is already known (a proposal read off the
/// manual's own table knows it).
public struct DraftPage: Equatable, Hashable, Sendable {
    public var cited: String
    public var physical: Int?

    public init(cited: String, physical: Int? = nil) {
        self.cited = cited
        self.physical = physical
    }

    /// A page as a reply writes it: "41", "p. 41", "page 41", "pp. 41-42", "4-12", "iv". Nil when the
    /// text is not a page.
    public static func parse(_ text: String) -> DraftPage? {
        var value = text.trimmingCharacters(in: .whitespaces)
        let lower = value.lowercased()
        for prefix in ["pdf page", "pages", "page", "pp.", "pp", "p."] where lower.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        while value.hasSuffix(".") { value.removeLast() }
        value = value.replacingOccurrences(of: "\u{2013}", with: "-")
        guard value.range(of: #"^[0-9A-Za-z]{1,6}(?:-[0-9A-Za-z]{1,6})?$"#, options: .regularExpression) != nil,
              value.contains(where: \.isNumber) || value.range(of: #"^[ivxlcdmIVXLCDM]{1,8}$"#, options: .regularExpression) != nil
        else { return nil }
        return DraftPage(cited: value)
    }
}

/// A fault code, what it means, and the page that says so.
public struct FaultCodeRow: Equatable, Sendable {
    public var code: String
    public var label: String
    public var page: DraftPage

    public init(code: String, label: String, page: DraftPage) {
        self.code = code
        self.label = label
        self.page = page
    }
}

/// A model, the other ways it is spelled, and the page that lists it (optional: a model is checked
/// against the whole manual).
public struct ModelRow: Equatable, Sendable {
    public var model: String
    public var aliases: [String]
    public var page: DraftPage?

    public init(model: String, aliases: [String] = [], page: DraftPage? = nil) {
        self.model = model
        self.aliases = aliases
        self.page = page
    }

    /// The model's name, then its aliases.
    public var spellings: [String] { [model] + aliases }
}

/// A symptom in a technician's words, its likely cause, the first check, and the page.
public struct SymptomRow: Equatable, Sendable {
    public var symptom: String
    public var cause: String
    public var check: String
    public var page: DraftPage

    public init(symptom: String, cause: String, check: String, page: DraftPage) {
        self.symptom = symptom
        self.cause = cause
        self.check = check
        self.page = page
    }
}

public enum DraftRow: Equatable, Sendable {
    case faultCode(FaultCodeRow)
    case model(ModelRow)
    case symptom(SymptomRow)

    public var layer: DraftLayer {
        switch self {
        case .faultCode: return .faultCodes
        case .model: return .modelMap
        case .symptom: return .symptoms
        }
    }
}

// MARK: - The prompt kits

public enum PromptKit {

    /// The return format of a layer, as the prompt states it and the parser reads it.
    public static func format(_ layer: DraftLayer) -> String {
        switch layer {
        case .faultCodes: return "code | what it means | page"
        case .modelMap: return "model | other spellings, comma-separated, or - | page"
        case .symptoms: return "what the technician says | likely cause | first check | page"
        }
    }

    /// The prompt an author copies for `layer` under `template`. `manualTitle` names the manual they
    /// attach, when the phone knows it.
    public static func prompt(for layer: DraftLayer, template: TradeTemplate, manualTitle: String? = nil) -> String {
        let manual = manualTitle.map { "the manual \"\($0.trimmingCharacters(in: .whitespacesAndNewlines))\"" }
            ?? "the manual"
        let pageRule = "- Give the page: the number printed on that page, or the PDF page number if the page has no printed number."
        let common = [
            "- Use only this manual. If it does not say something, leave it out. Never guess.",
            "- Write in a few words of your own. Do not copy sentences from the manual."
        ]
        var lines: [String]
        switch layer {
        case .faultCodes:
            lines = ["I have attached \(manual), for \(template.subject). List every fault code it explains.", "", "Rules:"]
                + common
                + ["- A fault code here is \(template.codeDescription).",
                   "- Only list a code the manual prints. Write it exactly as the manual does.",
                   "- Say what each code means in at most eight words.",
                   pageRule]
        case .modelMap:
            lines = ["I have attached \(manual), for \(template.subject). List every model it says it covers.", "", "Rules:"]
                + common
                + ["- A model here is \(template.identity.description).",
                   "- Only list a model the manual prints. Write it exactly as the manual does.",
                   "- On the same line, give the other ways the manual writes the same model (with or without dashes, a longer or shorter form). Write - when there are none.",
                   pageRule.replacingOccurrences(of: "Give the page:", with: "Give the page that lists the model:")]
        case .symptoms:
            let examples = template.symptomHeadings.prefix(4).map { $0.lowercased() }.joined(separator: ", ")
            lines = ["I have attached \(manual), for \(template.subject). Find its troubleshooting sections and list the problems they cover.", "", "Rules:"]
                + common
                + ["- Say each problem the way a technician says it on the job (for example: \(examples)).",
                   "- For each, give the likely cause and the first check the manual gives, in a few words each.",
                   pageRule]
        }
        lines += ["", "Return only the list, one per line, in exactly this format, with nothing before or after it:",
                  format(layer)]
        return lines.joined(separator: "\n")
    }
}

// MARK: - The paste parser

/// A pasted reply, read into rows. What does not fit is kept, with its line number and text.
public struct ParsedDraft: Equatable, Sendable {
    public struct Unparsed: Equatable, Sendable {
        /// 1-based, in the pasted text.
        public let line: Int
        /// The line as pasted, trimmed.
        public let text: String
    }

    public var rows: [DraftRow]
    public var unparsed: [Unparsed]
}

public enum PastedDraftParser {

    /// Reads `text` as a reply in `layer`'s format (`PromptKit.format`). Tolerated: code fences,
    /// bullets and numbering, bold and inline code, a Markdown table (its header and rule rows are
    /// formatting and are skipped), `|`, ` · ` or a tab between fields. Every other line that is not
    /// a row in the format, prose included, is returned as `unparsed`.
    public static func parse(_ text: String, layer: DraftLayer) -> ParsedDraft {
        var rows: [DraftRow] = []
        var unparsed: [ParsedDraft.Unparsed] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { continue }
            guard let cells = cells(of: trimmed) else {
                unparsed.append(.init(line: index + 1, text: trimmed))
                continue
            }
            if isRule(cells) || isHeader(cells, layer: layer) { continue }
            if let row = row(from: cells, layer: layer) {
                rows.append(row)
            } else {
                unparsed.append(.init(line: index + 1, text: trimmed))
            }
        }
        return ParsedDraft(rows: rows, unparsed: unparsed)
    }

    /// The line's fields, its list marker, emphasis and table edges taken off; nil when it has no
    /// field separator at all.
    static func cells(of line: String) -> [String]? {
        var text = line
        if let marker = text.range(of: #"^(?:[-*•+]|\d{1,3}[.)])\s+"#, options: .regularExpression) {
            text.removeSubrange(marker)
        }
        for emphasis in ["**", "__", "`"] { text = text.replacingOccurrences(of: emphasis, with: "") }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        let separator: String
        if text.contains("|") { separator = "|" } else if text.contains(" · ") { separator = " · " }
        else if text.contains("\t") { separator = "\t" } else { return nil }
        return text.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A Markdown table's rule row: `---`, `:--:`, every field.
    static func isRule(_ cells: [String]) -> Bool {
        cells.allSatisfy { $0.range(of: #"^:?-{2,}:?$"#, options: .regularExpression) != nil }
    }

    /// A header row: its last field says "page" and its first names the layer's subject.
    static func isHeader(_ cells: [String], layer: DraftLayer) -> Bool {
        guard let first = cells.first?.lowercased(), let last = cells.last?.lowercased(),
              ["page", "pages", "page number", "pdf page", "manual and page"].contains(last) else { return false }
        switch layer {
        case .faultCodes: return ["code", "fault code", "error code", "fault"].contains(first)
        case .modelMap: return ["model", "model number", "models"].contains(first)
        case .symptoms: return ["what the technician says", "symptom", "problem", "symptoms"].contains(first)
        }
    }

    static func row(from cells: [String], layer: DraftLayer) -> DraftRow? {
        switch layer {
        case .faultCodes:
            guard cells.count == 3, let page = DraftPage.parse(cells[2]) else { return nil }
            let code = cells[0].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !code.isEmpty, code.count <= 24, code.contains(where: { $0.isLetter || $0.isNumber }),
                  !cells[1].isEmpty else { return nil }
            return .faultCode(FaultCodeRow(code: code, label: cells[1], page: page))
        case .modelMap:
            guard cells.count == 2 || cells.count == 3, !cells[0].isEmpty, cells[0].count <= 40 else { return nil }
            var page: DraftPage?
            if cells.count == 3, !isNone(cells[2]) {
                guard let parsed = DraftPage.parse(cells[2]) else { return nil }
                page = parsed
            }
            let aliases = cells[1].components(separatedBy: CharacterSet(charactersIn: ",;/"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !isNone($0) && $0.uppercased() != cells[0].uppercased() }
            return .model(ModelRow(model: cells[0], aliases: aliases, page: page))
        case .symptoms:
            guard cells.count == 4, let page = DraftPage.parse(cells[3]),
                  !cells[0].isEmpty, !cells[1].isEmpty, !cells[2].isEmpty else { return nil }
            return .symptom(SymptomRow(symptom: cells[0], cause: cells[1], check: cells[2], page: page))
        }
    }

    static func isNone(_ text: String) -> Bool {
        ["-", "\u{2013}", "\u{2014}", "none", "n/a", "na"].contains(text.lowercased())
    }
}

// MARK: - Writing a kept row

/// The Markdown a kept row becomes in the vault's file. Each cites the manual by the key the export's
/// `expects` gives it, then `p. N` with the PDF page, and the printed page beside it when it differs:
/// what Plan LV's answer note reads (`key p. N`).
public enum IndexRowWriter {

    public static func citation(key: String, page: Int, printed: String? = nil) -> String {
        guard let printed = printed?.trimmingCharacters(in: .whitespaces), !printed.isEmpty,
              printed != String(page) else { return "\(key) p. \(page)" }
        return "\(key) p. \(page) (printed \(printed))"
    }

    /// A row of the fault-code table (`VaultStarter.faultCodeTableHeader`).
    public static func faultCodeLine(_ row: FaultCodeRow, citation: String) -> String {
        "| \(cell(row.code)) | \(cell(row.label)) | \(cell(citation)) |"
    }

    /// A model's section for `models.md`: its heading, as `VaultModelIndex` reads it, and the
    /// manuals that cover it.
    public static func modelSection(_ row: ModelRow, citations: [String]) -> String {
        let heading = row.aliases.isEmpty ? row.model : "\(row.model) (\(row.aliases.joined(separator: ", ")))"
        let manuals = citations.isEmpty ? "none yet" : citations.joined(separator: "; ")
        return "## \(heading)\nManuals: \(manuals)."
    }

    /// One numbered check under a symptom's heading in `symptoms.md`.
    public static func symptomCheckLine(_ row: SymptomRow, number: Int, citation: String) -> String {
        "\(number). \(sentence(row.check)) Likely cause: \(sentence(row.cause)) \(citation)."
    }

    static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ")
    }

    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return trimmed }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}
