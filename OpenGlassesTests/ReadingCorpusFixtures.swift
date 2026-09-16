import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit
@testable import OpenGlasses

/// Plan FF P1/PR4 — the reading corpus: four invented documents, four conditions each.
///
/// # Why the images are rendered rather than committed
///
/// A reading benchmark wants photographs, and photographs are exactly what this repository must not
/// carry: a real letter has somebody's address on it, a real medication box is guidance somebody
/// could act on, and a real price tag is a brand. Rendering from text means the corpus is small, is
/// reviewable as text in a pull request, and carries a ground truth that is true by construction
/// rather than by transcription.
///
/// The cost is stated rather than hidden: these are clean synthetic renders degraded by filters, so
/// the numbers they produce are an upper bound on what the same pipeline does with a real label
/// photographed through glasses at arm's length in a supermarket aisle. The corresponding on-device
/// measurement is what PR4 records as still owed.
///
/// # The four conditions
///
/// * `clear` — the render itself. The ceiling.
/// * `blurred` — Gaussian blur. Camera shake and a subject too close to focus.
/// * `glared` — a bright band across the middle. Overhead light on a glossy package, the single
///   most common thing that defeats reading a blister pack.
/// * `occluded` — the right third covered. A thumb, a shelf edge, the wearer's own hand.
enum ReadingCorpusFixtures {

    struct Document: Equatable {
        let id: String
        let label: String
        let canvas: CGSize
        let fontSize: CGFloat
        let lines: [String]

        /// The ground truth: the lines as rendered, in reading order.
        var groundTruth: String { lines.joined(separator: "\n") }
    }

    enum Variant: String, CaseIterable {
        case clear, blurred, glared, occluded
    }

    /// `<repo>/OpenGlassesTests/Fixtures/ReadingCorpus`, anchored the way `SafetyEvalCorpusLoader`
    /// anchors its corpus: a run must read the file the pull request changed, not a copy a build
    /// happened to embed.
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ReadingCorpus", isDirectory: true)
    }

    static func load() throws -> [Document] {
        let data = try Data(contentsOf: directory.appendingPathComponent("reading-corpus.json"))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let documents = root["documents"] as? [[String: Any]] else {
            throw CorpusError.malformed("reading-corpus.json: no documents array")
        }
        return try documents.map { entry in
            guard let id = entry["id"] as? String,
                  let label = entry["label"] as? String,
                  let canvas = entry["canvas"] as? [String: Any],
                  let width = canvas["width"] as? Double,
                  let height = canvas["height"] as? Double,
                  let fontSize = entry["fontSize"] as? Double,
                  let lines = entry["lines"] as? [String], !lines.isEmpty else {
                throw CorpusError.malformed("reading-corpus.json: malformed document entry")
            }
            return Document(id: id, label: label,
                            canvas: CGSize(width: width, height: height),
                            fontSize: fontSize, lines: lines)
        }
    }

    enum CorpusError: Error { case malformed(String) }

    // MARK: - Rendering

    /// JPEG bytes for one document under one condition, at the quality the sharp-capture path uses.
    ///
    /// Encoded rather than handed over as a `UIImage` because the thing under measurement is what
    /// arrives at a model: a JPEG at `SharpStillCapture.jpegQuality`, decoded again by whatever
    /// reads it. Measuring the un-encoded render would flatter every number.
    static func jpeg(_ document: Document, _ variant: Variant) -> Data {
        let image = render(document, variant)
        guard let data = image.jpegData(compressionQuality: SharpStillCapture.jpegQuality) else {
            preconditionFailure("corpus render would not encode")
        }
        return data
    }

    static func render(_ document: Document, _ variant: Variant) -> UIImage {
        let base = renderText(document)
        switch variant {
        case .clear: return base
        case .blurred: return blurred(base, fontSize: document.fontSize)
        case .glared: return glared(base)
        case .occluded: return occluded(base)
        }
    }

    /// Black text on white, left-aligned, evenly spaced. Deliberately plain: the corpus measures
    /// the capture and recognition pipeline, not a typesetter.
    private static func renderText(_ document: Document) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: document.canvas, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: document.canvas))

            let font = UIFont.systemFont(ofSize: document.fontSize, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.black,
            ]
            let lineHeight = font.lineHeight * 1.5
            let block = lineHeight * CGFloat(document.lines.count)
            var y = max((document.canvas.height - block) / 2, document.fontSize * 0.5)
            let x = document.canvas.width * 0.08
            for line in document.lines {
                (line as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
                y += lineHeight
            }
        }
    }

    /// Gaussian blur, radius scaled to the *type* size rather than to the canvas, so every document
    /// is degraded by a comparable amount relative to its own strokes. A fixed radius would erase
    /// the small print and barely touch the price tag, and the corpus would be measuring the font
    /// size instead. An eighth of the cap height is roughly a hand that moved through the shutter.
    private static func blurred(_ image: UIImage, fontSize: CGFloat) -> UIImage {
        guard let input = CIImage(image: image) else { return image }
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input
        filter.radius = Float(max(fontSize / 8, 2))
        guard let output = filter.outputImage else { return image }
        let context = CIContext()
        // Crop back to the original extent: a blur grows the extent, and a larger canvas would
        // change the delivered pixel size the report records.
        guard let cg = context.createCGImage(output, from: input.extent) else { return image }
        return UIImage(cgImage: cg)
    }

    /// A bright, soft horizontal band across the middle third — overhead light on a glossy surface.
    private static func glared(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            image.draw(at: .zero)
            let band = CGRect(x: 0, y: image.size.height * 0.30,
                              width: image.size.width, height: image.size.height * 0.40)
            context.cgContext.saveGState()
            context.cgContext.clip(to: band)
            // A plateau rather than a spike: real glare washes a region out, it does not draw a
            // line. The soft edges are what stop this from being an opaque rectangle with extra
            // steps — the recogniser gets partial strokes at the margins, which is the interesting
            // case.
            let colours = [UIColor(white: 1, alpha: 0.0).cgColor,
                           UIColor(white: 1, alpha: 1.0).cgColor,
                           UIColor(white: 1, alpha: 1.0).cgColor,
                           UIColor(white: 1, alpha: 0.0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colours, locations: [0, 0.3, 0.7, 1]) {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: band.minY),
                    end: CGPoint(x: 0, y: band.maxY),
                    options: [])
            }
            context.cgContext.restoreGState()
        }
    }

    /// An opaque block over the start of every line — a thumb, a shelf edge, the wearer's own hand.
    ///
    /// Over the *start* rather than the end, because the lines are ragged-right: a block on the
    /// right covers whitespace on the short lines and would degrade nothing on half the corpus.
    private static func occluded(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            image.draw(at: .zero)
            UIColor(white: 0.25, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0,
                                width: image.size.width * 0.34, height: image.size.height))
        }
    }

    // MARK: - Accuracy

    /// Character accuracy: 1 − (edit distance ÷ ground-truth length), floored at 0.
    ///
    /// Normalisation is deliberately gentle — case folded, runs of whitespace collapsed — because
    /// the question is whether a wearer would hear the right words, not whether the OCR reproduced
    /// the line breaks. Nothing is stripped that a reader would notice: punctuation and digits stay.
    static func characterAccuracy(recognized: String, truth: String) -> Double {
        let a = normalize(recognized), b = normalize(truth)
        guard !b.isEmpty else { return a.isEmpty ? 1 : 0 }
        let distance = editDistance(Array(a), Array(b))
        return max(0, 1 - Double(distance) / Double(b.count))
    }

    /// Digit accuracy over the digits alone, in order.
    ///
    /// Tracked separately because it is the number that matters: a date, a dose, a total and an
    /// account number are all digits, and an OCR pass that reads every word and one digit wrong is
    /// a *worse* failure for a blind wearer than one that reads nothing, because it sounds right.
    static func digitAccuracy(recognized: String, truth: String) -> Double {
        let a = digits(recognized), b = digits(truth)
        guard !b.isEmpty else { return a.isEmpty ? 1 : 0 }
        let distance = editDistance(Array(a), Array(b))
        return max(0, 1 - Double(distance) / Double(b.count))
    }

    static func digits(_ text: String) -> String {
        String(text.filter { $0.isNumber })
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// Levenshtein, two rows. Small strings, so clarity beats cleverness.
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
