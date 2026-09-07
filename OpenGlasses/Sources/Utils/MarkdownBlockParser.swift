import Foundation

/// A segment of a chat message or a vault document: inline-markdown prose, a fenced code block, a
/// heading, a list, or a pipe table.
/// Pure value model — produced by `MarkdownBlockParser`, rendered by `MessageContentView`.
enum MarkdownBlock: Equatable {
    case prose(String)
    case code(language: String?, body: String)
    /// An ATX heading. `level` is 1–3; deeper hashes clamp to 3, because the design kit has three
    /// heading sizes and a fourth would be indistinguishable from body text anyway.
    case heading(level: Int, text: String)
    /// A run of `- ` / `* ` items.
    case bulletList([String])
    /// A run of `1. ` / `1) ` items, carrying the numbers the author wrote so a list that starts
    /// at 3 still reads as steps 3, 4, 5.
    case numberedList([MarkdownListItem])
    case table(MarkdownTable)
}

/// One numbered-list item: the number the author wrote and the text after it.
struct MarkdownListItem: Equatable {
    let number: Int
    let text: String
}

/// A pipe table: a header row, an alignment row, and body rows padded to the header's width.
///
/// The vault files are fault-code tables and nameplate references, and a table read as prose loses
/// the column that says what the code means — so it is a grid or it is nothing.
struct MarkdownTable: Equatable {
    enum Alignment: String, Equatable {
        case leading, center, trailing
    }

    let headers: [String]
    let alignments: [Alignment]
    let rows: [[String]]

    var columnCount: Int { headers.count }

    /// The alignment of a column, defaulting to leading for a table whose alignment row is
    /// narrower than its header.
    func alignment(_ column: Int) -> Alignment {
        column < alignments.count ? alignments[column] : .leading
    }
}

/// Splits message and document text into ordered blocks. No I/O, no rendering — fully
/// unit-testable, and used for the chat transcript, the vault core-file view and the extracted-text
/// page view alike, so one document reads the same wherever it is shown.
///
/// Rules:
/// - A fence is a line whose trimmed content starts with ```` ``` ```` (optionally followed by a
///   language tag, e.g. ```` ```swift ````). Everything up to the next fence is code, verbatim, and
///   no other rule applies inside it. An unterminated fence captures the remainder.
/// - `#`–`######` at the start of a line is a heading (clamped to level 3).
/// - `- `, `* ` or `+ ` starts a bullet item; consecutive items are one list.
/// - `1. ` or `1) ` starts a numbered item; consecutive items are one list.
/// - A line containing `|` whose *next* line is an alignment row (`---`, `:--`, `--:`, `:-:`,
///   separated by pipes) opens a table; the rows that follow it, while they contain a pipe, are its
///   body. Ragged rows are padded or truncated to the header's width.
/// - Everything else is prose, run together with soft line breaks preserved; whitespace-only prose
///   runs are dropped.
enum MarkdownBlockParser {

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
        var inCode = false
        var codeLang: String?

        func flushProse() {
            let joined = proseLines.joined(separator: "\n")
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { blocks.append(.prose(trimmed)) }
            proseLines.removeAll()
        }
        func flushCode() {
            blocks.append(.code(language: codeLang, body: codeLines.joined(separator: "\n")))
            codeLines.removeAll()
            codeLang = nil
        }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushProse()
                    let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLang = lang.isEmpty ? nil : lang
                    inCode = true
                }
                index += 1
                continue
            }
            if inCode {
                codeLines.append(line)
                index += 1
                continue
            }

            if let heading = heading(trimmed) {
                flushProse()
                blocks.append(heading)
                index += 1
                continue
            }

            if let table = table(from: lines, at: index) {
                flushProse()
                blocks.append(.table(table.table))
                index = table.next
                continue
            }

            if bulletItem(trimmed) != nil {
                flushProse()
                var items: [String] = []
                while index < lines.count,
                      let item = bulletItem(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            if numberedItem(trimmed) != nil {
                flushProse()
                var items: [MarkdownListItem] = []
                while index < lines.count,
                      let item = numberedItem(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                blocks.append(.numberedList(items))
                continue
            }

            proseLines.append(line)
            index += 1
        }

        if inCode { flushCode() } else { flushProse() }
        return blocks
    }

    // MARK: - Line kinds

    static func heading(_ trimmed: String) -> MarkdownBlock? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard hashes <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes)
        // `#Hashtag` is not a heading; `# ` is.
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: min(hashes, 3), text: text)
    }

    static func bulletItem(_ trimmed: String) -> String? {
        guard let marker = trimmed.first, marker == "-" || marker == "*" || marker == "+" else { return nil }
        let rest = trimmed.dropFirst()
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    static func numberedItem(_ trimmed: String) -> MarkdownListItem? {
        guard let match = trimmed.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) else { return nil }
        let marker = trimmed[match]
        let number = Int(marker.prefix { $0.isNumber }) ?? 1
        let text = String(trimmed[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : MarkdownListItem(number: number, text: text)
    }

    // MARK: - Tables

    /// A table starting at `index`, or nil. `next` is the line after the table's last row.
    static func table(from lines: [String], at index: Int) -> (table: MarkdownTable, next: Int)? {
        guard index + 1 < lines.count else { return nil }
        let headerLine = lines[index]
        guard headerLine.contains("|") else { return nil }
        guard let alignments = alignmentRow(lines[index + 1]) else { return nil }
        let headers = cells(headerLine)
        guard !headers.isEmpty else { return nil }

        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let line = lines[cursor]
            guard line.contains("|"), !line.trimmingCharacters(in: .whitespaces).hasPrefix("```") else { break }
            if alignmentRow(line) != nil { cursor += 1; continue }
            rows.append(padded(cells(line), to: headers.count))
            cursor += 1
        }
        let table = MarkdownTable(headers: headers,
                                  alignments: padded(alignments, to: headers.count, with: .leading),
                                  rows: rows)
        return (table, cursor)
    }

    /// `|---|:--:|--:|` → the alignments it declares, or nil when the line is not one.
    static func alignmentRow(_ line: String) -> [MarkdownTable.Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.range(of: #"^\|?[\s:\-|]+\|?$"#, options: .regularExpression) != nil else {
            return nil
        }
        let parts = cells(line)
        guard !parts.isEmpty else { return nil }
        var alignments: [MarkdownTable.Alignment] = []
        for part in parts {
            let spec = part.trimmingCharacters(in: .whitespaces)
            guard spec.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else { return nil }
            if spec.hasPrefix(":") && spec.hasSuffix(":") {
                alignments.append(.center)
            } else if spec.hasSuffix(":") {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }
        return alignments
    }

    /// The cells of a pipe row, with the leading and trailing pipes dropped.
    static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed = String(trimmed.dropLast()) }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func padded(_ row: [String], to width: Int) -> [String] {
        padded(row, to: width, with: "")
    }

    private static func padded<T>(_ row: [T], to width: Int, with filler: T) -> [T] {
        if row.count == width { return row }
        if row.count > width { return Array(row.prefix(width)) }
        return row + Array(repeating: filler, count: width - row.count)
    }
}
