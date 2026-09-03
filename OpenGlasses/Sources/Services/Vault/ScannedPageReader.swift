import CoreGraphics
import Foundation
import PDFKit
import UIKit

/// Recognises the text on one rendered page. The seam that keeps scanned-manual import
/// headless-testable: everything around it — which pages to send, how to assemble the result,
/// confidence counting, checkpointing, progress — is pure over this one call.
protocol ScannedPageReader: Sendable {
    func recognise(_ image: CGImage) async -> ScannedPageText
}

/// What a reader returns for one page. `confidence` is the mean of the recognised blocks'
/// confidences, or zero when nothing was recognised.
struct ScannedPageText: Equatable, Sendable {
    let text: String
    let confidence: Float

    static let empty = ScannedPageText(text: "", confidence: 0)
}

/// The production reader: Apple Vision through the app's existing `OCRService`. On-device only.
struct VisionScannedPageReader: ScannedPageReader {
    private let ocr: OCRService

    init(ocr: OCRService = OCRService()) { self.ocr = ocr }

    func recognise(_ image: CGImage) async -> ScannedPageText {
        let result = await ocr.recognizeText(in: image)
        guard !result.blocks.isEmpty else { return .empty }
        let mean = result.blocks.map(\.confidence).reduce(0, +) / Float(result.blocks.count)
        return ScannedPageText(text: result.text, confidence: mean)
    }
}

/// How a page is rasterised for recognition, as a function of device state. Pure.
///
/// 200 dpi is what Vision wants for body text and small table type on a letter page (about
/// 1,700 × 2,200 pixels). Under thermal pressure the import should finish rather than throttle
/// to a crawl, so the resolution steps down instead of the work stopping.
struct ScanRenderPolicy: Equatable, Sendable {
    var nominalDPI: Int = 200
    var reducedDPI: Int = 150
    /// A page whose mean block confidence is below this is kept but counted as low confidence.
    var lowConfidenceFloor: Float = 0.5

    init(nominalDPI: Int = 200, reducedDPI: Int = 150, lowConfidenceFloor: Float = 0.5) {
        self.nominalDPI = nominalDPI
        self.reducedDPI = reducedDPI
        self.lowConfidenceFloor = lowConfidenceFloor
    }

    func dpi(for thermal: ProcessInfo.ThermalState) -> Int {
        switch thermal {
        case .nominal, .fair: return nominalDPI
        case .serious, .critical: return reducedDPI
        @unknown default: return reducedDPI
        }
    }

    func isLowConfidence(_ page: ScannedPageText) -> Bool {
        page.confidence < lowConfidenceFloor
    }
}

/// Rasterises a PDF page for recognition.
enum PDFPageRasterizer {
    /// Render `page` at `dpi`, capped so a poster-sized drawing cannot allocate an absurd bitmap.
    static func image(for page: PDFPage, dpi: Int, maxPixels: Int = 4_000) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = CGFloat(dpi) / 72
        var size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let longest = max(size.width, size.height)
        if longest > CGFloat(maxPixels) {
            let factor = CGFloat(maxPixels) / longest
            size = CGSize(width: size.width * factor, height: size.height * factor)
        }
        return page.thumbnail(of: size, for: .mediaBox).cgImage
    }
}

/// Recognised pages of one document, persisted as they arrive so a 300-page scan that is
/// interrupted (app backgrounded, phone locked, import cancelled) resumes where it stopped
/// instead of starting over. Keyed by the document's content hash, so a replaced file never
/// resumes from another file's pages.
struct OCRCheckpoint: Codable, Equatable {
    struct Page: Codable, Equatable {
        let index: Int
        let text: String
        let confidence: Float
    }

    var contentHash: String
    var pages: [Int: Page] = [:]

    init(contentHash: String, pages: [Int: Page] = [:]) {
        self.contentHash = contentHash
        self.pages = pages
    }

    static let directoryName = "_ocr"

    static func url(in directory: URL, contentHash: String) -> URL {
        directory.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("\(contentHash).json")
    }

    static func load(from directory: URL, contentHash: String) -> OCRCheckpoint {
        let url = url(in: directory, contentHash: contentHash)
        guard let data = try? Data(contentsOf: url),
              let checkpoint = try? JSONDecoder().decode(OCRCheckpoint.self, from: data),
              checkpoint.contentHash == contentHash else {
            return OCRCheckpoint(contentHash: contentHash)
        }
        return checkpoint
    }

    func save(to directory: URL) throws {
        let url = Self.url(in: directory, contentHash: contentHash)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    static func remove(from directory: URL, contentHash: String) {
        try? FileManager.default.removeItem(at: url(in: directory, contentHash: contentHash))
    }
}
