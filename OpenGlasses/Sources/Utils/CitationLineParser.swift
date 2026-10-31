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
        /// An approved team learning (Plan FP P2): the crew's finding, never a manual page. Its
        /// title is the contract §7.1 name, "Team learning · <subject> · <date> · approved by <role>".
        case teamLearning = "team_learning"
    }

    let kind: Kind
    /// The manual's title, or the core file's name.
    let title: String
    /// The printed page number, when the citation names one.
    let page: Int?
    /// The last page of a range the citation names (`pages 64–65`); nil for a single page.
    let throughPage: Int?
    /// "Figure 58" / "Table 16", when the citation names a caption.
    let figure: String?
    /// The `§Section` a prose passage was cited by.
    let section: String?
    /// A drawing with no caption — cited `page 44 (diagram)`.
    let isDiagram: Bool
    /// The label printed on the page, kept only when it is all the citation says about where to
    /// look (`Title, printed page 2-6`), so opening it can go through the manual's page labels
    /// rather than to page 1. Nil beside a `page`, which is the place to open (Plan KE).
    let printedPage: String?

    init(kind: Kind, title: String, page: Int? = nil, throughPage: Int? = nil, figure: String? = nil,
         section: String? = nil, isDiagram: Bool = false, printedPage: String? = nil) {
        self.kind = kind
        self.title = title
        self.page = page
        self.throughPage = (page != nil && (throughPage ?? 0) > (page ?? 0)) ? throughPage : nil
        self.figure = figure
        self.section = section
        self.isDiagram = isDiagram
        self.printedPage = page == nil ? printedPage : nil
    }

    /// The citation as the answer printed it, rebuilt from the parts — so a chip can never show a
    /// document the answer did not name.
    var label: String {
        var parts = [title]
        if let page, let throughPage {
            parts.append("pages \(page)\u{2013}\(throughPage)")
        } else if let page {
            parts.append("page \(page)")
        } else if let printedPage {
            parts.append("printed page \(printedPage)")
        }
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

    /// The badge flag the phone reads: this citation is a team learning, not the manual.
    var isTeamLearning: Bool { kind == .teamLearning }

    /// What the chip says. The same words, because the technician is checking the chip against the
    /// sentence above it.
    var chipLabel: String { label }
}

/// Turns an answer's `Source:` lines into citations (Plan EK P3).
///
/// Pure and total: anything it cannot read is left alone rather than guessed at, because a chip
/// that opens the wrong page is worse than no chip. It reads the two shapes the app itself
/// produces — `VaultRetriever.Passage.citation` on its own line, and a vault tool's trailing
/// `(Source: error_codes.md, models.md)` — and what a model does with them in an answer (Plan KE):
/// two `Source:` markers on one line, prose running on after the citation, and "PDF page N" with
/// "printed page M" and "Step N" beside it.
enum CitationLineParser {

    /// Extensions that mean a core file rather than a manual title.
    static let coreFileExtensions: Set<String> = ["md", "markdown", "txt"]

    /// Longest a title may be before it is read as a sentence that happens to follow the word
    /// "Source" rather than as the name of a document.
    static let maxTitleLength = 120

    /// What a model writes where a source would go when it has none. Not a document, so not a door.
    static let nonCitations: Set<String> = ["none", "n/a", "na", "unknown", "-", "\u{2014}"]

    /// Words a title or a section may end a piece of with, with the sentence carrying on after the
    /// full stop: "Acme Corp. Service Manual", "Service Bulletin No. A123".
    static let abbreviations: Set<String> = [
        "approx", "assy", "bros", "bull", "ch", "co", "corp", "dept", "doc", "dr", "ed", "eq", "fig",
        "figs", "gen", "inc", "inst", "intl", "jr", "ltd", "mfg", "mfr", "mr", "mrs", "ms", "mt", "no",
        "nos", "p", "pp", "pg", "pgs", "pt", "ref", "rev", "sec", "sect", "sr", "st", "std", "supp",
        "tab", "tech", "ver", "vers", "vol", "vs",
    ]

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
        sourceBodies(of: line).flatMap(citations(inBody:))
    }

    /// The text the line's first `Source:` marker introduces, or the first that says anything. Nil
    /// when the line cites nothing.
    static func sourceBody(of line: String) -> String? { sourceBodies(of: line).first }

    /// What each of a line's `Source:` markers introduces, with the parenthesised form closed off,
    /// the scan-provenance note removed and any prose after the citation dropped. A second marker
    /// starts a new body: read through, a model's two markers on one line made one 140-character
    /// title, which matched no manual and was reported as removed from the vault (Plan KE).
    static func sourceBodies(of line: String) -> [String] {
        // On the line itself rather than a lowercased copy: lowercasing can change a string's
        // length, and an index from the copy would then cut the wrong characters. Not mid-word, so
        // "Resources: 2" is not a citation.
        let pattern = #"(?i)(?<![\p{L}\p{N}])sources?:"#
        var markers: [Range<String.Index>] = []
        var searchFrom = line.startIndex
        while let found = line.range(of: pattern, options: .regularExpression, range: searchFrom..<line.endIndex) {
            markers.append(found)
            searchFrom = found.upperBound
        }
        return markers.indices.compactMap { index in
            let end = index + 1 < markers.count ? markers[index + 1].lowerBound : line.endIndex
            var body = String(line[markers[index].upperBound..<end]).trimmingCharacters(in: .whitespaces)
            let before = line[line.startIndex..<markers[index].lowerBound].trimmingCharacters(in: .whitespaces)
            // `(Source: a.md, b.md)` — the tools' inline suffix, closed by its own bracket, so a
            // `(diagram)` inside the citation survives and a bracket later in the prose does not count.
            if before.hasSuffix("("), let close = closingBracket(in: body) {
                body = String(body[body.startIndex..<close])
            }
            body = stripProvenanceNote(body)
            body = closingSentence(body)
            let trimmed = body.trimmingCharacters(in: CharacterSet(charactersIn: " \t.;("))
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// The bracket that closes one already open before `body` starts; the last one when the body's
    /// brackets do not balance.
    private static func closingBracket(in body: String) -> String.Index? {
        var depth = 1
        for index in body.indices {
            if body[index] == "(" { depth += 1 }
            if body[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return body.lastIndex(of: ")")
    }

    /// Drop the sentence a recognised-from-a-scan passage carries after its citation. It is a
    /// warning about the page, not part of the page's name. The model writes it in either spelling.
    static func stripProvenanceNote(_ body: String) -> String {
        guard let start = body.range(of: #"(?i)\(text recogni[sz]ed"#, options: .regularExpression) else { return body }
        return String(body[body.startIndex..<start.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// The body up to the end of its first sentence, so the prose after a citation is never read as
    /// a title: "Step 9. The manual's listed coverage includes X" made a chip of its own.
    ///
    /// A title and a section can hold full stops, so one ends the citation only where it can only
    /// be a sentence's: after a place in the document (a page, a step, a caption), unless another
    /// place follows; or after any other word that is not an abbreviation, with a capital next.
    /// A full stop inside brackets is never the end. The names the app builds itself with `·`
    /// separators are read whole, as they always were: a subject in one may hold a sentence.
    static func closingSentence(_ body: String) -> String {
        guard !isStructuredName(body) else { return body }
        var depth = 0
        for index in body.indices {
            if body[index] == "(" { depth += 1 }
            if body[index] == ")" { depth = max(0, depth - 1) }
            guard body[index] == ".", depth == 0 else { continue }
            let after = body.index(after: index)
            guard after < body.endIndex, body[after].isWhitespace else { continue }
            let head = String(body[body.startIndex..<index])
            let tail = body[after...].trimmingCharacters(in: .whitespaces)
            guard !tail.isEmpty else { continue }
            if endsSentence(head: head, tail: tail) { return head }
        }
        return body
    }

    private static func isStructuredName(_ body: String) -> Bool {
        body.contains(TeamLearningCitation.prefix) || body.hasPrefix("Photographed manual · ")
            || body.hasPrefix("Reviewed photographed manual · ")
    }

    private static func endsSentence(head: String, tail: String) -> Bool {
        func pieces(_ text: String) -> [String] {
            text.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let parts = pieces(head)
        let tailParts = pieces(tail)
        guard let part = parts.last, let firstOfTail = tailParts.first else { return false }
        if isPlace(firstOfTail) { return false }
        if isPlace(part) { return true }
        // Still in the title, with a page straight after the next piece: a title with a full stop
        // in it ("Acme QX100. Service Manual, page 3"), not a sentence that happens to be followed
        // by one. Prose after a citation has already passed a place, or never reaches one.
        if parts.count == 1, tailParts.count > 1, isPlace(tailParts[1]) { return false }
        let word = String(part.split(whereSeparator: \.isWhitespace).last ?? "")
        let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "§(")).lowercased()
        // "U.S" of "U.S. Standard", and any lone letter.
        let isInitials = bare.range(of: #"^(?:\p{L}\.)*\p{L}$"#, options: .regularExpression) != nil
        guard !abbreviations.contains(bare), !isInitials else { return false }
        return tail.first?.isUppercase == true
    }

    /// Whether a piece of a citation is only a place in a document, nothing after it but a bracket.
    private static func isPlace(_ part: String) -> Bool {
        part.range(of: #"(?i)^\(?(?:(?:pdf\s+)?pages?\s+\d[\d\s\-\x{2013}\x{2014}]*|(?:pdf\s+)?pp?\.\s*\d[\d\s\-\x{2013}\x{2014}]*"#
            + #"|printed\s+(?:pages?|p\.|pg\.?)\s*\S+|(?:figure|table)\s+\d+[a-z]?|steps?\s+\d+[a-z]?)\s*(?:\(.*\))?\)?$"#,
            options: .regularExpression) != nil
    }

    /// Split one `Source:` body into citations. A manual citation carries commas of its own
    /// (`Title, page 44, Figure 58`), so the parts are grouped rather than split: a part that names
    /// a page, a caption or a section belongs to the citation before it, and anything else starts
    /// a new one. "printed page M" and "Step N" belong to the citation before them and are never a
    /// citation of their own (Plan KE).
    ///
    /// Semicolons separate citations. Read as commas, "Installation Instructions, page 47; Service
    /// Manual, page 20" lost the second title inside "page 47; Service Manual" and the last page
    /// overwrote the first: a tester's job saved "Installation Instructions, page 20", a page the
    /// answer never cited. A group that opens on a page carries the title before it ("Service
    /// Manual, page 20; page 21"), and a second page for one title is a second citation.
    static func citations(inBody body: String) -> [Citation] {
        // A team learning's name is cited whole: everything from its prefix to the end of the line
        // is one citation, so a comma in the approver's role cannot split it into a "manual".
        if let start = body.range(of: TeamLearningCitation.prefix) {
            let before = String(body[body.startIndex..<start.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t.;,"))
            let name = String(body[start.lowerBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " \t.;"))
            return (before.isEmpty ? [] : citations(inBody: before))
                + [Citation(kind: .teamLearning, title: name)]
        }
        var found: [Citation] = []
        var title: String?
        var lastTitle: String?
        var page: Int?
        var throughPage: Int?
        var figure: String?
        var section: String?
        var isDiagram = false
        var printedPage: String?

        func flush() {
            defer {
                title = nil; page = nil; throughPage = nil; figure = nil; section = nil
                isDiagram = false; printedPage = nil
            }
            guard let name = title?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  validTitleLength(name), !nonCitations.contains(name.lowercased()) else { return }
            found.append(Citation(kind: isCoreFileName(name) ? .coreFile : .manual,
                                  title: name, page: page, throughPage: throughPage, figure: figure,
                                  section: section, isDiagram: isDiagram, printedPage: printedPage))
        }

        let groups = separatingPlaces(in: body).components(separatedBy: ";")
        for group in groups {
            flush()
            for (index, raw) in group.components(separatedBy: ",").enumerated() {
            let part = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t.;"))
            guard !part.isEmpty else { continue }
            // Before anything else, and without reaching back for a title: a place that adds only a
            // label to a citation is not a new door.
            if let label = printedLabel(part) {
                if title != nil, printedPage == nil { printedPage = label }
                continue
            }
            if isStep(part, inCitation: title != nil) { continue }
            let attaches = pageNumber(part) != nil || part.hasPrefix("§") || isCaption(part)
                || part.lowercased() == "(diagram)"
            if index == 0, attaches, title == nil, let lastTitle { title = lastTitle }
            if let (number, through, diagram) = pageRange(part) {
                if title == nil { continue }   // "page 4" with nothing to belong to
                if page != nil {               // a second page for the same title: its own citation
                    let same = title
                    flush()
                    title = same
                }
                page = number
                throughPage = through
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
                lastTitle = part
            }
            }
        }
        flush()
        return found
    }

    // MARK: - Parts

    /// Capture citations carry immutable identity/digest as well as a human title and job/date.
    /// Resolution still requires an exact saved manifest; a long ordinary sentence is not a chip.
    static func validTitleLength(_ name: String) -> Bool {
        if name.count <= maxTitleLength { return true }
        if name.hasPrefix("Reviewed photographed manual · "),name.utf8.count <= 1_200 {return true}
        return name.utf8.count <= 700 && name.hasPrefix("Photographed manual · ")
            && name.range(of:#" · capture [A-Za-z0-9_-]+/[1-9][0-9]*/[a-f0-9]{64}$"#,
                          options:.regularExpression) != nil
    }

    /// `page 44`, or `page 44 (diagram)`. Returns the number and whether the drawing marker rode
    /// along with it.
    static func pageNumber(_ part: String) -> (page: Int, isDiagram: Bool)? {
        pageRange(part).map { ($0.page, $0.isDiagram) }
    }

    /// `page 44`, `pages 64–65`, `pp. 64-65`, `PDF page 63`: the first page, the last when it is a
    /// range, and the drawing marker. "PDF page" is how an answer writes the place to open, and read
    /// as nothing the citation had no page and opened page 1 (Plan KE).
    static func pageRange(_ part: String) -> (page: Int, through: Int?, isDiagram: Bool)? {
        var lower = part.lowercased()
        if lower.hasPrefix("pdf ") { lower.removeFirst(4) }
        guard lower.hasPrefix("page ") || lower.hasPrefix("pages ") || lower.hasPrefix("p. ")
                || lower.hasPrefix("pp. ") else { return nil }
        guard let match = part.range(of: #"\d+"#, options: .regularExpression),
              let number = Int(part[match]) else { return nil }
        var through: Int?
        let rest = part[match.upperBound...]
        if let range = rest.range(of: #"^\s*(?:-|\u{2013}|\u{2014}|to)\s*(\d+)"#, options: .regularExpression),
           let last = rest[range].range(of: #"\d+"#, options: .regularExpression) {
            through = Int(rest[range][last])
        }
        return (number, through, lower.contains("(diagram)"))
    }

    /// `printed page 2-6`: the label printed on a page, as `Citation.printedPage` keeps it. The
    /// bracket is there when the part was split out of `(printed page 57, Step 4)`.
    static func printedLabel(_ part: String) -> String? {
        let pattern = #"(?i)^\(?printed\s+(?:pages?|p\.|pg\.?)\s*"#
        guard let prefix = part.range(of: pattern, options: .regularExpression) else { return nil }
        let label = part[prefix.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " \t.;()"))
        return label.isEmpty ? nil : label
    }

    /// `Step 4`, after a citation or standing alone. A title can start the same way ("Step 4
    /// Commissioning Checklist"), so with no citation open only the bare step counts.
    static func isStep(_ part: String, inCitation: Bool) -> Bool {
        let pattern = inCitation ? #"(?i)^\(?steps?\s+\d"# : #"(?i)^\(?steps?\s+\d+[a-z]?\)?$"#
        return part.range(of: pattern, options: .regularExpression) != nil
    }

    /// The body with "PDF page" and "printed page" made a part of their own when they follow a
    /// title with no comma: `Service Manual (PDF page 63)`, `Service Manual PDF page 63`. The
    /// bracket that closes them is left to the page reader, which ignores it.
    private static func separatingPlaces(in body: String) -> String {
        body.replacingOccurrences(of: #"(?i)(?<=[^\s,;(])\s*(?:\s|\()(?=(?:pdf|printed)\s+pages?\s+\d)"#,
                                  with: ", ", options: .regularExpression)
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
