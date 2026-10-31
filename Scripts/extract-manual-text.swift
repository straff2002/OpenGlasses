#!/usr/bin/env swift
import Foundation
import PDFKit
import Vision
import AppKit
import CryptoKit

// Avenkin compiles this source into a bundled worker; users need no Swift toolchain.
let officeWorker = CommandLine.arguments.contains("--office-worker")
let officeOutputLimit = 2 * 1024 * 1024
struct OfficeProgress: Encodable {
    let page: Int
    let pages: Int
}
func officeProgress(page: Int, pages: Int) {
    guard officeWorker, let data = try? JSONEncoder().encode(OfficeProgress(page: page, pages: pages)) else { return }
    FileHandle.standardOutput.write(data + Data([10]))
}

// Extracts a manual's text on a Mac, page by page, for a vault's documents tier — so a pack or a
// customer folder can ship pre-extracted text and the phone never pays for recognition.
//
//   ./Scripts/extract-manual-text.swift <manual.pdf> [output.md] [--dpi 200] [--lang en,fr] [--force-ocr]
//   ./Scripts/extract-manual-text.swift --self-check
//
// Pages with a text layer are copied with their structure marked; pages without one are rendered at
// --dpi and read with Apple Vision. The output is Markdown with a "Page N" marker line before each
// page, which the app's chunker reads as a page boundary, so citations still say "page 42". Written
// as a whole line and as plain text on purpose: Route C of the vault guide exists so a human can
// open the result and correct a misread figure before anyone relies on it.
//
// Structure comes from type, not from the words: a manual's real headings are bold at body size and
// often mixed case, its captions are bold and start "FIGURE 58", and a drawing is a page of labels
// set below body size with no sentences in it. Those become "## Heading", "### Figure 58 — Title"
// and a "<!-- page: diagram -->" tag, which is the same grammar the app's own PDF extractor emits,
// so a hand-corrected file and a machine-read one reach the chunker looking alike.
//
// Printed on stderr: how many pages were recognised, how many came out low confidence, and how
// many pages printed their own page number where that number disagrees with the PDF's page index.
// A manual with an unnumbered cover or roman-numeral front matter is the usual cause; the app
// always cites the physical page, so either fix the PDF or accept that citations name the page you
// reach by counting from the front.
//
// `--self-check` runs the page-marker, structure and manifest-hint rules over synthetic inputs and
// exits non-zero on a mismatch — the script has no test target, so this is what CI can run.
//
// Copyright note: only ship extracted text for manuals you are licensed to redistribute.

let usage = """
usage: extract-manual-text.swift <manual.pdf> [output.md] [--dpi 200] [--lang en,fr] [--force-ocr]
       extract-manual-text.swift --self-check

  --dpi N        render resolution for pages without a text layer (72–600, default 200)
  --lang a,b     recognition languages, most likely first (default en)
  --force-ocr    recognise every page, even one that already has a text layer
  --self-check   run the page-marker, structure and manifest-hint rules over synthetic inputs and exit
"""

func fail(_ message: String) -> Never {
    if officeWorker, CommandLine.arguments.count == 5,
       let data = try? JSONEncoder().encode(["error": message]) {
        try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[4]), options: .atomic)
    }
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - Page markers and manifest hints (the rules --self-check exercises)

/// The page number a whole-line page marker denotes ("Page 42", "- 42 -"), else nil.
///
/// Deliberately the same rule as the app's `DocumentChunker.pageNumber(in:)`: the whole trimmed
/// line must be the marker. A prefix match would treat a wrapped contents line ("Page 62 VII
/// Typical Operating Characteristics") as a page break, and the two halves of Route C — this
/// script and the chunker that reads its output — have to agree on what a marker is.
func printedPageNumber(in line: String) -> Int? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let isMarker = trimmed.range(of: #"^page\s+\d{1,4}$"#, options: [.regularExpression, .caseInsensitive]) != nil
        || trimmed.range(of: #"^-\s*\d{1,4}\s*-$"#, options: .regularExpression) != nil
    guard isMarker,
          let digits = trimmed.range(of: #"\d+"#, options: .regularExpression),
          let number = Int(trimmed[digits]), number > 0, number < 10000 else { return nil }
    return number
}

/// The first line of a page's text that is not blank, trimmed. Nil for a blank page.
func firstNonEmptyLine(of text: String) -> String? {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .lazy
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
}

/// The number a page prints for itself when it disagrees with its position in the PDF, else nil.
///
/// Only the page's own first line counts: a running header is printed at the top, and a "page 12"
/// buried in a cross-reference means nothing about which page this is.
func numberingMismatch(pageText: String, physicalPage: Int) -> Int? {
    guard let first = firstNonEmptyLine(of: pageText),
          let printed = printedPageNumber(in: first),
          printed != physicalPage else { return nil }
    return printed
}

/// The manifest `kind` a file name implies. A guess, printed as part of a hint the author edits.
func manualKind(forFileName name: String) -> String {
    let lower = name.lowercased()
    if lower.contains("install") { return "install_guide" }
    if lower.contains("wiring") { return "wiring" }
    if lower.contains("parts") { return "parts_list" }
    return "service_manual"
}

/// A manifest `title` suggestion: the file name with hyphens and underscores as spaces.
func titleSuggestion(forFileName name: String) -> String {
    let spaced = name
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
    return spaced.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
}

// MARK: - Structure from type (the rules the app's `ManualStructure` mirrors)

/// One line of a page with the type it was set in. `size` is 0 when the line carried no font
/// information at all, which never reads as a heading.
struct TypedLine {
    let raw: String
    let text: String
    let size: Double
    let bold: Bool
}

/// A page's lines plus the character histogram the body-size and diagram rules need.
struct TypedPage {
    let lines: [TypedLine]
    /// Non-whitespace characters by rounded point size.
    let sizes: [Int: Int]
}

let labelWords = "FIGURE|TABLE|NOTE|NOTES|NOTICE|WARNING|CAUTION|DANGER|IMPORTANT"

/// A numbered line that is a list step or a spec-table row rather than a heading; the separator
/// after the number is what tells them apart. Same set as the app's chunker uses.
let numberedNonHeading = [
    #"^\d+(\.\d+)*\s+[-\u{2013}\u{2014}]\s"#,   // 4 - Go to setup / system devices
    #"^\d+(\.\d+)*\s*\)"#,                     // 1) Remove the burner box cover
    #"^\d+(\.\d+)*\.?\s+\p{Ll}"#                // 2.6 or greater
]

/// The document-wide body size: the character-weighted modal point size, rounded to whole points.
/// Document-wide and not per page on purpose — a diagram page's own mode is its labels.
func bodySize(of pages: [TypedPage]) -> Int {
    var merged: [Int: Int] = [:]
    for page in pages { for (size, count) in page.sizes { merged[size, default: 0] += count } }
    guard let best = merged.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key else { return 0 }
    return best
}

/// A parenthetical qualifier set on its own line under a heading or a caption
/// ("(shown in upflow position)"). Never a heading on its own — it belongs to the line above.
func isParentheticalQualifier(_ line: TypedLine, bodySize: Int) -> Bool {
    line.bold && bodySize > 0 && line.size >= Double(bodySize) - 0.5
        && line.text.hasPrefix("(") && line.text.count <= 80
}

/// Whether a line reads as a section heading: bold, at least body size, short enough to say, and
/// none of the things an OEM manual sets in bold that are not places — a caption or safety label,
/// a sentence, a bare callout number, the publisher's own page header.
/// Whether a line opens in a script without case (the app's `ManualStructure.isCaseless`).
func isCaseless(_ text: String) -> Bool {
    guard let letter = text.first(where: \.isLetter) else { return false }
    return !letter.isUppercase && !letter.isLowercase
}

func isStructuralHeading(_ line: TypedLine, bodySize: Int) -> Bool {
    let text = line.text
    // A script without case (Plan JY P4): no capital to open with, and a heading may be set larger
    // rather than bolder.
    let caseless = isCaseless(text)
    guard line.bold || (caseless && line.size >= Double(bodySize) * 1.2),
          bodySize > 0, line.size >= Double(bodySize) - 0.5 else { return false }
    guard text.count >= 2, text.count <= 80 else { return false }
    guard text.contains(where: { $0.isLetter }) else { return false }          // "1", "2", "3 4"
    guard !text.hasPrefix("(") else { return false }   // a qualifier belongs to the heading above it
    // A heading opens; it does not continue. A line that starts lower case or ends on a broken
    // word or an unfinished clause is the middle of a paragraph that happens to be set in bold.
    guard let first = text.first, first.isUppercase || first.isNumber || caseless else { return false }
    guard let tail = text.last, !",;:-\u{2013}\u{2014}/&+".contains(tail) else { return false }
    if caseless {
        guard !"，、；：".contains(tail), !text.contains(where: { "。！？".contains($0) }) else { return false }
    }
    guard text.range(of: "^(\(labelWords))\\b", options: [.regularExpression, .caseInsensitive]) == nil else { return false }
    // A numbered procedure step is a step whatever weight it is set in, and this class of manual
    // sets them in bold: "4 - Go to setup / system devices / thermostat".
    for pattern in numberedNonHeading where text.range(of: pattern, options: .regularExpression) != nil { return false }
    guard let last = text.last, !".!?:".contains(last) else { return false }
    guard printedPageNumber(in: text) == nil else { return false }
    return true
}

/// The caption a line carries ("Figure 58", "Table 16") and whatever title follows it on the same
/// line, else nil. Captions are bold; the number is what separates a caption from a cross-reference.
func captionLabel(_ line: TypedLine) -> (label: String, inlineTitle: String)? {
    guard line.bold else { return nil }
    let text = droppingMarginMarks(line.text)
    // The label as printed, a letter beside the number and its dotted parts included (the app's
    // `TableExtractor.labelPattern`, Plan JY P5a).
    let labelPattern = #"(?:[A-Z]{1,2}\d{1,4}|\d{1,4})(?:\.\d{1,4}){0,6}(?:[A-Za-z](?![\p{L}\p{N}]))?"#
    guard let match = text.range(of: #"^(?i:FIGURE|TABLE)\s+"# + labelPattern, options: .regularExpression) else {
        return CaptionWords.match(text).map { ($0.label, $0.title) }
    }
    let head = String(text[match])
    let word = head.range(of: "^FIGURE", options: [.regularExpression, .caseInsensitive]) != nil ? "Figure" : "Table"
    let number = head.range(of: labelPattern + "$", options: .regularExpression).map { String(head[$0]) } ?? ""
    let rest = String(text[match.upperBound...])
        .trimmingCharacters(in: CharacterSet(charactersIn: " \t.:—–-"))
    return ("\(word) \(number)", rest)
}

/// A revision mark in the margin on a caption's line — a word of no letter or digit (a triangle, a
/// bar, an arrow, a bullet) or a Greek capital delta, standing apart or glued to the caption's first
/// word — dropped before the caption rule reads it. The app's `TableExtractor.droppingMarginMarks`.
func droppingMarginMarks(_ text: String) -> String {
    let notMark: Set<Character> = ["(", "[", "{", "\"", "'", "\u{201C}", "\u{2018}", "*", "\u{2020}", "\u{2021}"]
    func isMark(_ c: Character) -> Bool {
        c == "\u{0394}" || (!c.isLetter && !c.isNumber && !c.isWhitespace && !notMark.contains(c))
    }
    var rest = Substring(text).drop(while: \.isWhitespace)
    while let word = rest.split(whereSeparator: \.isWhitespace).first, word.allSatisfy(isMark) {
        rest = rest[word.endIndex...].drop(while: \.isWhitespace)
    }
    let glued = rest.prefix(while: isMark)
    if !glued.isEmpty, rest.dropFirst(glued.count).first?.isLetter == true { rest = rest.dropFirst(glued.count) }
    return String(rest)
}

/// Whether a page is a drawing rather than prose: most of its characters are set below body size
/// and it has next to no sentences. A table page meets both tests and that is accepted — a table is
/// read as a figure too, and its rows still reach exact-token search.
func isDiagramPage(_ page: TypedPage, bodySize: Int) -> Bool {
    let total = page.sizes.values.reduce(0, +)
    guard total > 0, bodySize > 0 else { return false }
    let small = page.sizes.filter { $0.key < bodySize }.values.reduce(0, +)
    guard Double(small) >= 0.6 * Double(total) else { return false }
    let terminators = page.lines.reduce(0) { $0 + $1.text.filter { ".!?".contains($0) }.count }
    return terminators * 200 < total
}

/// Whether the bold line at `index` stands on its own rather than being one line of a paragraph
/// that happens to be set in bold — which is how this class of manual sets its warnings, and which
/// wraps over four or five lines that each look like a heading in isolation.
///
/// A caption is not a continuation (it is its own structure) and neither is the parenthetical
/// qualifier the heading absorbs; anything else bold at body size, immediately above or below,
/// means this line is in the middle of something.
func standsAlone(at index: Int, in lines: [TypedLine], bodySize: Int) -> Bool {
    func isRun(_ i: Int) -> Bool {
        guard i >= 0, i < lines.count else { return false }
        let line = lines[i]
        guard !line.text.isEmpty else { return false }
        guard line.bold, line.size >= Double(bodySize) - 0.5 else { return false }
        // The publisher's own running header sits above the first heading on the page and is set in
        // the same bold; it is furniture, not the paragraph this line belongs to.
        guard printedPageNumber(in: line.text) == nil else { return false }
        return captionLabel(line) == nil
    }
    func previousNonEmpty(from i: Int) -> Int? {
        var j = i - 1
        while j >= 0, lines[j].text.isEmpty { j -= 1 }
        return j >= 0 ? j : nil
    }
    func nextNonEmpty(from i: Int) -> Int? {
        var j = i + 1
        while j < lines.count, lines[j].text.isEmpty { j += 1 }
        return j < lines.count ? j : nil
    }
    if let previous = previousNonEmpty(from: index), isRun(previous) { return false }
    var after = nextNonEmpty(from: index)
    // The heading may absorb one parenthetical qualifier; what follows *that* is the test.
    if let candidate = after, isParentheticalQualifier(lines[candidate], bodySize: bodySize) {
        after = nextNonEmpty(from: candidate)
    }
    if let following = after, isRun(following) { return false }
    return true
}

let diagramMarker = "<!-- page: diagram -->"

/// A page rewritten in the structured grammar the chunker reads: `## Heading`, `### Figure 58 —
/// Title`, and a `<!-- page: diagram -->` tag on a drawing. Every other line is passed through
/// unchanged — the grammar annotates the text, it does not replace it.
func structuredPageText(_ page: TypedPage, bodySize: Int) -> (text: String, headings: Int, isDiagram: Bool) {
    var out: [String] = []
    var headings = 0
    let diagram = isDiagramPage(page, bodySize: bodySize)
    var hoisted: Int? = nil
    if diagram {
        out.append(diagramMarker)
        // A drawing is one picture, and its caption names the page rather than a point inside it:
        // the labels around it come out of the PDF in no useful order, and the figure a citation
        // names has to be the one the reader sees when they turn to the page. So the page's own
        // caption — its FIGURE if it has one, otherwise its first TABLE — is written at the top,
        // where every chunk of the page inherits it.
        hoisted = page.lines.firstIndex { captionLabel($0)?.label.hasPrefix("Figure") == true }
            ?? page.lines.firstIndex { captionLabel($0) != nil }
        if let index = hoisted, let caption = captionLabel(page.lines[index]) {
            var title = caption.inlineTitle
            if title.isEmpty, index + 1 < page.lines.count {
                let next = page.lines[index + 1]
                if next.bold, !next.text.isEmpty, next.text.count <= 80, captionLabel(next) == nil { title = next.text }
            }
            out.append(title.isEmpty ? "### \(caption.label)" : "### \(caption.label) — \(title)")
        }
    }

    var index = 0
    while index < page.lines.count {
        let line = page.lines[index]
        if index == hoisted {
            // Already written at the top of the page; its title line goes with it.
            if index + 1 < page.lines.count, captionLabel(page.lines[index]) != nil,
               captionLabel(page.lines[index])?.inlineTitle.isEmpty == true {
                let next = page.lines[index + 1]
                if next.bold, !next.text.isEmpty, next.text.count <= 80, captionLabel(next) == nil { index += 1 }
            }
            index += 1
            continue
        }
        if let caption = captionLabel(line) {
            var title = caption.inlineTitle
            if title.isEmpty, index + 1 < page.lines.count {
                let next = page.lines[index + 1]
                if next.bold, !next.text.isEmpty, next.text.count <= 80, captionLabel(next) == nil {
                    title = next.text
                    index += 1
                }
            }
            if !title.isEmpty, index + 1 < page.lines.count,
               isParentheticalQualifier(page.lines[index + 1], bodySize: bodySize) {
                title += " " + page.lines[index + 1].text
                index += 1
            }
            out.append(title.isEmpty ? "### \(caption.label)" : "### \(caption.label) — \(title)")
            index += 1
            continue
        }
        if isStructuralHeading(line, bodySize: bodySize), standsAlone(at: index, in: page.lines, bodySize: bodySize) {
            var text = line.text
            // A parenthetical qualifier on its own line is the second half of the heading above it
            // ("PRESSURE SWITCH TUBING INSTALLATION" / "(shown in upflow position)").
            if index + 1 < page.lines.count, isParentheticalQualifier(page.lines[index + 1], bodySize: bodySize) {
                text += " " + page.lines[index + 1].text
                index += 1
            }
            out.append("## \(text)")
            headings += 1
            index += 1
            continue
        }
        out.append(line.raw)
        index += 1
    }
    return (out.joined(separator: "\n"), headings, diagram)
}

// MARK: - Caption words in other languages (a copy of the app's `CaptionWords`, Plan JY P4)

enum CaptionWords {

    enum Kind: Equatable { case table, figure }

    struct Match: Equatable {
        let kind: Kind
        /// "Table 7", "Figure 3A": the canonical label.
        let label: String
        /// What follows the label on the line, continuation words removed, trimmed.
        let title: String
        /// Whether the caption carries on a table begun on an earlier page.
        let continues: Bool
    }

    private static let label = #"(?:[A-Z]{1,2}\d{1,4}|\d{1,4})(?:\.\d{1,4}){0,6}(?:[A-Za-z](?![\p{L}\p{N}]))?"#
    /// After a CJK caption's label: not a Han, kana or Hangul letter.
    private static let notIntoCJK = #"(?![\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}])"#

    private static let tableWords = #"Tabelle|Tableau|Tabla|Tabella|Tabel|Tabela|Quadro|Таблица|Таблиця|(?:ال)?جدول(?:\s+رقم)?"#
    private static let figureWords = #"Abbildung|Abb\.|Figura|Figuur|Afbeelding|Rysunek|Rys\.|Рисунок|Рис\.|(?:ال)?شكل|شکل"#
    private static let carriedTableWords = #"Fortsetzung\s+(?:der\s+|von\s+)?Tabelle|Продолжение\s+таблицы|Окончание\s+таблицы|Продовження\s+таблиці|Закінчення\s+таблиці|تابع\s+(?:ال)?جدول"#

    /// Each form: its regex (the label in group 1), its kind, and whether the form itself says the
    /// table carries on.
    private static let forms: [(pattern: String, kind: Kind, carried: Bool)] = [
        (#"^(?:续表|續表)\s*("# + label + ")" + notIntoCJK, .table, true),
        (#"^(?:表|표)\s*("# + label + ")" + notIntoCJK, .table, false),
        (#"^(?:图|圖|図|그림)\s*("# + label + ")" + notIntoCJK, .figure, false),
        (#"^(?i:"# + carriedTableWords + #")\s+("# + label + ")", .table, true),
        (#"^(?i:"# + tableWords + #")\s+\(?("# + label + ")", .table, false),
        (#"^(?i:"# + figureWords + #")\s*("# + label + ")", .figure, false),
        (#"^("# + label + #")\.?\s+(?i:táblázat)"#, .table, false),
        (#"^("# + label + #")\.?\s+(?i:ábra)"#, .figure, false)
    ]

    private static let carryingWords = #"Fortsetzung|suite|continuación|continuação|continua|segue|vervolg|ciąg dalszy|folytatás|продолжение|продовження|تابع|جاری|続き|계속|Schluss|fin|conclusión|окончание|закінчення|Forts|продолж|продовж|оконч"#
    /// The words distinctive enough to say it unbracketed, at the end of the title.
    private static let bareCarryingWords = #"Fortsetzung|continuación|continuação|ciąg dalszy|folytatás|продолжение|продовження|окончание|закінчення"#
    /// A carrying-on word in brackets anywhere in the title, or ending it.
    private static let carryingPatterns = [
        #"[\(\[（]\s*(?i:"# + carryingWords + #")\.?\s*[\)\]）]"#,
        #"(?:^|[\s,\u{2013}\u{2014}-])(?i:"# + bareCarryingWords + #")\.?\s*$"#
    ]
    private static let compiled: [(regex: NSRegularExpression, kind: Kind, carried: Bool)] = forms.compactMap { form in
        (try? NSRegularExpression(pattern: form.pattern)).map { ($0, form.kind, form.carried) }
    }

    /// The caption a line starts with in a language other than English, else nil.
    static func match(_ text: String) -> Match? {
        for form in compiled {
            guard let found = form.regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let whole = Range(found.range, in: text), let number = Range(found.range(at: 1), in: text) else { continue }
            var title = String(text[whole.upperBound...])
            var continues = form.carried
            for pattern in carryingPatterns {
                if let range = title.range(of: pattern, options: .regularExpression) {
                    continues = true
                    title.removeSubrange(range)
                }
            }
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: " \t.:\u{2014}\u{2013}-\u{FF1A}\u{3001})）"))
            let word = form.kind == .table ? "Table" : "Figure"
            return Match(kind: form.kind, label: "\(word) \(asciiDigits(String(text[number])))", title: title, continues: continues)
        }
        return nil
    }

    /// Any decimal digit (Arabic-Indic, Extended Arabic-Indic, full-width) read as its ASCII digit.
    static func asciiDigits(_ text: String) -> String {
        String(text.map { character -> Character in
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
                  scalar.properties.numericType == .decimal, let value = scalar.properties.numericValue,
                  !(0x30...0x39).contains(scalar.value) else { return character }
            return Character(String(Int(value)))
        })
    }
}

// MARK: - Fake bold (the app's `OverprintedText`, Plan JY P4)

/// Whether a character is a Han, kana or Hangul letter (the app's `TextScript.isCJK`).
func isCJKLetter(_ character: Character) -> Bool {
    guard character.isLetter, let v = character.unicodeScalars.first?.value else { return false }
    switch v {
    case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F,                                  // kana
         0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7FF, 0xFFA0...0xFFDC,  // Hangul
         0x2E80...0x2FDF, 0x3005, 0x3007, 0x3021...0x3029, 0x3038...0x303B, 0x3400...0x4DBF,
         0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3FFFF:                                 // Han
        return true
    default: return false
    }
}

/// Ideographic and full-width punctuation.
func isCJKPunctuation(_ character: Character) -> Bool {
    guard !character.isLetter, !character.isNumber, let v = character.unicodeScalars.first?.value else { return false }
    switch v {
    case 0x3001...0x303F, 0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65: return true
    default: return false
    }
}

/// A CJK line printed twice over ("fake bold") reads each character twice. Collapse a run of doubled
/// pairs whose letters are all CJK when it has at least three pairs over three different characters,
/// or a doubled CJK punctuation mark beside a doubled letter. Returns the line and how many
/// characters were overprinted; Latin, Cyrillic and Arabic text is never touched.
///
/// Where the page says where each glyph is drawn (`advance`, ems from a character to the next; the
/// app's `OverprintedText.overprintAdvance`, Plan JY P5a), a run the text rule leaves is decided
/// pair by pair: a CJK pair whose copies start under 0.7 em apart is one glyph printed twice.
func collapsingOverprint(_ line: String, advance: ((Int) -> Double?)? = nil) -> (text: String, overprinted: Int) {
    let c = Array(line)
    guard c.count >= 4 else { return (line, 0) }
    var out: [Character] = []
    var overprinted = 0
    var i = 0
    func qualifies(_ pairs: [Character]) -> Bool {
        guard pairs.count >= 2 else { return false }
        var letters = 0
        for ch in pairs where ch.isLetter {
            guard isCJKLetter(ch) else { return false }
            letters += 1
        }
        guard letters > 0 else { return false }
        let distinct = Set(pairs).count
        if pairs.count >= 3, distinct >= 3 { return true }
        return distinct >= 2 && pairs.contains(where: isCJKPunctuation)
    }
    func printedTwice(_ from: Int, _ to: Int, _ advance: (Int) -> Double?) -> [Bool]? {
        var verdicts: [Bool] = []
        for p in stride(from: from, to: to, by: 2) {
            guard isCJKLetter(c[p]) || isCJKPunctuation(c[p]) else { verdicts.append(false); continue }
            guard let em = advance(p) else { return nil }
            verdicts.append(em < 0.7)
        }
        return verdicts.isEmpty ? nil : verdicts
    }
    while i < c.count {
        var end = i
        while end + 1 < c.count, c[end] == c[end + 1], !c[end].isWhitespace { end += 2 }
        if end > i {
            let pairs = stride(from: i, to: end, by: 2).map { c[$0] }
            if qualifies(pairs) { out.append(contentsOf: pairs); overprinted += pairs.count }
            else if let advance, let twice = printedTwice(i, end, advance) {
                for (k, p) in stride(from: i, to: end, by: 2).enumerated() {
                    out.append(c[p]); if twice[k] { overprinted += 1 } else { out.append(c[p + 1]) }
                }
            }
            else { out.append(contentsOf: c[i..<end]) }
            i = end
        } else {
            out.append(c[i]); i += 1
        }
    }
    return overprinted == 0 ? (line, 0) : (String(out), overprinted)
}

/// Whether most of a collapsed line's letters were overprinted: it was set in (fake) bold.
func isMostlyOverprinted(_ collapsed: (text: String, overprinted: Int)) -> Bool {
    let letters = collapsed.text.filter(\.isLetter).count
    return collapsed.overprinted > 0 && letters > 0 && collapsed.overprinted * 2 >= letters
}

/// Every line of a page's text collapsed.
func collapsingOverprintedLines(_ text: String) -> String {
    guard text.contains(where: isCJKLetter) else { return text }
    return text.split(separator: "\n", omittingEmptySubsequences: false).map { collapsingOverprint(String($0)).text }
        .joined(separator: "\n")
}

// MARK: - Reading type off the page

/// Whether a font is bold. The symbolic trait is the honest answer; a subset font embedded in a
/// PDF often loses it and keeps only its name ("ABCDE+Arial-BoldMT"), so the name is the backstop.
func isBoldFont(_ font: NSFont) -> Bool {
    if font.fontDescriptor.symbolicTraits.contains(.bold) { return true }
    let name = font.fontName.lowercased()
    return ["bold", "black", "heavy", "semibold", "-bd"].contains { name.contains($0) }
}

/// A page's lines with the type each was set in, from the attributed string PDFKit reconstructs.
///
/// A line's size and weight are its *dominant* run by non-whitespace character count, so a heading
/// with one italic word is still a heading and a body line with a bold lead-in is still body.
func typedPage(from attributed: NSAttributedString, glyphs: ((NSRange) -> CGRect?)? = nil) -> TypedPage {
    let ns = attributed.string as NSString
    var runs: [(range: NSRange, size: Double, bold: Bool)] = []
    attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: ns.length)) { value, range, _ in
        guard let font = value as? NSFont else { return }
        runs.append((range, Double(font.pointSize), isBoldFont(font)))
    }

    var lines: [TypedLine] = []
    var sizes: [Int: Int] = [:]
    var start = 0
    var index = 0
    var runIndex = 0

    func emit(_ range: NSRange) {
        let raw = ns.substring(with: range)
        // Weight each (size, bold) pair by the printable characters it covers on this line.
        var weights: [String: (size: Double, bold: Bool, count: Int)] = [:]
        while runIndex < runs.count, NSMaxRange(runs[runIndex].range) <= range.location { runIndex += 1 }
        var scan = runIndex
        while scan < runs.count, runs[scan].range.location < NSMaxRange(range) {
            let run = runs[scan]
            let overlap = NSIntersectionRange(run.range, range)
            if overlap.length > 0 {
                let printable = ns.substring(with: overlap).filter { !$0.isWhitespace }.count
                if printable > 0 {
                    let rounded = Int(run.size.rounded())
                    sizes[rounded, default: 0] += printable
                    let key = "\(rounded)|\(run.bold)"
                    let existing = weights[key] ?? (run.size, run.bold, 0)
                    weights[key] = (existing.size, existing.bold, existing.count + printable)
                }
            }
            scan += 1
        }
        // A tie between a bold and a regular run of one size and count is decided the same way every
        // time (Plan JY P5a): `weights` is a dictionary, whose order is seeded per process, so the
        // tie went either way from one run to the next and a line such as a clause number in bold
        // beside its title in a substituted regular font was a heading in one extraction and not in
        // the next.
        let dominant = weights.values.max { ($0.count, $0.size, $0.bold ? 1 : 0) < ($1.count, $1.size, $1.bold ? 1 : 0) }
        // Fake bold: collapse the doubling, and a line mostly set that way is bold.
        let overprint = collapsingOverprint(raw, advance: glyphs.map { glyphs in
            let offsets = raw.indices.map { range.location + raw.utf16.distance(from: raw.startIndex, to: $0) }
            let lengths = raw.map { $0.utf16.count }
            return { k in
                guard k + 1 < offsets.count else { return nil }
                let first = NSRange(location: offsets[k], length: lengths[k]), second = NSRange(location: offsets[k + 1], length: lengths[k + 1])
                guard NSMaxRange(second) <= attributed.length,
                      let font = attributed.attribute(.font, at: first.location, effectiveRange: nil) as? NSFont, font.pointSize > 0,
                      let a = glyphs(first), let b = glyphs(second), a.width > 0, b.width > 0,
                      abs(a.midY - b.midY) < font.pointSize / 2 else { return nil }
                return Double(b.minX - a.minX) / Double(font.pointSize)
            }
        })
        lines.append(TypedLine(raw: overprint.text,
                               text: overprint.text.trimmingCharacters(in: .whitespacesAndNewlines),
                               size: dominant?.size ?? 0,
                               bold: (dominant?.bold ?? false) || isMostlyOverprinted(overprint)))
    }

    while index < ns.length {
        let ch = ns.character(at: index)
        if ch == 10 || ch == 13 {
            emit(NSRange(location: start, length: index - start))
            if ch == 13, index + 1 < ns.length, ns.character(at: index + 1) == 10 { index += 1 }
            start = index + 1
        }
        index += 1
    }
    if start < ns.length { emit(NSRange(location: start, length: ns.length - start)) }

    return TypedPage(lines: lines, sizes: sizes)
}

func runSelfCheck() -> Never {
    var failures: [String] = []
    func check(_ label: String, _ actual: String, _ expected: String) {
        if actual != expected { failures.append("\(label): expected \(expected), got \(actual)") }
    }
    func marker(_ line: String) -> String { printedPageNumber(in: line).map(String.init) ?? "nil" }
    func mismatch(_ text: String, _ page: Int) -> String {
        numberingMismatch(pageText: text, physicalPage: page).map(String.init) ?? "nil"
    }

    // Marker lines, in the shapes the app's chunker also accepts.
    check("Page 42", marker("Page 42"), "42")
    check("lowercase", marker("page 7"), "7")
    check("padded", marker("   Page 3   "), "3")
    check("dashed", marker("- 12 -"), "12")
    check("dashed tight", marker("-12-"), "12")
    // Near misses. Each of these renumbering a page is a citation the reader cannot turn to.
    check("wrapped contents line", marker("Page 62 VII Typical Operating Characteristics"), "nil")
    check("cross reference", marker("See page 12 for the wiring diagram"), "nil")
    check("no number", marker("Page"), "nil")
    check("caption", marker("FIGURE 5"), "nil")
    check("five digits", marker("Page 12345"), "nil")
    check("zero", marker("Page 0"), "nil")

    check("first line", firstNonEmptyLine(of: "\n\n  Page 9  \nBody\n") ?? "nil", "Page 9")
    check("blank page", firstNonEmptyLine(of: "\n   \n") ?? "nil", "nil")

    // The warning fires on a printed header that disagrees, and only on one.
    check("printed 3 on physical 5", mismatch("Page 3\nBody text\n", 5), "3")
    check("printed 5 on physical 5", mismatch("Page 5\nBody text\n", 5), "nil")
    check("marker below content", mismatch("Body text\nPage 3\n", 5), "nil")
    check("dashed header", mismatch("- 9 -\nBody text\n", 11), "9")
    check("no header", mismatch("Body text only\n", 5), "nil")

    check("kind install", manualKind(forFileName: "Lennox SLP99 Installation Manual"), "install_guide")
    check("kind wiring", manualKind(forFileName: "RTU-500 wiring diagrams"), "wiring")
    check("kind parts", manualKind(forFileName: "G61MPV_parts_list"), "parts_list")
    check("kind default", manualKind(forFileName: "Lennox SLP99 Service Manual"), "service_manual")

    // Structure from type. Each case is a line an OEM manual actually prints, at the size and
    // weight it prints it in; the app's `ManualStructure` is checked against the same set.
    func line(_ text: String, _ size: Double, _ bold: Bool) -> TypedLine {
        TypedLine(raw: text, text: text, size: size, bold: bold)
    }
    func heading(_ text: String, _ size: Double, _ bold: Bool, body: Int = 10) -> String {
        isStructuralHeading(line(text, size, bold), bodySize: body) ? "yes" : "no"
    }
    func caption(_ text: String, _ bold: Bool = true) -> String {
        captionLabel(line(text, 10, bold)).map { $0.inlineTitle.isEmpty ? $0.label : "\($0.label)/\($0.inlineTitle)" } ?? "nil"
    }
    func page(_ lines: [TypedLine], _ sizes: [Int: Int], body: Int = 10) -> TypedPage {
        _ = sizes
        var histogram: [Int: Int] = [:]
        for l in lines { histogram[Int(l.size.rounded()), default: 0] += l.text.filter { !$0.isWhitespace }.count }
        return TypedPage(lines: lines, sizes: histogram)
    }

    // The heading a technician sees in the book: bold, body size, mixed case, no terminator.
    check("bold body heading", heading("Turning Off Gas to Unit", 10, true), "yes")
    check("bold larger heading", heading("Pressure Switches (Two)", 12, true), "yes")
    check("regular weight", heading("Turning Off Gas to Unit", 10, false), "no")
    check("below body", heading("W1 LOW STAGE HEAT", 8, true), "no")
    // Bold but not a place: a caption, a safety banner, a sentence, a callout number, a header.
    check("caption line", heading("FIGURE 58", 10, true), "no")
    check("table line", heading("TABLE 16", 10, true), "no")
    check("warning banner", heading("WARNING", 10, true), "no")
    check("notice banner", heading("NOTICE", 10, true), "no")
    check("note label", heading("NOTE - the blower runs on", 10, true), "no")
    check("sentence", heading("Turn off the gas at the manual shut-off valve.", 10, true), "no")
    check("colon lead-in", heading("Before you begin:", 10, true), "no")
    check("bare callout number", heading("1", 10, true), "no")
    check("callout run", heading("1 2 3 4", 10, true), "no")
    check("numbered list step", heading("4 - Go to setup / system devices / thermostat", 10, true), "no")
    check("parenthesised step", heading("1) Remove the burner box cover", 10, true), "no")
    check("numbered heading survives", heading("5. Heating Demand", 10, true), "yes")
    check("page header", heading("Page 44", 10, true), "no")
    check("too long", heading(String(repeating: "Requirement ", count: 8), 10, true), "no")
    // The middle of a bold paragraph, which this class of manual sets its warnings in.
    check("continues a word", heading("EQUIPMENT MAY EXPERIENCE PREMATURE COM-", 10, true), "no")
    check("continues a clause", heading("Units may be used for heating of buildings or structures,", 10, true), "no")
    check("starts lower case", heading("stallation in mobile homes, recreational vehicles or", 10, true), "no")

    // Standing alone is what separates a heading from a bold paragraph the shape rules cannot see.
    let bolded = [line("DO NOT USE THE UNIT FOR CONSTRUCTION HEAT", 10, true),
                  line("UNLESS ALL OF THE FOLLOWING CRITERIA ARE MET", 10, true),
                  line("Units may be used for heating of buildings under construction.", 10, false),
                  line("Use of Furnace as Construction Heater", 10, true),
                  line("Units may be used if the following conditions are met.", 10, false)]
    check("bold paragraph first line", standsAlone(at: 0, in: bolded, bodySize: 10) ? "yes" : "no", "no")
    check("bold paragraph second line", standsAlone(at: 1, in: bolded, bodySize: 10) ? "yes" : "no", "no")
    check("isolated heading", standsAlone(at: 3, in: bolded, bodySize: 10) ? "yes" : "no", "yes")
    // The page's own printed header sits above the first heading on the page, in the same bold.
    check("under a running header",
          standsAlone(at: 1, in: [line("Page 56", 10, true), line("BLOWER DATA", 10, true),
                                  line("Bottom return air performance is listed below.", 10, false)],
                      bodySize: 10) ? "yes" : "no", "yes")
    check("bold paragraph yields no headings",
          "\(structuredPageText(page(bolded, [:]), bodySize: 10).headings)", "1")

    check("figure caption", caption("FIGURE 58"), "Figure 58")
    check("table caption", caption("TABLE 16."), "Table 16")
    check("caption with title", caption("FIGURE 58 Integrated Control"), "Figure 58/Integrated Control")
    check("caption not bold", caption("FIGURE 58", false), "nil")
    check("cross reference", caption("See FIGURE 58 on page 44"), "nil")
    check("no number", caption("FIGURE"), "nil")
    check("letter after the number", caption("TABLE 95A Invented limits"), "Table 95A/Invented limits")
    check("letters before the number", caption("TABLE Q7"), "Table Q7")
    check("margin mark apart", caption("\u{0394} TABLE 99 Widget ratings"), "Table 99/Widget ratings")
    check("margin mark glued", caption("\u{25B2}TABLE 98A"), "Table 98A")
    check("mark alone", caption("\u{25B2}"), "nil")
    check("bracketed reference", caption("(TABLE 99)"), "nil")
    check("letter run into a word", caption("TABLE 16Wiring"), "Table 16/Wiring")

    // A caption takes the bold line under it as its title; a parenthetical line merges upward.
    let figurePage = page([line("FIGURE 58", 10, true),
                           line("PRESSURE SWITCH TUBING INSTALLATION", 10, true),
                           line("(shown in upflow position)", 10, true),
                           line("Route the tubing as shown before restoring power to the unit.", 10, false)], [:])
    let figureText = structuredPageText(figurePage, bodySize: 10)
    check("caption takes its title", figureText.text.components(separatedBy: "\n").first ?? "nil",
          "### Figure 58 — PRESSURE SWITCH TUBING INSTALLATION (shown in upflow position)")
    check("parenthetical never stands alone", figureText.text.contains("## (") ? "yes" : "no", "no")
    check("figure page headings", "\(figureText.headings)", "0")

    let mergedPage = page([line("PRESSURE SWITCH TUBING INSTALLATION", 10, true),
                           line("(shown in upflow position)", 10, true),
                           line("Route the tubing as shown before restoring power to the unit.", 10, false)], [:])
    check("merged heading", structuredPageText(mergedPage, bodySize: 10).text.components(separatedBy: "\n").first ?? "nil",
          "## PRESSURE SWITCH TUBING INSTALLATION (shown in upflow position)")

    // A drawing: labels below body size, no sentences. And a prose page, which never is one.
    let diagram = page((1...20).map { line("W\($0) LOW STAGE HEAT COMMON", 8, true) }
                       + [line("FIGURE 58", 10, true)], [:])
    check("diagram page", isDiagramPage(diagram, bodySize: 10) ? "yes" : "no", "yes")
    check("diagram tag", structuredPageText(diagram, bodySize: 10).text.hasPrefix(diagramMarker) ? "yes" : "no", "yes")
    let prose = page((1...12).map { line("The inducer draws through the collector box on call \($0).", 10, false) }, [:])
    check("prose page", isDiagramPage(prose, bodySize: 10) ? "yes" : "no", "no")
    check("prose untouched", structuredPageText(prose, bodySize: 10).text.contains(diagramMarker) ? "yes" : "no", "no")
    // A table page of small type with a few full stops is still read as a figure — accepted, and
    // its rows stay reachable by exact-token search.
    let table = page((1...15).map { line("090XV60C 20A26 20A88 \($0)", 8, false) } + [line("TABLE 16", 10, true)], [:])
    check("table page", isDiagramPage(table, bodySize: 10) ? "yes" : "no", "yes")

    // The page-naming caption is hoisted to the top of a drawing, and written only once.
    let labelled = page([line("Integrated Control", 8, false),
                         line("W1 LOW STAGE HEAT", 8, true),
                         line("FIGURE 58", 10, true),
                         line("TABLE 16 THERMOSTAT INPUT TERMINALS", 10, true),
                         line("C 24VAXC COMMON", 8, false),
                         line("1- DATA LOW CONNECTION", 8, false)], [:])
    let labelledText = structuredPageText(labelled, bodySize: 10)
    check("hoisted to the top", labelledText.text.components(separatedBy: "\n").prefix(2).joined(separator: "|"),
          "\(diagramMarker)|### Figure 58")
    check("hoisted once", "\(labelledText.text.components(separatedBy: "### Figure 58").count - 1)", "1")
    check("other captions stay put", labelledText.text.contains("### Table 16 — THERMOSTAT INPUT TERMINALS") ? "yes" : "no", "yes")

    check("body size mode", "\(bodySize(of: [prose, diagram]))", "10")

    // Fake bold (invented lines): a doubled CJK run collapses; reduplication and Latin stay.
    check("overprint run", collapsingOverprint("1.2 \u{6E29}\u{6E29}\u{5EA6}\u{5EA6}\u{8BA1}\u{8BA1}").text, "1.2 \u{6E29}\u{5EA6}\u{8BA1}")
    check("overprint punctuation", collapsingOverprint("\u{6CE8}\u{6CE8}\u{FF1A}\u{FF1A}x").text, "\u{6CE8}\u{FF1A}x")
    check("reduplication stays", collapsingOverprint("\u{9AD8}\u{9AD8}\u{5174}\u{5174}").text, "\u{9AD8}\u{9AD8}\u{5174}\u{5174}")
    check("latin stays", collapsingOverprint("committee bookkeeper").text, "committee bookkeeper")
    check("leader stays", collapsingOverprint("............").text, "............")
    check("overprinted is bold", isMostlyOverprinted(collapsingOverprint("\u{6E29}\u{6E29}\u{5EA6}\u{5EA6}\u{8BA1}\u{8BA1}")) ? "yes" : "no", "yes")

    // Captions in other languages (invented titles), labelled as an English one is.
    func otherCaption(_ text: String) -> String { captionLabel(line(text, 10, true)).map { "\($0.label)|\($0.inlineTitle)" } ?? "nil" }
    check("German caption", otherCaption("Tabelle 4 Anzugsmomente"), "Table 4|Anzugsmomente")
    check("Hungarian caption", otherCaption("3. t\u{E1}bl\u{E1}zat Nyomatek"), "Table 3|Nyomatek")
    check("Chinese caption", otherCaption("\u{8868} 5 \u{53C2}\u{6570}"), "Table 5|\u{53C2}\u{6570}")
    check("Chinese cross-reference", otherCaption("\u{8868}5\u{4E2D}\u{53C2}\u{6570}"), "nil")
    check("Japanese figure", otherCaption("\u{56F3}2 \u{914D}\u{7DDA}"), "Figure 2|\u{914D}\u{7DDA}")

    // Headings in a script without case (invented lines): bold, or larger than body.
    check("caseless bold heading", isStructuralHeading(line("2.1 \u{6E29}\u{5EA6}\u{8303}\u{56F4}", 10, true), bodySize: 10) ? "yes" : "no", "yes")
    check("caseless larger heading", isStructuralHeading(line("\u{7B2C}3\u{7AE0} \u{5B89}\u{88C5}", 13, false), bodySize: 10) ? "yes" : "no", "yes")
    check("caseless body line", isStructuralHeading(line("\u{7B2C}3\u{7AE0} \u{5B89}\u{88C5}", 10, false), bodySize: 10) ? "yes" : "no", "no")
    check("caseless sentence", isStructuralHeading(line("\u{5B89}\u{88C5}\u{524D}\u{65AD}\u{7535}\u{3002}", 10, true), bodySize: 10) ? "yes" : "no", "no")
    check("latin larger not bold", isStructuralHeading(line("Installation", 13, false), bodySize: 10) ? "yes" : "no", "no")
    // Plan JY P5a: a two-pair fake bold by the glyphs; dotted caption labels; furniture-only pages.
    check("two-pair overprint", collapsingOverprint("\u{6E29}\u{6E29}\u{5EA6}\u{5EA6}", advance: { _ in 0.5 }).text, "\u{6E29}\u{5EA6}")
    check("reduplicated word", collapsingOverprint("\u{9AD8}\u{9AD8}\u{5174}\u{5174}", advance: { _ in 1.0 }).text, "\u{9AD8}\u{9AD8}\u{5174}\u{5174}")
    check("dotted table label", caption("TABLE 2.7.2.2.1 Invented limits"), "Table 2.7.2.2.1/Invented limits")
    check("code book label", caption("TABLE 4B Invented ratings"), "Table 4B/Invented ratings")
    check("furniture-only pages", furnitureOnlyPages(["Invented Rev A\nThe valve opens at the set pressure and closes below it.\n- 1 -",
                                                      "Invented Rev A\n- 2 -", "Invented Rev A\n- 3 -", ""]).sorted().map(String.init).joined(separator: ","), "1,2")

    check("title hyphens", titleSuggestion(forFileName: "SLP99UHVK-service-manual"), "SLP99UHVK service manual")
    check("title underscores", titleSuggestion(forFileName: "RTU_500__wiring"), "RTU 500 wiring")
    check("title plain", titleSuggestion(forFileName: "Lennox SLP99 Service Manual"), "Lennox SLP99 Service Manual")

    guard failures.isEmpty else {
        FileHandle.standardError.write(Data(("self-check failed:\n  " + failures.joined(separator: "\n  ") + "\n").utf8))
        exit(1)
    }
    print("self-check passed")
    exit(0)
}

// MARK: - Arguments

var positional: [String] = []
var dpi = 200
var languages = ["en"]
var forceOCR = false
var selfCheck = false
var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = iterator.next() {
    switch arg {
    case "--dpi":
        guard let v = iterator.next(), let n = Int(v), n >= 72, n <= 600 else { fail("--dpi needs a value between 72 and 600") }
        dpi = n
    case "--lang":
        guard let v = iterator.next() else { fail("--lang needs a comma-separated list, e.g. en,fr") }
        languages = v.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    case "--force-ocr":
        forceOCR = true
    case "--self-check":
        selfCheck = true
    case "--office-worker":
        break
    case "-h", "--help":
        print(usage); exit(0)
    default:
        if arg.hasPrefix("--") { fail("unknown flag \(arg)") }
        positional.append(arg)
    }
}
if selfCheck { runSelfCheck() }
guard let inputPath = positional.first else { fail(usage) }
let inputURL = URL(fileURLWithPath: inputPath)
let outputURL = URL(fileURLWithPath: positional.count > 1 ? positional[1] : inputURL.deletingPathExtension().path + ".md")
guard let document = PDFDocument(url: inputURL) else { fail("Could not open \(inputPath) as a PDF.") }
if officeWorker {
    guard positional.count == 3 else { fail("The office worker requires input, text output and report output paths.") }
    guard !document.isLocked else { fail("This PDF is password locked. Import an unlocked copy before extracting text.") }
    guard document.pageCount > 0, document.pageCount <= 500 else { fail("Choose a PDF with 1–500 pages for this build.") }
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: inputPath),
          let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 16 * 1024 * 1024 else { fail("PDF input exceeds the office size limit.") }
}

func recognise(_ image: CGImage) -> (text: String, confidence: Float) {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = languages
    let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
    // The recogniser can fail to start its model while another process holds the Neural Engine
    // (Plan JY P5a: 16 of 223 pages of one extraction); a second try a moment later reads the page.
    var attempt = 0
    while true {
        do { try handler.perform([request]); break } catch where attempt < 2 {
            attempt += 1
            Thread.sleep(forTimeInterval: 0.5 * Double(attempt))
            continue
        } catch {
            if officeWorker { fail("Text recognition could not finish: \(error.localizedDescription). The original and any previously saved text have been kept.") }
            return ("", 0)
        }
    }
    guard let observations = request.results, !observations.isEmpty else { return ("", 0) }
    var blocks: [(text: String, confidence: Float, box: CGRect)] = []
    for observation in observations {
        guard let candidate = observation.topCandidates(1).first else { continue }
        blocks.append((candidate.string, candidate.confidence, observation.boundingBox))
    }
    blocks.sort { a, b in
        if abs(a.box.maxY - b.box.maxY) < 0.02 { return a.box.minX < b.box.minX }
        return a.box.maxY > b.box.maxY
    }
    let mean = blocks.map(\.confidence).reduce(0, +) / Float(max(blocks.count, 1))
    return (blocks.map(\.text).joined(separator: "\n"), mean)
}

func render(_ page: PDFPage) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    var scale = CGFloat(dpi) / 72
    if officeWorker {
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
        // Bound scan raster memory independently of unusual PDF page dimensions.
        scale = min(scale, 4096 / max(bounds.width, bounds.height))
        scale = min(scale, sqrt(10_000_000 / (bounds.width * bounds.height)))
        guard scale.isFinite, scale > 0, bounds.width * scale >= 1, bounds.height * scale >= 1 else { return nil }
    }
    let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    let image = page.thumbnail(of: size, for: .mediaBox)
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

// One pass over the type before any text is written: the body size is a property of the whole
// document, and a diagram page's own mode is its labels, so it cannot be decided page by page.
var typedPages: [Int: TypedPage] = [:]
var layerBytes = 0
if !forceOCR {
    for index in 0..<document.pageCount {
        guard let page = document.page(at: index),
              let attributed = page.attributedString, attributed.length > 0 else { continue }
        if officeWorker {
            layerBytes += attributed.string.utf8.count
            guard attributed.length <= 500_000, layerBytes <= officeOutputLimit else { fail("Extracted text exceeds this build’s 2 MB limit.") }
        }
        typedPages[index] = typedPage(from: attributed, glyphs: { page.selection(for: $0)?.bounds(for: page) })
    }
}
let body = bodySize(of: typedPages.keys.sorted().compactMap { typedPages[$0] })

// Pages whose text layer is only their furniture while their body is drawn (the app's
// `VaultDocumentExtractor.pagesNeedingRecognition`, Plan JY P5a): an edition printed as outlined
// glyphs keeps its running header and folio as text. Under 20 non-space characters off lines that
// carry no letters or repeat (digits aside) on 3+ pages, and 2% of the body band inked at 36 dpi.
func furnitureOnlyPages(_ pages: [String]) -> Set<Int> {
    let lines = pages.map { $0.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    func key(_ line: String) -> String { line.filter { !$0.isNumber } }
    var pagesWith: [String: Int] = [:]
    for page in lines { for line in Set(page.map(key)) { pagesWith[line, default: 0] += 1 } }
    return Set(lines.indices.filter { i in
        guard !lines[i].isEmpty else { return false }
        let body = lines[i].filter { $0.contains(where: \.isLetter) && (pagesWith[key($0)] ?? 0) < 3 }
        return body.joined().filter { !$0.isWhitespace }.count < 20
    })
}
func bodyInk(_ page: PDFPage) -> Double {
    let bounds = page.bounds(for: .mediaBox)
    let image = page.thumbnail(of: CGSize(width: bounds.width / 2, height: bounds.height / 2), for: .mediaBox)
    var rect = CGRect(origin: .zero, size: image.size)
    guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil), cg.width > 0, cg.height > 0,
          let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
          let data = context.data else { return 0 }
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    let pixels = data.bindMemory(to: UInt8.self, capacity: cg.width * cg.height)
    let top = Int(Double(cg.height) * 0.09), bottom = Int(Double(cg.height) * 0.91)
    guard bottom > top else { return 0 }
    var dark = 0
    for row in top..<bottom { for column in 0..<cg.width where pixels[row * cg.width + column] < 200 { dark += 1 } }
    return Double(dark) / Double(cg.width * (bottom - top))
}
let furnitureOnly = officeWorker || forceOCR ? Set<Int>()
    : furnitureOnlyPages((0..<document.pageCount).map { document.page(at: $0)?.string ?? "" })

var output = "# \(inputURL.deletingPathExtension().lastPathComponent)\n"
var recognisedPages = 0
var lowConfidence = 0
var numberingMismatches = 0
var structuredHeadings = 0
var diagramPages = 0
var pageStartLines: [Int] = []
var nextOutputLine = 2
var ocrPageNumbers: [Int] = []
var reviewPageNumbers: [Int] = []
var emptyPageNumbers: [Int] = []
var printedPageMismatches: [Int] = []
var supplementedPages: [Int] = []
var diagramPageNumbers: [Int] = []
var readableCharacters = 0
officeProgress(page: 0, pages: document.pageCount)
for index in 0..<document.pageCount {
    guard let page = document.page(at: index) else {
        if officeWorker { fail("A PDF page could not be read. The original has been kept.") }
        continue
    }
    let layer = collapsingOverprintedLines(page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    var text = layer
    var diagram = false
    let sparse = layer.filter { !$0.isWhitespace }.count < 160
    let hasObject = layer.contains("\u{fffc}") || layer.contains("\u{fffd}")
    let supplement = officeWorker && !forceOCR && !layer.isEmpty && (sparse || hasObject)
    let drawnBody = furnitureOnly.contains(index) && autoreleasepool { bodyInk(page) } >= 0.02
    if forceOCR || layer.isEmpty || drawnBody {
        // Each page's render and its Vision request drain before the next (Plan JY P5a): held for
        // the whole loop, they grew until the recogniser could no longer start, and every later
        // page of a long scan came back empty.
        if let result = autoreleasepool(invoking: { render(page).map(recognise) }) {
            text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            recognisedPages += 1
            ocrPageNumbers.append(index + 1)
            if result.confidence < 0.8 { reviewPageNumbers.append(index + 1) }
            if result.confidence < 0.5 { lowConfidence += 1 }
            FileHandle.standardError.write(Data("page \(index + 1)/\(document.pageCount): recognised (confidence \(String(format: "%.2f", result.confidence)))\n".utf8))
        } else if officeWorker { fail("A scanned page could not be rendered. The original has been kept.") }
    } else if let typed = typedPages[index], body > 0 {
        // A recognised page has no type to read, so it keeps the lexical treatment; a typed page
        // gets its headings, captions and diagram tag marked.
        let structured = structuredPageText(typed, bodySize: body)
        text = structured.text.trimmingCharacters(in: .whitespacesAndNewlines)
        structuredHeadings += structured.headings
        diagram = structured.isDiagram
        if diagram { diagramPages += 1 }
    }
    if supplement {
        guard let result = autoreleasepool(invoking: { render(page).map(recognise) }) else {
            fail("A potentially incomplete page could not be rendered. Previously saved text has been kept.")
        }
        // Keep the digital text unchanged; OCR is visibly separate and cannot silently
        // overwrite a readable number, part identifier or warning in the text layer.
        text += "\n\n### OCR supplement — review against original\n" + (result.text.isEmpty ? "(No additional text recognised.)" : result.text)
        recognisedPages += 1
        ocrPageNumbers.append(index + 1)
        supplementedPages.append(index + 1)
        reviewPageNumbers.append(index + 1)
    }
    // A page holding a picture is reported for review, and only `isDiagramPage`, which wrote its tag
    // above, makes it a drawing. Tagging every such page took the prose beside a photograph out of
    // the search, which the phone's extractor never did (Plan KG P1).
    if diagram || hasObject { diagramPageNumbers.append(index + 1) }
    // The page's own running header, when it disagrees with where the page actually sits. The text
    // is left exactly as it is — only the reader is told.
    if let printed = numberingMismatch(pageText: text, physicalPage: index + 1) {
        numberingMismatches += 1
        printedPageMismatches.append(index + 1)
        FileHandle.standardError.write(Data(
            "page \(index + 1)/\(document.pageCount): the page prints itself as page \(printed); citations will say page \(index + 1)\n".utf8))
    }
    pageStartLines.append(nextOutputLine + 1)
    let chunk = "\nPage \(index + 1)\n\n" + (text.isEmpty ? "(no text on this page)\n" : text + "\n")
    output += chunk
    nextOutputLine += chunk.utf8.filter { $0 == 10 }.count
    readableCharacters += text.filter { !$0.isWhitespace }.count
    if text.isEmpty { emptyPageNumbers.append(index + 1) }
    if officeWorker, output.utf8.count > officeOutputLimit { fail("Extracted text exceeds this build’s 2 MB limit.") }
    officeProgress(page: index + 1, pages: document.pageCount)
}

if officeWorker, readableCharacters == 0 { fail("No readable text was found. The original has been kept; attach a reviewed text file instead.") }

do {
    try output.write(to: outputURL, atomically: true, encoding: .utf8)
} catch {
    fail("Could not write \(outputURL.path): \(error)")
}
if officeWorker {
    struct OfficeReport: Encodable {
        let version: Int
        let sourceSha256: String
        let method: String
        let pages: Int
        let pageStartLines: [Int]
        let ocrPages: [Int]
        let lowConfidencePages: [Int]
        let emptyPages: [Int]
        let printedPageMismatches: [Int]
        let supplementedPages: [Int]
        let diagramPages: [Int]
    }
    do {
        let source = try Data(contentsOf: inputURL, options: .mappedIfSafe)
        let digest = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        let report = OfficeReport(version: 1, sourceSha256: digest, method: "macPDFKitVision", pages: document.pageCount,
                                  pageStartLines: pageStartLines, ocrPages: ocrPageNumbers, lowConfidencePages: reviewPageNumbers,
                                  emptyPages: emptyPageNumbers, printedPageMismatches: printedPageMismatches,
                                  supplementedPages: supplementedPages, diagramPages: diagramPageNumbers)
        try JSONEncoder().encode(report).write(to: URL(fileURLWithPath: positional[2]), options: .atomic)
    } catch { fail("Could not save the extraction report. Previously saved text has been kept.") }
    exit(0)
}
let stem = inputURL.deletingPathExtension().lastPathComponent
FileHandle.standardError.write(Data("""
wrote \(outputURL.path)
\(document.pageCount) pages, \(recognisedPages) read by recognition, \(lowConfidence) low confidence
body text is \(body) pt; \(structuredHeadings) headings and \(diagramPages) diagram pages marked from type
\(numberingMismatches) pages printed a page number that disagreed with the PDF page\
\(numberingMismatches == 0 ? "" : " — fix the PDF's page order or accept that citations name the physical page")
add it to the vault manifest as a document — the title is a suggestion from the file name, edit it
to the title printed on the manual's cover:
  { "file": "\(outputURL.lastPathComponent)", "title": "\(titleSuggestion(forFileName: stem))", "kind": "\(manualKind(forFileName: stem))" }

""".utf8))
