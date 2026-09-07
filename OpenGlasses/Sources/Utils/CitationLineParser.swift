import Foundation

/// One source an answer cited, parsed back out of the answer's own text (Plan EK P3).
///
/// A `Source:` line is machine-attached by `VaultRetriever` (or by a vault tool's `(Source: …)`
/// suffix) and repeated verbatim by the model, so it names a real page in a real document rather
/// than something recalled. That is what makes it safe to turn into a door: tapping a citation
/// opens the page the sentence came from, and the session records that a human looked at it.
struct Citation: Equatable, Hashable, Identifiable {

    /// Which tier of the vault the citation points into. The two open different things: a manual
    /// page opens the figure sheet, a core file opens the vault's own editor.
    enum Kind: String, Equatable, Hashable {
        /// A reference-tier manual — a title and, usually, a printed page.
        case manual
        /// A core file loaded whole into every prompt ("error_codes.md").
        case coreFile = "core_file"
    }

    let kind: Kind
    /// The manual's title, or the core file's name.
    let title: String
    /// The printed page number, when the citation names one.
    let page: Int?
    /// "Figure 58" / "Table 16", when the citation names a caption.
    let figure: String?
    /// The `§Section` a prose passage was cited by.
    let section: String?
    /// A drawing with no caption — cited `page 44 (diagram)`.
    let isDiagram: Bool

    init(kind: Kind, title: String, page: Int? = nil, figure: String? = nil,
         section: String? = nil, isDiagram: Bool = false) {
        self.kind = kind
        self.title = title
        self.page = page
        self.figure = figure
        self.section = section
        self.isDiagram = isDiagram
    }

    /// The citation as the answer printed it, rebuilt from the parts — so a chip can never show a
    /// document the answer did not name.
    var label: String {
        var parts = [title]
        if let page { parts.append("page \(page)") }
        if let figure, !figure.isEmpty {
            parts.append(figure)
        } else if let section, !section.isEmpty {
            parts.append("§\(section)")
        }
        var rendered = parts.joined(separator: ", ")
        if isDiagram { rendered += " (diagram)" }
        return rendered
    }

    var id: String { label }

    /// What the chip says. The same words, because the technician is checking the chip against the
    /// sentence above it.
    var chipLabel: String { label }
}

/// Turns an answer's `Source:` lines into citations (Plan EK P3).
///
/// Pure and total: anything it cannot read is left alone rather than guessed at, because a chip
/// that opens the wrong page is worse than no chip. It reads the two shapes the app itself
/// produces — `VaultRetriever.Passage.citation` on its own line, and a vault tool's trailing
/// `(Source: error_codes.md, models.md)` — and nothing else.
enum CitationLineParser {

    /// Extensions that mean a core file rather than a manual title.
    static let coreFileExtensions: Set<String> = ["md", "markdown", "txt"]

    /// Longest a title may be before it is read as a sentence that happens to follow the word
    /// "Source" rather than as the name of a document.
    static let maxTitleLength = 120

    /// What a model writes where a source would go when it has none. Not a document, so not a door.
    static let nonCitations: Set<String> = ["none", "n/a", "na", "unknown", "-", "\u{2014}"]

    static func parse(_ text: String) -> [Citation] {
        var found: [Citation] = []
        var seen = Set<String>()
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            for citation in citations(inLine: line) where seen.insert(citation.label).inserted {
                found.append(citation)
            }
        }
        return found
    }

    // MARK: - One line

    static func citations(inLine line: String) -> [Citation] {
        guard let body = sourceBody(of: line) else { return [] }
        return citations(inBody: body)
    }

    /// The text a line's `Source:` marker introduces, with the parenthesised form closed off and
    /// the scan-provenance note removed. Nil when the line cites nothing.
    static func sourceBody(of line: String) -> String? {
        // Searched in the line itself rather than in a lowercased copy: lowercasing can change a
        // string's length, and an index from the copy would then cut the wrong characters.
        let markerRange = line.range(of: "sources:", options: .caseInsensitive)
            ?? line.range(of: "source:", options: .caseInsensitive)
        guard let markerRange else { return nil }
        let before = line[line.startIndex..<markerRange.lowerBound].trimmingCharacters(in: .whitespaces)
        var body = String(line[markerRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        // `(Source: a.md, b.md)` — the tools' inline suffix. The closing bracket is the last one on
        // the line, so a `(diagram)` inside the citation survives.
        if before.hasSuffix("("), let close = body.lastIndex(of: ")") {
            body = String(body[body.startIndex..<close])
        }
        body = stripProvenanceNote(body)
        let trimmed = body.trimmingCharacters(in: CharacterSet(charactersIn: " \t.;"))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Drop the sentence a recognised-from-a-scan passage carries after its citation. It is a
    /// warning about the page, not part of the page's name.
    static func stripProvenanceNote(_ body: String) -> String {
        guard let start = body.range(of: "(text recognised", options: .caseInsensitive) else { return body }
        return String(body[body.startIndex..<start.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// Split one `Source:` body into citations. A manual citation carries commas of its own
    /// (`Title, page 44, Figure 58`), so the parts are grouped rather than split: a part that names
    /// a page, a caption or a section belongs to the citation before it, and anything else starts
    /// a new one.
    static func citations(inBody body: String) -> [Citation] {
        var found: [Citation] = []
        var title: String?
        var page: Int?
        var figure: String?
        var section: String?
        var isDiagram = false

        func flush() {
            defer { title = nil; page = nil; figure = nil; section = nil; isDiagram = false }
            guard let name = title?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  name.count <= maxTitleLength, !nonCitations.contains(name.lowercased()) else { return }
            found.append(Citation(kind: isCoreFileName(name) ? .coreFile : .manual,
                                  title: name, page: page, figure: figure,
                                  section: section, isDiagram: isDiagram))
        }

        for raw in body.components(separatedBy: ",") {
            let part = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t.;"))
            guard !part.isEmpty else { continue }
            if let (number, diagram) = pageNumber(part) {
                if title == nil { continue }   // "page 4" with nothing to belong to
                page = number
                isDiagram = isDiagram || diagram
            } else if part.hasPrefix("§") {
                if title == nil { continue }
                section = String(part.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if isCaption(part) {
                if title == nil { continue }
                figure = part
            } else if part.lowercased() == "(diagram)" {
                if title == nil { continue }
                isDiagram = true
            } else {
                flush()
                title = part
            }
        }
        flush()
        return found
    }

    // MARK: - Parts

    /// `page 44`, or `page 44 (diagram)`. Returns the number and whether the drawing marker rode
    /// along with it.
    static func pageNumber(_ part: String) -> (page: Int, isDiagram: Bool)? {
        let lower = part.lowercased()
        guard lower.hasPrefix("page ") || lower.hasPrefix("pages ") || lower.hasPrefix("p. ") else { return nil }
        guard let match = part.range(of: #"\d+"#, options: .regularExpression),
              let number = Int(part[match]) else { return nil }
        return (number, lower.contains("(diagram)"))
    }

    /// `Figure 58` / `Table 16`, as the extractor writes a caption.
    static func isCaption(_ part: String) -> Bool {
        part.range(of: #"^(Figure|Table)\s+\d+"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isCoreFileName(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), !name.contains(" ") else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        return coreFileExtensions.contains(String(ext))
    }
}
