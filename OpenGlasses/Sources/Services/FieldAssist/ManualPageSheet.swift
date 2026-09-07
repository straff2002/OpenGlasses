import Foundation
import PDFKit

/// The figure sheet's two routes, its honest header, and its paging — decided without SwiftUI
/// (Plan EK P3).
///
/// A citation is only a door if what is behind it says what it is. A manufacturer's SOP is
/// satisfied by the manufacturer's page; a transcription of that page is a different thing, and a
/// transcription of a page whose original is not in the vault at all is a third. The sheet says
/// which of the three the technician is looking at, and the audit log records it.

// MARK: - Which document is on screen

/// What the technician is actually reading. The raw values are the audit log's, so the export and
/// the header can never drift apart.
enum ManualPageRoute: String, Equatable, Codable {
    /// The manufacturer's own PDF, from the vault baseline.
    case manufacturerPDF = "manufacturer_pdf"
    /// The text the importer extracted from it, as stored in the document store.
    case extractedText = "extracted_text"
    /// The manufacturer's published copy, opened outside the app.
    case externalURL = "external_url"
}

// MARK: - Is it the file that was imported?

/// Whether the file on screen is byte-for-byte the one the ledger recorded at import.
///
/// Checked rather than asserted: the baseline is meant to be read-only, so a hash that no longer
/// matches means the file changed behind the vault's back, and a compliance reviewer would rather
/// be told that than be told "unmodified" by a sentence that is a constant.
enum ManualPageIntegrity: String, Equatable {
    case unmodified
    case changed
    /// No hash was recorded (a vault installed before the ledger kept one), so nothing is claimed.
    case unknown

    static func compare(fileHash: String?, ledgerHash: String?) -> ManualPageIntegrity {
        guard let fileHash, let ledgerHash, !fileHash.isEmpty, !ledgerHash.isEmpty else { return .unknown }
        return fileHash == ledgerHash ? .unmodified : .changed
    }

    /// Re-hash the file off the main thread and compare. Once per open — a manual is tens of
    /// megabytes and the answer cannot change while the sheet is up.
    static func check(url: URL?, against ledgerHash: String?) async -> ManualPageIntegrity {
        guard let url, let ledgerHash, !ledgerHash.isEmpty else { return .unknown }
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .unknown }
            return compare(fileHash: VaultDocumentLedger.hash(of: data), ledgerHash: ledgerHash)
        }.value
    }

    /// The clause that ends the header line, or nil when nothing can honestly be said.
    var clause: String? {
        switch self {
        case .unmodified: return "unmodified since import"
        case .changed: return "changed since import"
        case .unknown: return nil
        }
    }
}

// MARK: - Paging

/// Where the technician is in a document relative to the page they were sent to.
///
/// One model for both routes: PDFKit pages a PDF by swipe and the store pages extracted text by
/// page number, but "which page am I on, how many are there, and how do I get back to the one the
/// answer cited" is the same question either way.
struct FigurePagingModel: Equatable {
    /// The page the citation named — the one "Back to the cited page" returns to.
    let citedPage: Int
    /// Every page that can be shown, ascending. The PDF route is 1…pageCount; the extracted-text
    /// route is the pages the store actually holds text for, which may be sparse.
    let pages: [Int]
    private(set) var currentPage: Int

    init(citedPage: Int, pages: [Int]) {
        let ordered = Array(Set(pages)).sorted()
        self.pages = ordered.isEmpty ? [max(citedPage, 1)] : ordered
        self.citedPage = citedPage
        // A cited page the document does not hold still opens *somewhere* rather than nowhere: the
        // nearest page that exists, which is what a technician turning to a page would do.
        self.currentPage = self.pages.contains(citedPage) ? citedPage
            : (self.pages.first { $0 >= citedPage } ?? self.pages[self.pages.count - 1])
    }

    init(citedPage: Int, pageCount: Int) {
        self.init(citedPage: citedPage, pages: pageCount > 0 ? Array(1...pageCount) : [])
    }

    var pageCount: Int { pages.count }
    var currentIndex: Int { pages.firstIndex(of: currentPage) ?? 0 }
    var canGoForward: Bool { currentIndex < pages.count - 1 }
    var canGoBack: Bool { currentIndex > 0 }
    /// True when the technician has paged away from what the answer cited — which is when the
    /// return control has a job.
    var isAwayFromCitedPage: Bool { currentPage != citedPage }

    /// "page 20 of 85". The title on both routes.
    var title: String { "page \(currentPage) of \(pageCount)" }

    @discardableResult
    mutating func goForward() -> Int? {
        guard canGoForward else { return nil }
        currentPage = pages[currentIndex + 1]
        return currentPage
    }

    @discardableResult
    mutating func goBack() -> Int? {
        guard canGoBack else { return nil }
        currentPage = pages[currentIndex - 1]
        return currentPage
    }

    /// Move to a page the viewer reports (PDFKit pages itself when swiped). Returns the page when
    /// it actually moved, so the caller logs one view per page rather than one per redraw.
    @discardableResult
    mutating func move(to page: Int) -> Int? {
        guard pages.contains(page), page != currentPage else { return nil }
        currentPage = page
        return currentPage
    }

    @discardableResult
    mutating func returnToCitedPage() -> Int? { move(to: citedPage) }
}

// MARK: - The sheet

/// Everything the figure sheet draws, for one citation, on either route.
struct ManualPageSheetModel: Equatable {

    /// One printed page of extracted text.
    struct Page: Equatable {
        let number: Int
        let text: String
    }

    /// The citation the answer printed — the sheet's subtitle and the audit log's key.
    let citation: String
    let documentTitle: String
    /// The manufacturer's PDF: the document itself when the vault imported a PDF, or the original
    /// bundled beside extracted text. Nil when the vault holds neither.
    let manufacturerPDF: URL?
    /// Pages of stored text, ascending. Empty on the PDF route.
    let extractedPages: [Page]
    /// Where the manufacturer publishes this manual, when the manifest names it.
    let publishedURL: URL?
    /// The ledger hash `manufacturerPDF` is checked against.
    let ledgerHash: String?
    /// Whether the manufacturer's PDF is the document itself rather than an original bundled
    /// beside extracted text. Decides which route the sheet opens on.
    let documentIsPDF: Bool

    private(set) var route: ManualPageRoute
    var integrity: ManualPageIntegrity = .unknown
    var paging: FigurePagingModel

    init(citation: String, documentTitle: String, citedPage: Int,
         manufacturerPDF: URL? = nil, pdfPageCount: Int = 0,
         extractedPages: [Page] = [], publishedURL: URL? = nil,
         ledgerHash: String? = nil, documentIsPDF: Bool = false) {
        self.citation = citation
        self.documentTitle = documentTitle
        self.manufacturerPDF = manufacturerPDF
        self.extractedPages = extractedPages
        self.publishedURL = publishedURL
        self.ledgerHash = ledgerHash
        self.documentIsPDF = documentIsPDF
        // The manufacturer's document wins when the vault imported one; extracted text is what is
        // left when it did not, and it is honest about being a transcription.
        let startOnPDF = documentIsPDF && manufacturerPDF != nil
        route = startOnPDF ? .manufacturerPDF : .extractedText
        paging = startOnPDF
            ? FigurePagingModel(citedPage: citedPage, pageCount: pdfPageCount)
            : FigurePagingModel(citedPage: citedPage, pages: extractedPages.map(\.number))
        self.pdfPageCount = pdfPageCount
    }

    /// Pages in the manufacturer's PDF, so switching routes can page through the whole document.
    private(set) var pdfPageCount: Int = 0

    /// Whether there is anything at all to draw. False for a text-imported manual whose page the
    /// store holds nothing for — the honest limit P2 named, kept.
    var hasContent: Bool {
        switch route {
        case .manufacturerPDF: return manufacturerPDF != nil
        case .extractedText: return !extractedPages.isEmpty
        case .externalURL: return false
        }
    }

    /// The extracted text for the page currently being shown.
    var currentText: String? {
        extractedPages.first { $0.number == paging.currentPage }?.text
    }

    /// Whether the sheet can offer "Open manufacturer's page" — a bundled original the technician
    /// is not already reading.
    var canOpenOriginal: Bool { manufacturerPDF != nil && route != .manufacturerPDF }

    /// The header line: which document this is, which page of how many, and — for the
    /// manufacturer's own file — whether it is still the file that was imported.
    var headerLine: String {
        switch route {
        case .manufacturerPDF:
            var parts = ["Manufacturer's document", paging.title]
            if let clause = integrity.clause { parts.append(clause) }
            return parts.joined(separator: " \u{00B7} ")
        case .extractedText:
            return "Extracted text \u{00B7} page \(paging.currentPage)"
        case .externalURL:
            return "Manufacturer's published manual"
        }
    }

    /// What the header says about the original, on the extracted-text route. Nil on the PDF route,
    /// where the original is what is on screen.
    var originalLine: String? {
        guard route == .extractedText else { return nil }
        return manufacturerPDF == nil
            ? "Original not bundled in this vault"
            : "The manufacturer's original is bundled with this vault."
    }

    /// How many pages a PDF has, for the `page N of M` title. Zero when it cannot be opened, which
    /// the paging model reads as "just the page we were sent to".
    static func pageCount(ofPDF url: URL) -> Int {
        PDFDocument(url: url)?.pageCount ?? 0
    }

    /// Switch to the manufacturer's PDF at the page currently being read.
    mutating func openOriginal() {
        guard manufacturerPDF != nil else { return }
        let page = paging.currentPage
        route = .manufacturerPDF
        paging = FigurePagingModel(citedPage: paging.citedPage, pageCount: max(pdfPageCount, page))
        paging.move(to: page)
        integrity = .unknown
    }
}

// MARK: - Driving the sheet

/// Owns the sheet's model and is the only thing that writes its audit trail.
///
/// The view calls `open`, `next`, `previous`, `returnToCitedPage`, `openOriginal` and
/// `openPublished`; every log line the plan asks for is written here, so a surface that forgets to
/// log is a surface that cannot page. `session` is optional and injectable, so the whole thing runs
/// in a test with no app around it.
@MainActor
final class ManualPageController: ObservableObject {

    @Published private(set) var model: ManualPageSheetModel
    private weak var session: FieldSessionService?
    /// So a re-render cannot log the same page twice.
    private var viewedPages: Set<Int> = []

    init(model: ManualPageSheetModel, session: FieldSessionService?) {
        self.model = model
        self.session = session
    }

    /// Called once when the sheet appears: check the file against the ledger, then record what the
    /// technician is verifying the answer against.
    func open() async {
        if model.route == .manufacturerPDF {
            model.integrity = await ManualPageIntegrity.check(url: model.manufacturerPDF,
                                                              against: model.ledgerHash)
        }
        recordVerification()
    }

    func next() { apply { $0.paging.goForward() } }
    func previous() { apply { $0.paging.goBack() } }
    func returnToCitedPage() { apply { $0.paging.returnToCitedPage() } }

    /// The viewer paged itself (a swipe in PDFKit). Logs one view per page actually reached.
    func viewerMoved(to page: Int) { apply { $0.paging.move(to: page) } }

    /// Swap the transcription for the manufacturer's own page, at the page being read.
    func openOriginal() async {
        guard model.canOpenOriginal else { return }
        model.openOriginal()
        model.integrity = await ManualPageIntegrity.check(url: model.manufacturerPDF,
                                                          against: model.ledgerHash)
        recordVerification()
    }

    /// The manufacturer's published copy, for the caller to open outside the app. Recorded as a
    /// verification of its own kind: a page on the manufacturer's website is not the page in this
    /// vault, and an audit that conflated them would be worth nothing.
    func openPublished() -> URL? {
        guard let url = model.publishedURL else { return nil }
        session?.logPageVerified(title: model.documentTitle, page: model.paging.currentPage,
                                 source: .externalURL)
        return url
    }

    private func apply(_ change: (inout ManualPageSheetModel) -> Int?) {
        var copy = model
        guard let page = change(&copy) else { return }
        model = copy
        guard viewedPages.insert(page).inserted else { return }
        session?.logPageViewed(title: model.documentTitle, page: page)
    }

    private func recordVerification() {
        guard model.hasContent else { return }
        viewedPages.insert(model.paging.currentPage)
        session?.logPageVerified(title: model.documentTitle, page: model.paging.currentPage,
                                 source: model.route)
    }
}
