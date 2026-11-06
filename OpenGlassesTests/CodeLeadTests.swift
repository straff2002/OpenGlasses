import XCTest
@testable import OpenGlasses

/// A spoken code leads at most two passages (Plan KO): past them, the question's words decide
/// before the codes a passage prints, so a list of part numbers cannot take every place from the
/// passage that answers. Every manual, part number and sentence here is invented.
@MainActor
final class CodeLeadTests: XCTestCase {

    private static let title = "KT Cabinet Service Notes"

    private func raw(_ index: Int, _ text: String, section: String? = nil, similarity: Float) -> DocumentStore.Passage {
        DocumentStore.Passage(documentId: "kt-notes", documentName: Self.title, chunkIndex: index, text: text,
                              similarity: similarity, page: index + 1, section: section, kind: .prose)
    }

    /// Four passages print the part number and do not answer; one answers and never prints it.
    private var manual: [DocumentStore.Passage] {
        [
            raw(0, "KT4410 KT4420 KT4430 cabinet range overview", similarity: 0.40),
            raw(1, "Spare parts for KT4410: gasket, hinge, shelf clip", similarity: 0.42),
            raw(2, "KT4410 ordering codes by colour", similarity: 0.38),
            raw(3, "KT4410 shipping weights and carton sizes", similarity: 0.36),
            raw(4, "To replace the door gasket, pull the old gasket out of its channel and press the new one in, starting at a corner.",
                section: "Door gasket", similarity: 0.50),
            raw(5, "Wipe the shelves with warm soapy water.", similarity: 0.30),
            raw(6, "Fault E77 means the drain pump is blocked: clear the pump inlet and restart.", section: "Fault codes",
                similarity: 0.33),
            raw(7, "E77 E78 E79 fault list", similarity: 0.31),
            raw(8, "E77 appears in the fault history menu", similarity: 0.29),
            raw(9, "If the drain pump is blocked the cabinet stops cooling and the drain light flashes; the pump is under the base.",
                section: "Drain pump", similarity: 0.45),
        ]
    }

    private func retriever(_ pages: [DocumentStore.Passage]? = nil) -> VaultRetriever {
        let pages = pages ?? manual
        let stats = pages.reduce(into: LexicalSupport.TermStatistics()) { $0.add(text: $1.text, heading: $1.section) }
        return VaultRetriever(
            query: { _, limit in Array(pages.sorted { $0.similarity > $1.similarity }.prefix(limit)) },
            tokenSearch: { token, limit in Array(pages.filter { CodeTokenizer.contains($0.text, token: token) }.prefix(limit)) },
            termSearch: { query, limit in
                let terms = LexicalSupport.contentTerms(query)
                return Array(pages.filter { LexicalSupport.sharedTermCount(text: $0.text, queryTerms: terms) > 0 }.prefix(limit))
            },
            termStatistics: { stats },
            // Every candidate passes, so the order is read without the gate's thresholds.
            policy: RetrievalEvidencePolicy(similarityFloor: -.infinity))
    }

    private func order(_ turn: String) -> [Int] {
        retriever().rankedCandidates(.init(turn: turn, limit: 4)).map(\.passage.chunkIndex)
    }

    func testTheLeadIsHalfThePassagesAskedFor() {
        XCTAssertEqual(VaultRetriever.codeLeadPlaces(limit: 4), 2)
        XCTAssertEqual(VaultRetriever.codeLeadPlaces(limit: 6), 3)
        XCTAssertEqual(VaultRetriever.codeLeadPlaces(limit: 3), 2, "rounded up")
        XCTAssertEqual(VaultRetriever.codeLeadPlaces(limit: 1), 1, "never none")
    }

    func testTwoPassagesPrintingTheCodeLeadAndTheAnswerThatDoesNotPrintItComesThird() {
        let ranked = order("how do I replace the door gasket on the KT4410")
        XCTAssertEqual(Array(ranked.prefix(2)), [1, 0],
                       "the code's two places, the one sharing a question word first, then today's order")
        XCTAssertEqual(ranked[2], 4, "the answer outranks the code passages past the first two")
        XCTAssertTrue(retriever().retrieve(.init(turn: "how do I replace the door gasket on the KT4410", limit: 4))
            .passages.contains { $0.chunkIndex == 4 }, "so it is among the four handed to the model")
    }

    func testACodePassageThatAnswersKeepsTheLead() {
        let ranked = order("what does fault E77 mean, is the drain pump blocked")
        XCTAssertEqual(ranked.first, 6, "the passage printing the code and sharing the words leads")
        XCTAssertTrue([7, 8].contains(ranked[1]), "the second code place is kept, whatever the words")
        XCTAssertEqual(ranked[2], 9, "past the code's places the words decide")
    }

    func testAQuestionWhoseOnlyCodeIsANumberKeepsEveryPassagePrintingIt() {
        // A number printed on few passages names them, as an error or identifier number does.
        let pages = [
            raw(0, "Error 4471: the lid switch is open.", similarity: 0.30),
            raw(1, "4471 4472 4473 error table", similarity: 0.28),
            raw(2, "4471 logged in the service history", similarity: 0.27),
            raw(3, "4471 reset counter", similarity: 0.26),
            raw(4, "The display shows an error when the lid is open; what each error means is listed below.",
                section: "Display errors", similarity: 0.44),
        ]
        let ranked = retriever(pages).rankedCandidates(.init(turn: "what does error 4471 mean on the display", limit: 4))
            .map(\.passage.chunkIndex)
        XCTAssertEqual(Set(ranked.prefix(4)), [0, 1, 2, 3], "every passage printing the number keeps its place")
        XCTAssertEqual(ranked[4], 4, "the passage sharing the most words comes after them, as before")
    }

    func testPastTheLeadTheCodesStillDecideBetweenPassagesSharingAsManyWords() {
        let candidates = retriever().rankedCandidates(.init(turn: "KT4410 shipping", limit: 4))
        let ranked = candidates.map(\.passage.chunkIndex)
        // Two code passages lead; of the rest, the one sharing "shipping" comes next by its words.
        XCTAssertEqual(ranked.first, 3, "the code passage sharing the word leads")
        XCTAssertEqual(Array(ranked.prefix(4)).filter { [0, 1, 2, 3].contains($0) }.count, 4,
                       "with no plain passage sharing a word, the code passages fill the places as before")
    }
}
