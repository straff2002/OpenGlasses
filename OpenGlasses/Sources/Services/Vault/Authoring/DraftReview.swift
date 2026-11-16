import Foundation

/// Plan LW P1 — one row on the draft review screen: the phone's own proposal or a pasted row, its
/// check against the manual, and what the author did with it.
struct DraftReviewItem: Identifiable, Equatable {
    enum Origin: Equatable { case proposal, pasted }
    enum State: Equatable { case open, kept, skipped }

    let id: UUID
    var row: DraftRow
    /// Prefilled from the manual by a proposal; cleared when the author edits the row.
    var copiedFromManual: Bool
    var outcome: DraftRowCheck.Outcome
    let origin: Origin
    var state: State = .open
    /// Where *Keep* wrote it.
    var kept: VaultAuthoring.KeptRow?

    init(row: DraftRow, copiedFromManual: Bool, outcome: DraftRowCheck.Outcome, origin: Origin, id: UUID = UUID()) {
        self.id = id
        self.row = row
        self.copiedFromManual = copiedFromManual
        self.outcome = outcome
        self.origin = origin
    }

    /// The PDF page *Keep* cites, or nil when the row cannot be kept as it stands: not found, or
    /// found on several pages (the author edits it first). A row on another page is kept once the
    /// author takes that page (`DraftReview.takingFoundPage`).
    var keepPage: Int? {
        switch outcome.mark {
        case .checked, .sectionChecked, .pageTextUnclear: return outcome.page
        case .foundOnAnotherPage, .foundOnPages, .notFound: return nil
        }
    }

    var inManualsWords: Bool { copiedFromManual || outcome.inManualsWords }
}

/// The review screen's logic, pure over the manual's page text.
enum DraftReview {

    /// Each row checked against `manual`.
    static func items(_ rows: [(row: DraftRow, copied: Bool)], origin: DraftReviewItem.Origin,
                      in manual: ManualPageText) -> [DraftReviewItem] {
        rows.map { DraftReviewItem(row: $0.row, copiedFromManual: $0.copied,
                                   outcome: DraftRowCheck.check($0.row, copiedFromManual: $0.copied, in: manual),
                                   origin: origin) }
    }

    /// What the phone proposes for one manual, by layer, each card's rows checked.
    struct Proposals {
        var faultCodes: FaultCodeProposals.Result
        var models: [ProposedRow]
        var symptoms: [ProposedRow]

        func rows(_ layer: DraftLayer) -> [ProposedRow] {
            switch layer {
            case .faultCodes: return faultCodes.rows
            case .modelMap: return models
            case .symptoms: return symptoms
            }
        }
    }

    static func proposals(text: ManualPageText, tables: [ManualTable], template: TradeTemplate) -> Proposals {
        let pages = text.pageNumbers.compactMap { page in text.text(onPage: page).map { (page: page, text: $0) } }
        return Proposals(faultCodes: FaultCodeProposals.propose(tables: tables, template: template),
                         models: ModelMapProposals.propose(pages: pages, tables: tables, template: template),
                         symptoms: SymptomProposals.propose(tables: tables, pages: pages))
    }

    /// A pasted reply, read and checked: its rows, and its lines that do not fit, shown as they are.
    static func pasted(_ text: String, layer: DraftLayer, in manual: ManualPageText)
        -> (items: [DraftReviewItem], unparsed: [ParsedDraft.Unparsed]) {
        let parsed = PastedDraftParser.parse(text, layer: layer)
        return (items(parsed.rows.map { ($0, false) }, origin: .pasted, in: manual), parsed.unparsed)
    }

    /// `row` moved to PDF page `physical`: what *Use page N* does with a row found on another page.
    static func row(_ row: DraftRow, onPage physical: Int, labels: PageLabelMap) -> DraftRow {
        let page = DraftPage(cited: labels.printed(forPhysical: physical) ?? String(physical), physical: physical)
        switch row {
        case .faultCode(var faultCode): faultCode.page = page; return .faultCode(faultCode)
        case .model(var model): model.page = page; return .model(model)
        case .symptom(var symptom): symptom.page = page; return .symptom(symptom)
        }
    }

    /// The item with the page it was found on taken, and checked again.
    static func takingFoundPage(_ item: DraftReviewItem, in manual: ManualPageText) -> DraftReviewItem {
        guard case .foundOnAnotherPage(let page) = item.outcome.mark else { return item }
        var out = item
        out.row = row(item.row, onPage: page, labels: manual.labels)
        out.outcome = DraftRowCheck.check(out.row, copiedFromManual: out.copiedFromManual, in: manual)
        return out
    }

    /// The item as the author edited it: no longer the manual's words by proposal, and checked again.
    static func editing(_ item: DraftReviewItem, to row: DraftRow, in manual: ManualPageText) -> DraftReviewItem {
        var out = item
        out.row = row
        out.copiedFromManual = false
        out.outcome = DraftRowCheck.check(row, copiedFromManual: false, in: manual)
        return out
    }

    /// The open, checked items of a card *Keep all checked* keeps.
    static func keepAllChecked(_ items: [DraftReviewItem]) -> [UUID] {
        let open = items.filter { $0.state == .open }
        return DraftRowCheck.keepAllChecked(open.map(\.outcome)).map { open[$0].id }
    }

    // MARK: - Pages, as the screen says them

    /// "page 43", or "page 43 (printed 41)" when the printed page differs.
    static func pageText(_ page: Int, labels: PageLabelMap) -> String {
        if let printed = labels.printed(forPhysical: page), printed != String(page) {
            return String(localized: "page \(page) (printed \(printed))")
        }
        return String(localized: "page \(page)")
    }

    /// "41–44" for a run of pages, "41, 43" otherwise.
    static func pageList(_ pages: [Int]) -> String {
        let sorted = Array(Set(pages)).sorted()
        guard let first = sorted.first, let last = sorted.last else { return "" }
        if sorted.count > 1, last - first + 1 == sorted.count { return "\(first)–\(last)" }
        return sorted.map(String.init).joined(separator: ", ")
    }
}
