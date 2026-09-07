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
// Pages with a text layer are copied as-is; pages without one are rendered at --dpi and read with
// Apple Vision. The output is Markdown with a "Page N" marker line before each page, which the
// app's chunker reads as a page boundary, so citations still say "page 42". Written as a whole
// line and as plain text on purpose: Route C of the vault guide exists so a human can open the
// result and correct a misread figure before anyone relies on it.
//
// Printed on stderr: how many pages were recognised, how many came out low confidence, and how
// many pages printed their own page number where that number disagrees with the PDF's page index.
// A manual with an unnumbered cover or roman-numeral front matter is the usual cause; the app
// always cites the physical page, so either fix the PDF or accept that citations name the page you
// reach by counting from the front.
//
// `--self-check` runs the page-marker and manifest-hint rules over synthetic inputs and exits
// non-zero on a mismatch — the script has no test target, so this is what CI can run.
//
// Copyright note: only ship extracted text for manuals you are licensed to redistribute.

let usage = """
usage: extract-manual-text.swift <manual.pdf> [output.md] [--dpi 200] [--lang en,fr] [--force-ocr]
       extract-manual-text.swift --self-check

  --dpi N        render resolution for pages without a text layer (72–600, default 200)
  --lang a,b     recognition languages, most likely first (default en)
  --force-ocr    recognise every page, even one that already has a text layer
  --self-check   run the page-marker and manifest-hint rules over synthetic inputs and exit
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

var output = "# \(inputURL.deletingPathExtension().lastPathComponent)\n"
var recognisedPages = 0
var lowConfidence = 0
var numberingMismatches = 0
for index in 0..<document.pageCount {
    guard let page = document.page(at: index) else { continue }
    let layer = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var text = layer
    if forceOCR || layer.isEmpty {
        if let image = render(page) {
            let result = recognise(image)
            text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            recognisedPages += 1
            if result.confidence < 0.5 { lowConfidence += 1 }
            FileHandle.standardError.write(Data("page \(index + 1)/\(document.pageCount): recognised (confidence \(String(format: "%.2f", result.confidence)))\n".utf8))
        }
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
\(numberingMismatches) pages printed a page number that disagreed with the PDF page\
\(numberingMismatches == 0 ? "" : " — fix the PDF's page order or accept that citations name the physical page")
add it to the vault manifest as a document — the title is a suggestion from the file name, edit it
to the title printed on the manual's cover:
  { "file": "\(outputURL.lastPathComponent)", "title": "\(titleSuggestion(forFileName: stem))", "kind": "\(manualKind(forFileName: stem))" }

""".utf8))
