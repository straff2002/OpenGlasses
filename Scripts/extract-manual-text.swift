#!/usr/bin/env swift
import Foundation
import PDFKit
import Vision
import AppKit

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
func isStructuralHeading(_ line: TypedLine, bodySize: Int) -> Bool {
    guard line.bold, bodySize > 0, line.size >= Double(bodySize) - 0.5 else { return false }
    let text = line.text
    guard text.count >= 2, text.count <= 80 else { return false }
    guard text.contains(where: { $0.isLetter }) else { return false }          // "1", "2", "3 4"
    guard !text.hasPrefix("(") else { return false }   // a qualifier belongs to the heading above it
    // A heading opens; it does not continue. A line that starts lower case or ends on a broken
    // word or an unfinished clause is the middle of a paragraph that happens to be set in bold.
    guard let first = text.first, first.isUppercase || first.isNumber else { return false }
    guard let tail = text.last, !",;:-\u{2013}\u{2014}/&+".contains(tail) else { return false }
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
    guard let match = line.text.range(of: "^(FIGURE|TABLE)\\s+(\\d+)", options: [.regularExpression, .caseInsensitive]) else { return nil }
    let head = String(line.text[match])
    let word = head.range(of: "^FIGURE", options: [.regularExpression, .caseInsensitive]) != nil ? "Figure" : "Table"
    let number = head.range(of: "\\d+", options: .regularExpression).map { String(head[$0]) } ?? ""
    let rest = String(line.text[match.upperBound...])
        .trimmingCharacters(in: CharacterSet(charactersIn: " \t.:—–-"))
    return ("\(word) \(number)", rest)
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
func typedPage(from attributed: NSAttributedString) -> TypedPage {
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
        let dominant = weights.values.max { ($0.count, $0.size) < ($1.count, $1.size) }
        lines.append(TypedLine(raw: raw,
                               text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                               size: dominant?.size ?? 0,
                               bold: dominant?.bold ?? false))
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

func recognise(_ image: CGImage) -> (text: String, confidence: Float) {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = languages
    let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
    do { try handler.perform([request]) } catch { return ("", 0) }
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
    let scale = CGFloat(dpi) / 72
    let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    let image = page.thumbnail(of: size, for: .mediaBox)
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

// One pass over the type before any text is written: the body size is a property of the whole
// document, and a diagram page's own mode is its labels, so it cannot be decided page by page.
var typedPages: [Int: TypedPage] = [:]
if !forceOCR {
    for index in 0..<document.pageCount {
        guard let page = document.page(at: index),
              let attributed = page.attributedString, attributed.length > 0 else { continue }
        typedPages[index] = typedPage(from: attributed)
    }
}
let body = bodySize(of: typedPages.keys.sorted().compactMap { typedPages[$0] })

var output = "# \(inputURL.deletingPathExtension().lastPathComponent)\n"
var recognisedPages = 0
var lowConfidence = 0
var numberingMismatches = 0
var structuredHeadings = 0
var diagramPages = 0
for index in 0..<document.pageCount {
    guard let page = document.page(at: index) else { continue }
    let layer = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var text = layer
    var diagram = false
    if forceOCR || layer.isEmpty {
        if let image = render(page) {
            let result = recognise(image)
            text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            recognisedPages += 1
            if result.confidence < 0.5 { lowConfidence += 1 }
            FileHandle.standardError.write(Data("page \(index + 1)/\(document.pageCount): recognised (confidence \(String(format: "%.2f", result.confidence)))\n".utf8))
        }
    } else if let typed = typedPages[index], body > 0 {
        // A recognised page has no type to read, so it keeps the lexical treatment; a typed page
        // gets its headings, captions and diagram tag marked.
        let structured = structuredPageText(typed, bodySize: body)
        text = structured.text.trimmingCharacters(in: .whitespacesAndNewlines)
        structuredHeadings += structured.headings
        diagram = structured.isDiagram
        if diagram { diagramPages += 1 }
    }
    // The page's own running header, when it disagrees with where the page actually sits. The text
    // is left exactly as it is — only the reader is told.
    if let printed = numberingMismatch(pageText: text, physicalPage: index + 1) {
        numberingMismatches += 1
        FileHandle.standardError.write(Data(
            "page \(index + 1)/\(document.pageCount): the page prints itself as page \(printed); citations will say page \(index + 1)\n".utf8))
    }
    output += "\nPage \(index + 1)\n\n"
    output += text.isEmpty ? "(no text on this page)\n" : text + "\n"
}

do {
    try output.write(to: outputURL, atomically: true, encoding: .utf8)
} catch {
    fail("Could not write \(outputURL.path): \(error)")
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
