#!/usr/bin/env swift
import Foundation
import PDFKit
import Vision
import AppKit

// Extracts a manual's text on a Mac, page by page, for a vault's documents tier — so a pack or a
// customer folder can ship pre-extracted text and the phone never pays for recognition.
//
//   ./Scripts/extract-manual-text.swift <manual.pdf> [output.md] [--dpi 200] [--lang en,fr] [--force-ocr]
//
// Pages with a text layer are copied as-is; pages without one are rendered at --dpi and read with
// Apple Vision. The output is Markdown with a "Page N" marker line before each page, which the
// app's chunker reads as a page boundary, so citations still say "page 42". A summary of how many
// pages were recognised, and how many came out low confidence, is printed on stderr.
//
// Copyright note: only ship extracted text for manuals you are licensed to redistribute.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var positional: [String] = []
var dpi = 200
var languages = ["en"]
var forceOCR = false
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
    case "-h", "--help":
        print("usage: extract-manual-text.swift <manual.pdf> [output.md] [--dpi 200] [--lang en,fr] [--force-ocr]"); exit(0)
    default:
        if arg.hasPrefix("--") { fail("unknown flag \(arg)") }
        positional.append(arg)
    }
}
guard let inputPath = positional.first else {
    fail("usage: extract-manual-text.swift <manual.pdf> [output.md] [--dpi 200] [--lang en,fr] [--force-ocr]")
}
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
    output += "\nPage \(index + 1)\n\n"
    output += text.isEmpty ? "(no text on this page)\n" : text + "\n"
}

do {
    try output.write(to: outputURL, atomically: true, encoding: .utf8)
} catch {
    fail("Could not write \(outputURL.path): \(error)")
}
FileHandle.standardError.write(Data("""
wrote \(outputURL.path)
\(document.pageCount) pages, \(recognisedPages) read by recognition, \(lowConfidence) low confidence
add it to the vault manifest as a document, e.g.
  { "file": "\(outputURL.lastPathComponent)", "title": "\(inputURL.deletingPathExtension().lastPathComponent)", "kind": "service_manual" }

""".utf8))
