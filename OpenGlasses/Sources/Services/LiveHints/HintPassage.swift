import Foundation

/// One passage from the wearer's documents, as a hint uses it (Plan MO §5): the text, the
/// document's name for the card, and the ids a press needs to open the passage on the phone.
///
/// A passage from the job's manuals (§5a) also carries Field Assist's citation for it ("Pump
/// guide, page 12, §4 Priming"), which the card shows as its source and a press opens as a page.
struct HintPassage: Equatable, Sendable {
    let documentId: String
    let documentName: String
    let chunkIndex: Int
    let text: String
    /// Field Assist's citation, exactly as a turn's `Source:` line gives it. Nil for the wearer's
    /// own documents.
    let citation: String?
    /// The manual page, when the passage names one.
    let page: Int?

    init(documentId: String, documentName: String, chunkIndex: Int, text: String,
         citation: String? = nil, page: Int? = nil) {
        self.documentId = documentId
        self.documentName = documentName
        self.chunkIndex = chunkIndex
        self.text = text
        self.citation = citation
        self.page = page
    }

    init(_ passage: DocumentStore.Passage) {
        self.init(documentId: passage.documentId, documentName: passage.documentName,
                  chunkIndex: passage.chunkIndex, text: passage.text)
    }

    /// A manual passage Field Assist's search returned, with its citation.
    init(manual passage: VaultRetriever.Passage) {
        self.init(documentId: passage.documentId, documentName: passage.documentName,
                  chunkIndex: passage.chunkIndex, text: passage.text,
                  citation: passage.citation, page: passage.page)
    }

    /// How the card names where the passage came from: the citation for a manual, else the
    /// document's name.
    var sourceName: String { citation ?? documentName }
}
