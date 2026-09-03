import Foundation
import PDFKit

/// Turns a reference-tier document file into page-aware plain text for `DocumentChunker`.
///
/// The one thing this must get right that the Reading Companion's extractor does not need to:
/// **page boundaries survive.** `PDFDocument.string` flattens a PDF into one run of text, so the
/// chunker's page detection never fires and a citation degrades to "chunk 117". Here each PDF page
/// is extracted on its own and pages are joined with a form feed, which the chunker already reads
/// as a page break — so a passage cites "page 42" and the technician can open the manual to it.
enum VaultDocumentExtractor {

    struct Extracted: Equatable {
        let text: String
        /// Physical page count for a paginated source; nil for text and EPUB.
        let pageCount: Int?
    }

    enum ExtractionError: LocalizedError, Equatable {
        case unsupportedFormat(String)
        case unreadable(String)
        /// A PDF with no extractable text on any page — a scan without an OCR layer.
        case noTextLayer(String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let f): return "\(f): unsupported format (use PDF, EPUB, Markdown, or text)."
            case .unreadable(let f): return "\(f): could not be opened."
            case .noTextLayer(let f): return "\(f): this PDF has no text layer (a scanned image). OCR import is not available yet."
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

    static func extract(from url: URL) throws -> Extracted {
        let name = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url) else { throw ExtractionError.unreadable(name) }
            let paged = pageAwareText(from: document)
            guard paged.nonEmptyPages > 0 else { throw ExtractionError.noTextLayer(name) }
            return Extracted(text: paged.text, pageCount: paged.pageCount)
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

    /// Per-page text joined by form feeds. Pages with no text still emit their separator so page
    /// numbering stays physical (a blank page 3 keeps page 4 as page 4).
    static func pageAwareText(from document: PDFDocument) -> (text: String, pageCount: Int, nonEmptyPages: Int) {
        var pages: [String] = []
        var nonEmpty = 0
        for index in 0..<document.pageCount {
            let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { nonEmpty += 1 }
            pages.append(text)
        }
        return (pages.joined(separator: pageSeparator), document.pageCount, nonEmpty)
    }
}
