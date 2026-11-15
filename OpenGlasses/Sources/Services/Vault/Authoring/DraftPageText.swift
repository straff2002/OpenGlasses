import Foundation

/// Plan LW §4a — one indexed manual's page text, as the paste check (`DraftRowCheck`) and the
/// proposal builders read it. A seam: tests inject fixtures (`ManualPageText`), and the live source
/// reads what the phone already stores for the manual (see `ManualPageText`'s note).
protocol DraftPageText {
    /// Every PDF page with text, ascending.
    var pageNumbers: [Int] { get }
    /// A PDF page's text, or nil when the manual holds none for it.
    func text(onPage page: Int) -> String?
    /// The PDF pages that print `label` as their page number. Empty when none does.
    func pages(printed label: String) -> [Int]
    /// The page's text was recognised with low confidence or reads as garbled: the check can neither
    /// pass nor fail a row on it.
    func isUnclear(page: Int) -> Bool
    /// The page was read by recognition (a photographed or scanned page), where O and 0, I and 1, S
    /// and 5 are mistaken for each other: codes are compared with those folded together.
    func isRecognised(page: Int) -> Bool
}

/// A manual's page text held in memory.
///
/// **The live source (P1)** builds one per manual from what indexing already stored, on the phone:
/// - `texts`: `DocumentStore.pageTexts(documentId:)` (the text the page viewer's extracted route
///   shows), by PDF page;
/// - `labels`: `DocumentStore.pageLabels(documentId:)` (the printed-page map citations and the
///   viewer already use); for a photographed manual, its pages' `printedPage`
///   (`CapturedManualReview.Page`, as `FieldSessionService.manualPageSheet(for:)` maps them);
/// - `recognisedPages`: every page of a photographed manual, and every page of a document whose
///   ledger entry records `ocrPages` (the ledger counts them, it does not list them);
/// - `unclearPages`: a photographed page whose `confidenceMilli` is under 500 (the floor
///   `CapturedManualAssembler` counts `lowConfidencePages` by) or that failed, where the capture's
///   own pages are at hand; otherwise, and for every other page, any page `looksGarbled` says so of.
///   A reviewed capture in a vault (`CapturedManualReview`) keeps only the counts, so it relies on
///   `looksGarbled`.
struct ManualPageText: DraftPageText, Equatable {
    var texts: [Int: String]
    var labels: PageLabelMap
    var unclearPages: Set<Int>
    var recognisedPages: Set<Int>

    init(texts: [Int: String], labels: PageLabelMap = PageLabelMap([]), unclearPages: Set<Int> = [],
         recognisedPages: Set<Int> = []) {
        self.texts = texts
        self.labels = labels
        self.unclearPages = unclearPages
        self.recognisedPages = recognisedPages
    }

    var pageNumbers: [Int] { texts.keys.sorted() }
    func text(onPage page: Int) -> String? { texts[page] }
    func pages(printed label: String) -> [Int] { labels.physicalPages(forPrinted: label) }
    func isUnclear(page: Int) -> Bool { unclearPages.contains(page) }
    func isRecognised(page: Int) -> Bool { recognisedPages.contains(page) }

    /// Text that reads as noise rather than words: of its runs of letters and digits, fewer than half
    /// look like a word or a number (two or more characters, with a vowel or a digit). Short text is
    /// never called garbled; a page with little on it is not unclear for that.
    static func looksGarbled(_ text: String) -> Bool {
        let words = CodeTokenizer.words(in: text)
        guard words.count >= 12 else { return false }
        let vowels = Set("aeiouyAEIOUY")
        let plausible = words.filter { word in
            word.count >= 2 && (word.contains(where: \.isNumber) || word.contains(where: vowels.contains))
        }
        return plausible.count * 2 < words.count
    }
}
