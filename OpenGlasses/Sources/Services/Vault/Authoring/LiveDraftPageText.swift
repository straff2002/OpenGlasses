import Foundation

/// Plan LW P1 — the live source of `DraftPageText`: one indexed manual's page text, printed-page
/// map and tables, read from what indexing already stored on the phone. Nothing leaves it.
///
/// - **Text** is `DocumentStore.pageTexts(documentId:)`, the text the page viewer's extracted route
///   shows, by PDF page.
/// - **Printed pages** are the document's `DocumentStore.pageLabels(documentId:)`, the map citations
///   and the viewer already read; for a reviewed photographed manual, its pages' own `printedPage`
///   (as `FieldSessionService.manualPageSheet(for:)` maps them).
/// - **Recognised pages** are every page of a photographed manual, and of a document whose ledger
///   entry records pages read by recognition (the ledger counts them, it does not list them).
/// - **Unclear pages** are those whose text `ManualPageText.looksGarbled` says reads as noise. A
///   vault keeps a capture's counts, not each page's confidence, so that is the reading it has.
/// - A manual whose removal is in flight, or whose rows have gone, has no text here, as it has none
///   for an answer (`VaultManualRemoval.availabilityCheck`).
enum LiveDraftPageText {

    /// One manual of a vault, ready for the review screen and the check.
    struct Manual {
        let vaultId: String
        let document: VaultDocument
        /// The key the vault's index rows cite it by (`VaultExpects`).
        let key: String
        let pageText: ManualPageText
        let tables: [ManualTable]
        var title: String { document.title }
    }

    @MainActor
    static func manual(vaultId: String, file: String, documentStore: DocumentStore) -> Manual? {
        guard let manifest = VaultImporter.installedManifest(id: vaultId),
              let document = manifest.documents.first(where: { $0.file == file }),
              let entry = VaultImporter.documentLedger(for: vaultId).entries.first(where: { $0.file == file })
        else { return nil }
        let available = VaultManualRemoval.availabilityCheck(forVault: vaultId, documentStore: documentStore)
        guard available(entry.documentId) else { return nil }
        let labels = entry.capturedManual.map(labels(from:)) ?? documentStore.pageLabels(documentId: entry.documentId)
        let text = assemble(pages: documentStore.pageTexts(documentId: entry.documentId), labels: labels,
                            recognised: entry.usedRecognition || document.personalCapture == true)
        return Manual(vaultId: vaultId, document: document, key: VaultAuthoring.key(for: document, in: manifest),
                      pageText: text, tables: documentStore.tables(documentId: entry.documentId))
    }

    /// The page text as the check reads it: each page's text by PDF page, the printed-page map, every
    /// page recognised when any was read by recognition, and unclear the pages `unclear` names plus
    /// those that read as noise.
    static func assemble(pages: [(page: Int, text: String)], labels: PageLabelMap, recognised: Bool,
                         unclear: Set<Int> = []) -> ManualPageText {
        var texts: [Int: String] = [:]
        for (page, text) in pages { texts[page] = texts[page].map { $0 + "\n" + text } ?? text }
        let garbled = Set(texts.filter { ManualPageText.looksGarbled($0.value) }.keys)
        return ManualPageText(texts: texts, labels: labels, unclearPages: unclear.union(garbled),
                              recognisedPages: recognised ? Set(texts.keys) : [])
    }

    /// A reviewed photographed manual's printed pages; a page printing none (0) has no label.
    static func labels(from review: CapturedManualReview) -> PageLabelMap {
        PageLabelMap(review.pages.filter { $0.printedPage > 0 }
            .map { PageLabel(page: $0.index, label: String($0.printedPage), source: .printed) })
    }
}
