import Foundation

/// One passage from the wearer's documents, as a hint uses it (Plan MO §5): the text, the
/// document's name for the card, and the ids a press needs to open the passage on the phone.
struct HintPassage: Equatable, Sendable {
    let documentId: String
    let documentName: String
    let chunkIndex: Int
    let text: String

    init(documentId: String, documentName: String, chunkIndex: Int, text: String) {
        self.documentId = documentId
        self.documentName = documentName
        self.chunkIndex = chunkIndex
        self.text = text
    }

    init(_ passage: DocumentStore.Passage) {
        self.init(documentId: passage.documentId, documentName: passage.documentName,
                  chunkIndex: passage.chunkIndex, text: passage.text)
    }
}
