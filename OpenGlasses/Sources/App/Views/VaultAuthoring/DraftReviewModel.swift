import SwiftUI
import UIKit

/// Plan LW P1 — the draft review screen's state for one manual: the phone's proposals and the
/// pasted rows, by layer, each checked against the manual (`DraftReview`), and what *Keep* wrote.
@MainActor
final class DraftReviewModel: ObservableObject {
    @Published private(set) var manual: LiveDraftPageText.Manual?
    @Published private(set) var proposals: [DraftLayer: [DraftReviewItem]] = [:]
    @Published private(set) var pasted: [DraftLayer: [DraftReviewItem]] = [:]
    @Published private(set) var unparsed: [DraftLayer: [ParsedDraft.Unparsed]] = [:]
    @Published var pasteText: [DraftLayer: String] = [:]
    @Published var message: String?
    @Published private(set) var promptCopied: DraftLayer?
    private(set) var template: TradeTemplate = .general
    private(set) var faultCodeResult: FaultCodeProposals.Result?
    private var vaultId = ""

    func load(vaultId: String, file: String, documentStore: DocumentStore?, fixture: LiveDraftPageText.Manual? = nil) {
        self.vaultId = vaultId
        if let manifest = VaultImporter.installedManifest(id: vaultId) { template = VaultAuthoring.template(for: manifest) }
        guard let found = fixture ?? documentStore.flatMap({ LiveDraftPageText.manual(vaultId: vaultId, file: file, documentStore: $0) }) else {
            manual = nil
            return
        }
        manual = found
        let made = DraftReview.proposals(text: found.pageText, tables: found.tables, template: template)
        faultCodeResult = made.faultCodes
        for layer in DraftLayer.allCases {
            proposals[layer] = DraftReview.items(made.rows(layer).map { ($0.row, $0.copiedFromManual) },
                                                 origin: .proposal, in: found.pageText)
        }
    }

    func items(_ layer: DraftLayer, _ origin: DraftReviewItem.Origin) -> [DraftReviewItem] {
        (origin == .proposal ? proposals[layer] : pasted[layer]) ?? []
    }

    // MARK: - Paste and check

    func prompt(_ layer: DraftLayer) -> String {
        PromptKit.prompt(for: layer, template: template, manualTitle: manual?.title)
    }

    func copyPrompt(_ layer: DraftLayer) {
        UIPasteboard.general.string = prompt(layer)
        promptCopied = layer
    }

    func checkPaste(_ layer: DraftLayer) {
        guard let manual else { return }
        let read = DraftReview.pasted(pasteText[layer] ?? "", layer: layer, in: manual.pageText)
        pasted[layer] = read.items
        unparsed[layer] = read.unparsed
    }

    // MARK: - Keep, edit, skip

    private func update(_ id: UUID, _ layer: DraftLayer, _ transform: (inout DraftReviewItem) -> Void) {
        if var list = proposals[layer], let index = list.firstIndex(where: { $0.id == id }) {
            transform(&list[index]); proposals[layer] = list
        } else if var list = pasted[layer], let index = list.firstIndex(where: { $0.id == id }) {
            transform(&list[index]); pasted[layer] = list
        }
    }

    private func item(_ id: UUID, _ layer: DraftLayer) -> DraftReviewItem? {
        (proposals[layer] ?? []).first { $0.id == id } ?? (pasted[layer] ?? []).first { $0.id == id }
    }

    func keep(_ id: UUID, layer: DraftLayer) {
        guard let manual, let item = item(id, layer), item.state == .open, let page = item.keepPage else { return }
        do {
            let kept = try VaultAuthoring.keep(item.row, key: manual.key, page: page, labels: manual.pageText.labels,
                                               inManualsWords: item.inManualsWords, vaultId: vaultId)
            update(id, layer) { $0.state = .kept; $0.kept = kept }
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    /// Keeps every open, checked row of one card, and no other.
    func keepAllChecked(_ layer: DraftLayer, _ origin: DraftReviewItem.Origin) {
        for id in DraftReview.keepAllChecked(items(layer, origin)) { keep(id, layer: layer) }
    }

    func skip(_ id: UUID, layer: DraftLayer) {
        update(id, layer) { $0.state = .skipped }
    }

    func reopen(_ id: UUID, layer: DraftLayer) {
        update(id, layer) { if $0.state == .skipped { $0.state = .open } }
    }

    func takeFoundPage(_ id: UUID, layer: DraftLayer) {
        guard let manual else { return }
        update(id, layer) { $0 = DraftReview.takingFoundPage($0, in: manual.pageText) }
    }

    func edit(_ id: UUID, layer: DraftLayer, to row: DraftRow) {
        guard let manual else { return }
        update(id, layer) { $0 = DraftReview.editing($0, to: row, in: manual.pageText) }
    }

    // MARK: - What each card says

    /// The card's question: *"Found 3 fault-code tables on pages 41–44. Add 38 codes?"*.
    func summary(_ layer: DraftLayer) -> String? {
        let rows = proposals[layer] ?? []
        guard !rows.isEmpty else { return nil }
        switch layer {
        case .faultCodes:
            let result = faultCodeResult
            let tables = result?.tableCount ?? 0
            let pages = DraftReview.pageList(result?.pages ?? [])
            return tables == 1
                ? String(localized: "Found 1 fault-code table on page \(pages). Add \(rows.count) codes?")
                : String(localized: "Found \(tables) fault-code tables on pages \(pages). Add \(rows.count) codes?")
        case .modelMap:
            return rows.count == 1
                ? String(localized: "This manual names 1 model. Add it to the map?")
                : String(localized: "This manual names \(rows.count) models. Add them to the map?")
        case .symptoms:
            let numbers = Set(rows.compactMap { $0.row.symptomPage })
            let pages = DraftReview.pageList(Array(numbers))
            return numbers.count == 1
                ? String(localized: "Found troubleshooting on page \(pages). Draft \(rows.count) symptoms?")
                : String(localized: "Found troubleshooting on pages \(pages). Draft \(rows.count) symptoms?")
        }
    }
}

private extension DraftRow {
    var symptomPage: Int? {
        if case .symptom(let row) = self { return row.page.physical ?? Int(row.page.cited) }
        return nil
    }
}
