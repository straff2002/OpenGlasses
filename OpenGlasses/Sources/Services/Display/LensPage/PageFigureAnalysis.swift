import CoreGraphics
import Foundation
import PDFKit

/// The PDF edge of Plan KV P1b: a page's ink mask and text lines from PDFKit, for the pure
/// `PageFigureLocator`. Synchronous; callers run it off the main actor (`LensPageRenderer.layout`).
///
/// **Where it doesn't apply.** A page with no text layer (a photographed page, a scan, a
/// document imported as text has no PDF at all) has nothing to blank the text out of, so it finds
/// no drawings and the page opens whole, as before. So does a rotated page, whose rendered pixels
/// and text bounds are in different spaces.
enum PageFigureAnalysis {

    /// The analysis renders at 72 dpi: a pixel a point, and a letter page is 612 × 792 pixels.
    static let dpi = 72
    /// A pixel darker than this is ink. A half-point black line drawn at 72 dpi antialiases to
    /// about mid-grey, so the threshold sits well above it; paper and light tints stay out.
    static let inkThreshold: UInt8 = 192

    /// The page's drawings, in reading order; empty where the analysis does not apply.
    static func drawings(on page: PDFPage) -> [PageDrawing] {
        guard page.rotation % 360 == 0 else { return [] }
        let lines = textLines(of: page)
        guard !lines.isEmpty, let mask = inkMask(of: page) else { return [] }
        return PageFigureLocator.locate(mask: mask, textLines: lines)
    }

    /// Every line of the page's text, in top-down page points (`PDFKitPageTextGeometry.topDown`):
    /// PDFKit's line selections (`selectionsByLine()` over the page), each split where its
    /// words leave a gap wider than `segmentGapEms` of their height. PDFKit runs one "line"
    /// across a drawing when two labels share a baseline ("blower" in one box, "board" in the
    /// next), and blanking that whole band would cut the drawing in two.
    static func textLines(of page: PDFPage) -> [PageTextLine] {
        guard let string = page.string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let selection = page.selection(for: NSRange(location: 0, length: (string as NSString).length))
        else { return [] }
        let box = page.bounds(for: .mediaBox)
        let text = string as NSString
        return selection.selectionsByLine().flatMap { line -> [PageTextLine] in
            let pieces = segments(of: line, on: page, text: text)
            if !pieces.isEmpty {
                return pieces.map { PageTextLine(rect: PDFKitPageTextGeometry.topDown($0.rect, mediaBox: box), text: $0.text) }
            }
            let bounds = line.bounds(for: page)
            let words = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard bounds.width > 0, bounds.height > 0, !words.isEmpty else { return [] }
            return [PageTextLine(rect: PDFKitPageTextGeometry.topDown(bounds, mediaBox: box), text: words)]
        }
    }

    /// A gap between words wider than this many of their heights starts a new piece.
    static let segmentGapEms: CGFloat = 1.5

    /// One line selection's words gathered into pieces, in PDF page space. A word is a run of
    /// non-blank characters (its punctuation kept, so a full stop is blanked with its word), and
    /// its bounds are its own selection's: `PDFPage.selection(for:)` takes ranges in the page
    /// text's own indices. `characterBounds(at:)` was tried first and drifted further from the
    /// text line by line on the invented test pages, so it is not used.
    private static func segments(of line: PDFSelection, on page: PDFPage, text: NSString) -> [PageTextLine] {
        var words: [PageTextLine] = []
        for index in 0..<line.numberOfTextRanges(on: page) {
            let range = line.range(at: index, on: page)
            guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= text.length else { continue }
            var position = range.location
            var wordStart: Int?
            func endWord(at end: Int) {
                guard let start = wordStart, end > start else { return }
                wordStart = nil
                let wordRange = NSRange(location: start, length: end - start)
                guard let bounds = page.selection(for: wordRange)?.bounds(for: page),
                      bounds.width > 0, bounds.height > 0 else { return }
                words.append(PageTextLine(rect: bounds, text: text.substring(with: wordRange)))
            }
            while position < NSMaxRange(range) {
                let composed = text.rangeOfComposedCharacterSequence(at: position)
                if text.substring(with: composed).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    endWord(at: composed.location)
                } else if wordStart == nil {
                    wordStart = composed.location
                }
                position = NSMaxRange(composed)
            }
            endWord(at: NSMaxRange(range))
        }

        var pieces: [PageTextLine] = []
        for word in words {
            if let last = pieces.last {
                let height = max(last.rect.height, word.rect.height, 1)
                let sameLine = abs(word.rect.midY - last.rect.midY) <= height
                let gap = word.rect.minX - last.rect.maxX
                if sameLine, gap <= segmentGapEms * height, word.rect.maxX >= last.rect.minX - height {
                    pieces[pieces.count - 1] = PageTextLine(rect: last.rect.union(word.rect),
                                                            text: last.text + " " + word.text)
                    continue
                }
            }
            pieces.append(word)
        }
        return pieces
    }

    /// The page rendered small through `PDFPageRasterizer`, onto white, thresholded into cells.
    static func inkMask(of page: PDFPage, cellSize: CGFloat = PageFigureLocator.defaultCellSize) -> PageInkMask? {
        let size = page.bounds(for: .mediaBox).size
        guard size.width > 0, size.height > 0,
              let image = PDFPageRasterizer.image(for: page, dpi: dpi) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var luma = [UInt8](repeating: 255, count: width * height)
        let drawn = luma.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // Paper first, so a thumbnail with a clear ground reads as paper, not ink.
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // A bitmap context's memory runs from the image's top row down, as the mask's rows do.
        return PageInkMask(luma: luma, width: width, height: height, pageSize: size, cellSize: cellSize,
                           threshold: inkThreshold)
    }

    /// Where the page's text names figure `number`, in top-down page points.
    static func captionRects(number: String, on page: PDFPage) -> [CGRect] {
        guard let text = page.string else { return [] }
        return PageFigureChoice.captionRects(number: number, text: text, geometry: PDFKitPageTextGeometry(page: page))
    }
}

/// Located drawings, by document, page and source revision, so a page is analysed once however
/// many times it is opened, whatever it marks. In memory only; thread-safe, since layouts run
/// off the main actor.
final class PageFigureCache: @unchecked Sendable {
    static let shared = PageFigureCache()
    static let defaultCapacity = 64

    private let lock = NSLock()
    private let capacity: Int
    private var drawings: [String: [PageDrawing]] = [:]
    private var order: [String] = []
    private var analysisCount = 0

    init(capacity: Int = PageFigureCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// The key for one page of one revision of a document.
    static func key(documentId: String, page: Int, sourceRevision: String?, sourceFile: String?) -> String {
        [documentId, "\(page)", sourceRevision ?? "", sourceFile ?? ""].joined(separator: "\u{1F}")
    }

    /// The page's drawings, analysed by `analyse` the first time only.
    func drawings(for key: String, analyse: () -> [PageDrawing]) -> [PageDrawing] {
        lock.lock()
        if let known = drawings[key] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let found = analyse()
        lock.lock()
        defer { lock.unlock() }
        analysisCount += 1
        drawings[key] = found
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity { drawings[order.removeFirst()] = nil }
        return found
    }

    /// How many pages have been analysed (a test seam: the second open of a page analyses none).
    var analyses: Int {
        lock.lock()
        defer { lock.unlock() }
        return analysisCount
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return drawings.count
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        drawings = [:]
        order = []
    }
}
