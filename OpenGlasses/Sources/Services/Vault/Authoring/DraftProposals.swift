import Foundation

/// Plan LW §4 — a row the phone proposes from a manual it has indexed: the same row a pasted reply
/// gives (`DraftRow`), so the review screen and `DraftRowCheck` serve both. Nothing here writes to
/// the vault; the review screen does, on *Keep*.
struct ProposedRow: Equatable {
    var row: DraftRow
    /// The row's wording was taken from the manual (a label, a cause, a check): *in the manual's
    /// words* until the author rewrites it. Pass it to `DraftRowCheck.check(_:copiedFromManual:in:)`.
    var copiedFromManual: Bool
}

private extension ManualTable.Page {
    var draftPage: DraftPage { DraftPage(cited: printed ?? String(physical), physical: physical) }
}

private func tidy(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

// MARK: - Fault codes

/// Fault-code tables: a table whose code column (a row heading, or its first column) reads as the
/// template's codes in most rows → *code · label · page* rows, the label prefilled from the next
/// column and marked as the manual's words. *"Found 3 fault-code tables on pages 41–44. Add 38 codes?"*
enum FaultCodeProposals {

    struct Result: Equatable {
        var rows: [ProposedRow]
        /// How many tables the rows came from.
        var tableCount: Int
        /// The PDF pages they are printed on, ascending.
        var pages: [Int]
    }

    /// Of a table's rows, the share whose code column must read as a code for the table to count.
    static let codeShare = 0.6
    static let minimumCodes = 2

    /// Where in a row its code is: a row-heading cell, or the first value column.
    private enum CodeColumn: CaseIterable { case lastHeading, firstHeading, firstCell }

    private static func code(in row: ManualTable.Row, at column: CodeColumn) -> (code: String, label: String)? {
        switch column {
        case .lastHeading:
            guard let code = row.path.last else { return nil }
            return (tidy(code), firstText(row.cells.map(\.text)))
        case .firstHeading:
            guard row.path.count >= 2, let code = row.path.first else { return nil }
            return (tidy(code), firstText(Array(row.path.dropFirst()) + row.cells.map(\.text)))
        case .firstCell:
            guard let code = row.cells.first?.text else { return nil }
            return (tidy(code), firstText(row.cells.dropFirst().map(\.text)))
        }
    }

    private static func firstText(_ texts: [String]) -> String {
        texts.map(tidy).first { !$0.isEmpty } ?? ""
    }

    static func propose(tables: [ManualTable], template: TradeTemplate) -> Result {
        var rows: [ProposedRow] = []
        var seen = Set<String>()
        var tableCount = 0
        var pages = Set<Int>()
        for table in tables where table.failure == nil && table.rows.count >= minimumCodes {
            let readable = table.rows.filter { !$0.keyUncertain }
            guard let column = CodeColumn.allCases.first(where: { column in
                let codes = readable.filter { code(in: $0, at: column).map { template.isCode($0.code) } ?? false }.count
                return codes >= minimumCodes && Double(codes) >= codeShare * Double(table.rows.count)
            }) else { continue }
            var added = false
            for row in readable {
                guard let found = code(in: row, at: column), template.isCode(found.code), !found.label.isEmpty,
                      seen.insert(DraftRowCheck.codeKey(found.code, folding: false)).inserted else { continue }
                rows.append(ProposedRow(row: .faultCode(FaultCodeRow(code: found.code, label: found.label,
                                                                     page: row.page.draftPage)),
                                        copiedFromManual: true))
                pages.insert(row.page.physical)
                added = true
            }
            if added { tableCount += 1 }
        }
        return Result(rows: rows, tableCount: tableCount, pages: pages.sorted())
    }
}

// MARK: - The model map

/// Model numbers from a manual's cover pages and its specification tables, as the template's
/// identity pattern and `VaultModelIndex` both read them, grouped by spelling (with and without
/// dashes) → *"These 4 models, covered by this manual?"*. A model number is not wording, so these are
/// never the manual's words. A document number (`VaultModelIndex.isDocumentNumber`) is left out: a
/// manual prints its own on its cover.
enum ModelMapProposals {

    /// The cover pages, by PDF page: `DraftRowCheck.coverPages`.
    static let coverPages = DraftRowCheck.coverPages
    static let limit = 40

    static func propose(pages: [(page: Int, text: String)], tables: [ManualTable], template: TradeTemplate) -> [ProposedRow] {
        var sightings: [(token: String, page: ManualTable.Page)] = []
        for (page, text) in pages.sorted(by: { $0.page < $1.page }) where page <= coverPages {
            sightings += tokens(in: text, template: template).map { (token: $0, page: ManualTable.Page(physical: page)) }
        }
        for table in tables where isSpecification(table) {
            for row in table.rows {
                let text = (row.path + row.cells.map(\.text)).joined(separator: " ")
                sightings += tokens(in: text, template: template).map { (token: $0, page: row.page) }
            }
        }
        var order: [String] = []
        var groups: [String: (spellings: [String], page: ManualTable.Page)] = [:]
        for (token, page) in sightings {
            let key = VaultModelIndex.key(token)
            if var group = groups[key] {
                if !group.spellings.contains(where: { $0.uppercased() == token.uppercased() }) { group.spellings.append(token) }
                groups[key] = group
            } else {
                guard order.count < limit else { continue }
                order.append(key)
                groups[key] = (spellings: [token], page: page)
            }
        }
        return order.compactMap { key in
            guard let group = groups[key], let model = group.spellings.first else { return nil }
            return ProposedRow(row: .model(ModelRow(model: model, aliases: Array(group.spellings.dropFirst()),
                                                    page: group.page.draftPage)),
                               copiedFromManual: false)
        }
    }

    /// A table about the models: a title or caption saying *specification* or *model*.
    static func isSpecification(_ table: ManualTable) -> Bool {
        let caption = (table.label + " " + table.title).lowercased()
        return caption.contains("specification") || caption.contains("model")
    }

    /// The whole tokens of `text` (letters, digits and inner hyphens) that read as a model: model-like
    /// as a `##` heading needs (`VaultModelIndex`), the template's identity, and not a document number.
    static func tokens(in text: String, template: TradeTemplate) -> [String] {
        DraftRowCheck.tokens(of: text).filter { token in
            VaultModelIndex.isModelLike(token, minimumLength: VaultModelIndex.headingMinimumLength)
                && template.isIdentity(token) && !VaultModelIndex.isDocumentNumber(token)
        }
    }
}

// MARK: - Symptoms

/// Troubleshooting tables (*Symptom / Possible cause / Check*) and blocks of labelled lines
/// (`Problem: …`, `Cause: …`, `Check: …`) → one draft symptom per row, pointing at its page, its
/// wording the manual's until the author rewrites it in a technician's words. This is where most of
/// an author's know-how goes in; the proposal only saves typing.
enum SymptomProposals {

    static let symptomWords = ["symptom", "problem", "trouble", "condition", "complaint"]
    static let causeWords = ["cause", "reason"]
    static let checkWords = ["check", "remedy", "action", "correction", "solution", "what to do", "repair"]

    static func propose(tables: [ManualTable], pages: [(page: Int, text: String)] = []) -> [ProposedRow] {
        var rows: [ProposedRow] = []
        var seen = Set<String>()
        func add(_ row: SymptomRow) {
            let key = [row.symptom, row.cause, row.check].joined(separator: "|").lowercased()
            guard seen.insert(key).inserted else { return }
            rows.append(ProposedRow(row: .symptom(row), copiedFromManual: true))
        }
        for table in tables where table.failure == nil {
            for row in rowsOfTroubleshootingTable(table) { add(row) }
        }
        for (page, text) in pages.sorted(by: { $0.page < $1.page }) {
            for row in labelledBlocks(in: text, page: page) { add(row) }
        }
        return rows
    }

    private static func column(_ headers: [String], _ words: [String]) -> Int? {
        headers.firstIndex { header in words.contains { header.lowercased().contains($0) } }
    }

    static func rowsOfTroubleshootingTable(_ table: ManualTable) -> [SymptomRow] {
        let headers = table.rowHeaders + table.columns.map(\.name)
        guard let symptom = column(headers, symptomWords) else { return [] }
        let cause = column(headers, causeWords).flatMap { $0 == symptom ? nil : $0 }
        let check = column(headers, checkWords).flatMap { $0 == symptom || $0 == cause ? nil : $0 }
        guard cause != nil || check != nil else { return [] }
        var out: [SymptomRow] = []
        var lastSymptom = ""
        for row in table.rows where !row.keyUncertain {
            let headings = Array(row.path.suffix(table.rowHeaders.count))
            let fields = (headings + Array(repeating: "", count: max(0, table.rowHeaders.count - headings.count))
                          + row.cells.map(\.text)).map(tidy)
            func field(_ index: Int?) -> String {
                guard let index, fields.indices.contains(index) else { return "" }
                return fields[index]
            }
            // A symptom printed once over several rows of causes is the group heading, or the row above.
            var said = field(symptom)
            if said.isEmpty, row.path.count > table.rowHeaders.count, let group = row.path.first { said = tidy(group) }
            if said.isEmpty { said = lastSymptom }
            lastSymptom = said
            let likely = field(cause), first = field(check)
            guard !said.isEmpty, !(likely.isEmpty && first.isEmpty) else { continue }
            out.append(SymptomRow(symptom: said, cause: likely, check: first, page: row.page.draftPage))
        }
        return out
    }

    /// `Problem: …` then `Cause: …` and `Check: …` lines on a page, each block one row.
    static func labelledBlocks(in text: String, page: Int) -> [SymptomRow] {
        var out: [SymptomRow] = []
        var current: (symptom: String, cause: String, check: String)?
        func flush() {
            if let block = current, !block.symptom.isEmpty, !(block.cause.isEmpty && block.check.isEmpty) {
                out.append(SymptomRow(symptom: block.symptom, cause: block.cause, check: block.check,
                                      page: DraftPage(cited: String(page), physical: page)))
            }
            current = nil
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let label = trimmed[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
            let value = tidy(String(trimmed[trimmed.index(after: colon)...]))
            guard !value.isEmpty, label.split(separator: " ").count <= 3 else { continue }
            if symptomWords.contains(where: { label.contains($0) }) {
                flush()
                current = (value, "", "")
            } else if current != nil, causeWords.contains(where: { label.contains($0) }), current!.cause.isEmpty {
                current!.cause = value
            } else if current != nil, checkWords.contains(where: { label.contains($0) }), current!.check.isEmpty {
                current!.check = value
            }
        }
        flush()
        return out
    }
}
