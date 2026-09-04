import Foundation
import PDFKit

/// Turns a reference-tier document file into page-aware plain text for `DocumentChunker`.
///
/// The one thing this must get right that the Reading Companion's extractor does not need to:
/// **page boundaries survive.** `PDFDocument.string` flattens a PDF into one run of text, so the
/// chunker's page detection never fires and a citation degrades to "chunk 117". Here each PDF page
/// is extracted on its own and pages are joined with a form feed, which the chunker already reads
/// as a page break — so a passage cites "page 42" and the technician can open the manual to it.
///
/// A PDF is rarely all scan or all text — a reissued manual often has a typeset front section and
/// scanned appendices — so the decision is **per page**: the text layer where a page has one, the
/// injected `ScannedPageReader` where it does not. Page numbering stays physical either way.
enum VaultDocumentExtractor {

    struct Extracted: Equatable {
        let text: String
        /// Physical page count for a paginated source; nil for text and EPUB.
        let pageCount: Int?
        /// Pages whose text came from recognition rather than a text layer.
        let ocrPages: Int
        /// Of those, pages whose mean recognition confidence fell below the policy floor. They
        /// are kept — a shaky page is a better search target than none — but counted, so the
        /// author knows which scan to replace.
        let lowConfidencePages: Int

        init(text: String, pageCount: Int?, ocrPages: Int = 0, lowConfidencePages: Int = 0) {
            self.text = text
            self.pageCount = pageCount
            self.ocrPages = ocrPages
            self.lowConfidencePages = lowConfidencePages
        }

        var usedRecognition: Bool { ocrPages > 0 }
    }

    /// What a PDF's text layer covers, page by page. The validator reports this so an author can
    /// decide to find the original PDF before paying for recognition at import.
    struct TextLayerSurvey: Equatable {
        let pageCount: Int
        let pagesWithText: Int
        var pagesWithoutText: Int { pageCount - pagesWithText }
        var needsRecognition: Bool { pagesWithoutText > 0 }
    }

    enum ExtractionError: LocalizedError, Equatable {
        case unsupportedFormat(String)
        case unreadable(String)
        /// A PDF with no extractable text on any page and no reader to recognise it.
        case noTextLayer(String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let f): return "\(f): unsupported format (use PDF, EPUB, Markdown, or text)."
            case .unreadable(let f): return "\(f): could not be opened."
            case .noTextLayer(let f): return "\(f): this PDF has no text layer (a scanned image) and no recogniser is available."
            case .empty(let f): return "\(f): contains no text."
            }
        }
    }

    /// Page separator the chunker recognises.
    static let pageSeparator = "\u{0C}"

    static let supportedExtensions: Set<String> = ["pdf", "epub", "md", "markdown", "txt", "text"]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Synchronous, text layer only

    /// Extract without recognition. A PDF with no text layer at all throws `noTextLayer`; pages
    /// without text inside a mixed PDF are left blank. This is the validator's path and the
    /// import path when no reader is configured.
    static func extract(from url: URL) throws -> Extracted {
        let name = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url) else { throw ExtractionError.unreadable(name) }
            let pages = textLayerPages(of: document)
            guard pages.contains(where: { !$0.isEmpty }) else { throw ExtractionError.noTextLayer(name) }
            return Extracted(text: pages.joined(separator: pageSeparator), pageCount: document.pageCount)
        default:
            return try extractNonPDF(from: url)
        }
    }

    /// Survey a PDF's text layer without extracting. Nil for non-PDF or unreadable files.
    static func survey(_ url: URL) -> TextLayerSurvey? {
        guard url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) else { return nil }
        let pages = textLayerPages(of: document)
        return TextLayerSurvey(pageCount: pages.count, pagesWithText: pages.filter { !$0.isEmpty }.count)
    }

    // MARK: - Asynchronous, with recognition

    /// Extract with a reader for pages that have no text layer. Recognised pages are checkpointed
    /// through `checkpoint` (when given) after each page, and pages already in the checkpoint are
    /// not recognised again. `progress` reports (pages done, pages needing recognition).
    static func extract(from url: URL,
                        reader: ScannedPageReader?,
                        policy: ScanRenderPolicy = ScanRenderPolicy(),
                        thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState,
                        checkpoint: (load: () -> OCRCheckpoint, save: (OCRCheckpoint) throws -> Void)? = nil,
                        progress: ((Int, Int) -> Void)? = nil) async throws -> Extracted {
        let name = url.lastPathComponent
        guard url.pathExtension.lowercased() == "pdf" else { return try extractNonPDF(from: url) }
        guard let document = PDFDocument(url: url) else { throw ExtractionError.unreadable(name) }

        var pages = textLayerPages(of: document)
        let blank = pages.indices.filter { pages[$0].isEmpty }
        guard let reader, !blank.isEmpty else {
            guard pages.contains(where: { !$0.isEmpty }) else { throw ExtractionError.noTextLayer(name) }
            return Extracted(text: pages.joined(separator: pageSeparator), pageCount: pages.count)
        }

        var state = checkpoint?.load() ?? OCRCheckpoint(contentHash: "")
        let dpi = policy.dpi(for: thermal)
        var done = 0
        var low = 0
        for index in blank {
            let recognised: ScannedPageText
            if let saved = state.pages[index] {
                recognised = ScannedPageText(text: saved.text, confidence: saved.confidence)
            } else if let page = document.page(at: index), let image = PDFPageRasterizer.image(for: page, dpi: dpi) {
                recognised = await reader.recognise(image)
                state.pages[index] = .init(index: index, text: recognised.text, confidence: recognised.confidence)
                try checkpoint?.save(state)
            } else {
                recognised = .empty
            }
            pages[index] = recognised.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if policy.isLowConfidence(recognised) { low += 1 }
            done += 1
            progress?(done, blank.count)
            await Task.yield()
        }

        guard pages.contains(where: { !$0.isEmpty }) else { throw ExtractionError.empty(name) }
        return Extracted(text: pages.joined(separator: pageSeparator), pageCount: pages.count,
                         ocrPages: blank.count, lowConfidencePages: low)
    }

    // MARK: - Helpers

    /// Per-page text-layer text, trimmed; empty string for a page without a text layer.
    private static func textLayerPages(of document: PDFDocument) -> [String] {
        (0..<document.pageCount).map { index in
            document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    private static func extractNonPDF(from url: URL) throws -> Extracted {
        let name = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "epub":
            guard let data = try? Data(contentsOf: url) else { throw ExtractionError.unreadable(name) }
            guard let text = EPUBExtractor.text(from: data),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExtractionError.empty(name)
            }
            return Extracted(text: text, pageCount: nil)
        case "md", "markdown", "txt", "text":
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ExtractionError.unreadable(name) }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ExtractionError.empty(name) }
            return Extracted(text: text, pageCount: nil)
        default:
            throw ExtractionError.unsupportedFormat(name)
        }
    }

    /// Per-page text joined by form feeds. Kept for callers that only need the text layer.
    static func pageAwareText(from document: PDFDocument) -> (text: String, pageCount: Int, nonEmptyPages: Int) {
        let pages = textLayerPages(of: document)
        return (pages.joined(separator: pageSeparator), pages.count, pages.filter { !$0.isEmpty }.count)
    }
}
