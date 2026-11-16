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
///
/// A page read from its text layer is read *with its type* ([[ManualStructure]]): PDFKit's
/// attributed string carries point size and weight per run, which is what tells a real section
/// heading (bold, body size, often mixed case) from the sentence beside it, a figure caption from a
/// cross-reference to one, and a wiring diagram from prose. Those become `## Heading`,
/// `### Figure 58 — Title` and a `<!-- page: diagram -->` tag, the grammar [[DocumentChunker]]
/// reads. A recognised page has no type to read and keeps the lexical treatment, which is also what
/// a PDF whose fonts carry no structure falls back to.
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
        /// Section headings read off the type (`## ` lines). Zero means the document carried no
        /// structure in its fonts and the chunker's lexical rules apply instead.
        let structuredHeadings: Int
        /// Pages that came out as drawings rather than prose (`<!-- page: diagram -->`).
        let diagramPages: Int
        /// The printed page number each physical page carries, where the PDF's labels or its
        /// header/footer band say (Plan IN P0, decision 4). Empty for text and EPUB.
        var pageLabels: [PageLabel] = []

        init(text: String, pageCount: Int?, ocrPages: Int = 0, lowConfidencePages: Int = 0,
             structuredHeadings: Int = 0, diagramPages: Int = 0, pageLabels: [PageLabel] = []) {
            self.text = text
            self.pageCount = pageCount
            self.ocrPages = ocrPages
            self.lowConfidencePages = lowConfidencePages
            self.structuredHeadings = structuredHeadings
            self.diagramPages = diagramPages
            self.pageLabels = pageLabels
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
            let layer = structuredPages(of: document)
            guard layer.pages.contains(where: { !$0.isEmpty }) else { throw ExtractionError.noTextLayer(name) }
            return Extracted(text: layer.pages.joined(separator: pageSeparator), pageCount: document.pageCount,
                             structuredHeadings: layer.headings, diagramPages: layer.diagramPages,
                             pageLabels: pageLabels(of: document))
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
                        bodyInk: ((PDFPage) -> Double)? = nil,
                        progress: ((Int, Int) -> Void)? = nil) async throws -> Extracted {
        let name = url.lastPathComponent
        guard url.pathExtension.lowercased() == "pdf" else { return try extractNonPDF(from: url) }
        guard let document = PDFDocument(url: url) else { throw ExtractionError.unreadable(name) }

        let layer = structuredPages(of: document)
        var pages = layer.pages
        // A page with no text layer, and one whose text layer is only its furniture while its body
        // is drawn (Plan JY P5a: an edition printed as outlined glyphs keeps its running header and
        // folio as text). Asked only when there is a reader to send them to.
        let blank = reader == nil ? pages.indices.filter { pages[$0].isEmpty }
            : pagesNeedingRecognition(document: document, layerPages: pages, bodyInk: bodyInk ?? Self.bodyInk(of:))
        guard let reader, !blank.isEmpty else {
            guard pages.contains(where: { !$0.isEmpty }) else { throw ExtractionError.noTextLayer(name) }
            return Extracted(text: pages.joined(separator: pageSeparator), pageCount: pages.count,
                             structuredHeadings: layer.headings, diagramPages: layer.diagramPages,
                             pageLabels: pageLabels(of: document))
        }

        var state = checkpoint?.load() ?? OCRCheckpoint(contentHash: "")
        let dpi = policy.dpi(for: thermal)
        var done = 0
        var low = 0
        for index in blank {
            let recognised: ScannedPageText
            if let saved = state.pages[index] {
                recognised = ScannedPageText(text: saved.text, confidence: saved.confidence)
            } else if let image = autoreleasepool(invoking: { () -> CGImage? in
                guard let page = document.page(at: index) else { return nil }
                return PDFPageRasterizer.image(for: page, dpi: dpi)
            }) {
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
                         ocrPages: blank.count, lowConfidencePages: low,
                         structuredHeadings: layer.headings, diagramPages: layer.diagramPages,
                         pageLabels: pageLabels(of: document))
    }

    // MARK: - Pages printed as drawings (Plan JY P5a)

    /// A page whose text layer, its furniture set aside, has fewer non-space characters than this
    /// carries no body in its text layer.
    static let furnitureBodyCharacters = 20
    /// A line repeated on at least this many pages (its digits set aside) is a running header or
    /// footer: furniture.
    static let furnitureRepeatPages = 3
    /// The share of a page's body band (between the header and footer bands) that must be inked
    /// for a furniture-only page to be sent to recognition. Measured at 36 dpi, a pixel darker than
    /// 200 of 255 counting: a regulation's Arabic edition printed as outlined glyphs inks 2–16% of
    /// its body band on 225 of its 247 furniture-only pages (the rest are blank); every
    /// furniture-only page of its English, Russian and Chinese editions — blank pages carrying only
    /// the copyright line — inks under 2%, most under 0.2%.
    static let minimumBodyInk = 0.02
    /// The resolution the body band is rendered at to measure its ink: enough to see a line of
    /// type, cheap enough to ask of every furniture-only page.
    static let inkDPI = 36

    /// The pages recognition should read: those with no text layer, and those whose text layer is
    /// furniture only (`furnitureOnlyPages`) while the page's body band is inked (`bodyInk`). A
    /// blank page with only its copyright line, and a manual's short pages (a part title, a figure
    /// with its caption — a caption is not furniture), are left to their text layer, so no
    /// recognition is spent on them.
    static func pagesNeedingRecognition(document: PDFDocument, layerPages: [String],
                                        bodyInk: (PDFPage) -> Double) -> [Int] {
        let empty = Set(layerPages.indices.filter { layerPages[$0].isEmpty })
        let candidates = furnitureOnlyPages(textLayerPages(of: document)).filter { !empty.contains($0) }
        let inked = candidates.filter { index in
            autoreleasepool { document.page(at: index).map { bodyInk($0) >= minimumBodyInk } ?? false }
        }
        return (Array(empty) + inked).sorted()
    }

    /// The pages whose text, its furniture set aside, has fewer than `furnitureBodyCharacters`
    /// non-space characters. Furniture is a line with no letters (a folio, "- 397 -") and a line
    /// that, with its digits set aside, stands on `furnitureRepeatPages` pages or more (a running
    /// header, a copyright footer). An empty page is not counted here. Pure.
    static func furnitureOnlyPages(_ pages: [String]) -> [Int] {
        let lines = pages.map { page in
            page.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        func key(_ line: String) -> String { line.filter { !$0.isNumber } }
        var pagesWith: [String: Int] = [:]
        for page in lines { for line in Set(page.map(key)) { pagesWith[line, default: 0] += 1 } }
        return lines.indices.filter { index in
            guard !lines[index].isEmpty else { return false }
            let body = lines[index].filter { line in
                line.contains(where: \.isLetter) && (pagesWith[key(line)] ?? 0) < furnitureRepeatPages
            }
            return body.joined().filter { !$0.isWhitespace }.count < furnitureBodyCharacters
        }
    }

    /// The share of a page's body band — below the header band and above the footer band
    /// (`pageNumberBand`) — drawn darker than 200 of 255, rendered at `inkDPI`. Zero when the page
    /// cannot be rendered.
    static func bodyInk(of page: PDFPage) -> Double {
        guard let image = PDFPageRasterizer.image(for: page, dpi: inkDPI) else { return 0 }
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return 0 }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        let top = Int(Double(height) * Double(pageNumberBand)), bottom = Int(Double(height) * Double(1 - pageNumberBand))
        guard bottom > top else { return 0 }
        var dark = 0
        for row in top..<bottom {
            for column in 0..<width where pixels[row * width + column] < 200 { dark += 1 }
        }
        return Double(dark) / Double(width * (bottom - top))
    }

    // MARK: - Printed page numbers (Plan IN P0)

    /// How much of the page's height, at the top and at the bottom, counts as the running header
    /// or footer a page number is printed in.
    static let pageNumberBand: CGFloat = 0.09

    /// The printed page each physical page carries. The publisher's own label wins when it says
    /// something other than the physical number — PDFKit reports "1", "2", … for a document with
    /// no labels, which says nothing. Otherwise a lone number or roman numeral in the top or bottom
    /// band is read, so a code book whose PDF carries no labels still maps page 112 to PDF page 130;
    /// and failing that a number at the end of a band line that runs in step with the physical page
    /// over the document (Plan JW P0), for a book that prints its folio at the end of the footer
    /// line beside a date and a copyright notice. The decision is `PrintedPageBand.labels`, pure
    /// over each page's band text. A page that shows none of these gets no entry: unknown is not
    /// "the same as the physical page".
    static func pageLabels(of document: PDFDocument) -> [PageLabel] {
        var pdfLabels: [Int: String] = [:]
        var bands: [String] = []
        for index in 0..<document.pageCount {
            let band: String = autoreleasepool {
                guard let page = document.page(at: index) else { return "" }
                let physical = index + 1
                if let label = page.label?.trimmingCharacters(in: .whitespaces), !label.isEmpty,
                   label != String(physical) {
                    pdfLabels[physical] = label
                    return ""
                }
                return bandText(on: page)
            }
            bands.append(band)
        }
        return PrintedPageBand.labels(bands: bands, pdfLabels: pdfLabels)
    }

    /// The page number printed in a page's header or footer band, read from that page alone (a
    /// lone number on a band line), else nil.
    static func printedLabel(on page: PDFPage) -> String? {
        PrintedPageBand.label(in: bandText(on: page))
    }

    /// The text of a page's top and bottom bands, the top first.
    static func bandText(on page: PDFPage) -> String {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.height > 0 else { return "" }
        let band = bounds.height * pageNumberBand
        // PDF space has its origin at the bottom left.
        let bottom = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: band)
        let top = CGRect(x: bounds.minX, y: bounds.maxY - band, width: bounds.width, height: band)
        return [top, bottom].compactMap { page.selection(for: $0)?.string }.joined(separator: "\n")
    }

    // MARK: - Tables (Plan JJ P0)

    /// The captioned tables in a vault document's PDF, read from the words' positions on the page
    /// by [[PDFTableReader]], each page named by its printed number where one is known. Nil when
    /// `url` is not a PDF PDFKit can open — a Markdown or text import has no positions to read.
    /// Nothing here touches `extract(from:)`: the chunk text, the page separators and the labels
    /// are exactly what they were.
    static func tables(from url: URL) -> PDFTableReader.Result? {
        guard url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) else { return nil }
        let labels = Dictionary(pageLabels(of: document).map { ($0.page, $0.label) }, uniquingKeysWith: { first, _ in first })
        return PDFTableReader.read(document: document, printedLabels: labels)
    }

    /// `tables(from:)` with the tables printed as pictures read too (Plan JN P1), through
    /// `pictures`' reader; with none, exactly `tables(from:)`.
    static func tables(from url: URL, pictures: PictureTableReading.Context?) async -> PDFTableReader.Result? {
        guard url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) else { return nil }
        let labels = Dictionary(pageLabels(of: document).map { ($0.page, $0.label) }, uniquingKeysWith: { first, _ in first })
        return await PDFTableReader.read(document: document, printedLabels: labels, pictures: pictures)
    }

    // MARK: - Charts (Plan LX)

    /// The charts in a vault document's PDF, found from each page's placed words by
    /// [[PDFChartReader]] — on the phone, with no model and no image — each page named by its
    /// printed number where one is known. Nil when `url` is not a PDF PDFKit can open. Like
    /// `tables(from:)`, nothing here touches the document's own text.
    static func charts(from url: URL) -> [ChartCandidate]? {
        guard url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) else { return nil }
        let labels = Dictionary(pageLabels(of: document).map { ($0.page, $0.label) }, uniquingKeysWith: { first, _ in first })
        return PDFChartReader.read(document: document, printedLabels: labels)
    }

    /// What one document's charts came to, in counts: how many found, how many critical. Never a
    /// caption, a title or a label.
    static func logCharts(_ charts: [ChartCandidate]?) {
        guard let charts, !charts.isEmpty else { return }
        PrivacyLog.store(.ragDocuments, .indexed, count: charts.count, detail: PrivacyToken("charts_words_only"))
        let critical = charts.filter { ChartSafetyClass.classify($0).isCritical }.count
        if critical > 0 {
            PrivacyLog.store(.ragDocuments, .indexed, count: critical, detail: PrivacyToken("charts_critical"))
        }
    }

    /// The PDF a vault document's tables are read from: the document itself when it is one, else
    /// the original it was extracted from when the vault carries that, else nil.
    static func tablesSource(document: URL, original: URL?) -> URL? {
        if document.pathExtension.lowercased() == "pdf" { return document }
        guard let original, original.pathExtension.lowercased() == "pdf",
              FileManager.default.fileExists(atPath: original.path) else { return nil }
        return original
    }

    /// What one document's tables came to, in counts: how many captions, how many extracted to a
    /// grid, how many rows the passage cap left out — or that there was no PDF to read them from.
    /// Never a label, a title or a cell.
    static func logTables(_ result: PDFTableReader.Result?, rowsDropped: Int) {
        guard let result else {
            PrivacyLog.store(.ragDocuments, .saveSkipped, detail: PrivacyToken("tables_no_pdf"))
            return
        }
        PrivacyLog.store(.ragDocuments, .indexed, count: result.extracted, total: result.captioned,
                         detail: PrivacyToken("tables"))
        // Tables read from a picture (Plan JN P1): how many, how many were too unclear to keep, how
        // many of their cells, row keys and headings were uncertain, and by which reading.
        if result.recognised + result.unclearInPicture > 0 {
            let reader = result.pictureReader?.rawValue ?? "none"
            PrivacyLog.store(.ragDocuments, .indexed, count: result.recognised, total: result.recognised + result.unclearInPicture,
                             detail: PrivacyToken("tables_from_picture_" + reader))
            PrivacyLog.store(.ragDocuments, .dropped, count: result.unclearInPicture,
                             detail: PrivacyToken("tables_unclear_in_picture"))
            PrivacyLog.store(.ragDocuments, .indexed, count: result.uncertainCells, detail: PrivacyToken("table_cells_uncertain"))
            PrivacyLog.store(.ragDocuments, .indexed, count: result.uncertainKeys, detail: PrivacyToken("table_keys_uncertain"))
            PrivacyLog.store(.ragDocuments, .indexed, count: result.uncertainColumns,
                             detail: PrivacyToken("table_headings_uncertain"))
        }
        if rowsDropped > 0 {
            PrivacyLog.store(.ragDocuments, .dropped, count: rowsDropped, detail: PrivacyToken("table_rows_capped"))
        }
        // A recognised region whose checkpoint could not be saved (Plan JN P2): counted, never
        // silent, so a locked-phone import that cannot resume is visible in the log.
        if result.checkpointSaveFailures > 0 {
            PrivacyLog.store(.ragDocuments, .saveFailed, count: result.checkpointSaveFailures,
                             detail: PrivacyToken("table_checkpoint"))
        }
    }

    // MARK: - Helpers

    /// What a document's text layer came out as, page by page, once its type has been read.
    struct LayerText {
        /// Per-page text in the chunker's grammar; empty string for a page without a text layer.
        let pages: [String]
        let headings: Int
        let diagramPages: Int
    }

    /// Per-page text with its structure marked from type.
    ///
    /// The body size is measured across the whole document before any page is written — a diagram
    /// page's own modal size is its labels, so no page can decide for itself what "small" means. A
    /// page whose text layer carries no attributed string (a recognised scan) or a document whose
    /// fonts yield no body size at all falls back to `page.string`, and the chunker's lexical rules
    /// then apply as they did before.
    private static func structuredPages(of document: PDFDocument) -> LayerText {
        let typed = ManualStructure.typedPages(of: document)
        let body = ManualStructure.bodySize(of: typed.keys.sorted().compactMap { typed[$0] })
        var pages: [String] = []
        var headings = 0
        var diagrams = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { pages.append(""); continue }
            guard body > 0, let typedPage = typed[index] else {
                pages.append(autoreleasepool {
                    OverprintedText.collapsedLines(page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                })
                continue
            }
            let rendered = ManualStructure.render(typedPage, bodySize: body)
            headings += rendered.headings
            if rendered.isDiagram { diagrams += 1 }
            pages.append(rendered.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return LayerText(pages: pages, headings: headings, diagramPages: diagrams)
    }

    /// Per-page text-layer text, trimmed; empty string for a page without a text layer. The plain
    /// read, for callers that only need to know whether there is text at all.
    private static func textLayerPages(of document: PDFDocument) -> [String] {
        (0..<document.pageCount).map { index in
            autoreleasepool { document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
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
