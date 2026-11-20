import XCTest
@testable import OpenGlasses

/// Plan MO §5 step 4: the no-model card, the passage sentence that holds the query's words.
final class PassageHintTests: XCTestCase {

    private func passage(_ text: String, name: String, id: String, chunk: Int) -> HintPassage {
        HintPassage(documentId: id, documentName: name, chunkIndex: chunk, text: text)
    }

    func testTheSentenceWithMostOfTheQueryWins() {
        let passages = [
            passage("Our offices are in Leeds. Delivery is free on orders over 200.", name: "Terms", id: "t", chunk: 2),
            passage("Standard delivery takes 3 days. Express delivery to Leeds takes 1 day.", name: "Shipping", id: "s", chunk: 7),
        ]
        let hint = PassageHint.pick(from: passages, for: "How long does express delivery to Leeds take?")
        XCTAssertEqual(hint, PassageHint(text: "Express delivery to Leeds takes 1 day.", documentName: "Shipping",
                                         documentId: "s", chunkIndex: 7))
    }

    func testTiesGoToTheEarlierPassageThenTheEarlierSentence() {
        let passages = [
            passage("Intro text here. The warranty lasts five years. The warranty covers parts.", name: "A", id: "a", chunk: 0),
            passage("The warranty is transferable.", name: "B", id: "b", chunk: 1),
        ]
        let hint = PassageHint.pick(from: passages, for: "warranty")
        XCTAssertEqual(hint?.text, "The warranty lasts five years.")
        XCTAssertEqual(hint?.documentId, "a")
        XCTAssertEqual(hint?.chunkIndex, 0)
    }

    func testAKeywordFindsItsSentence() {
        let passages = [passage("Prices change in March. The price list is on page 4.", name: "Sales", id: "p", chunk: 3)]
        XCTAssertEqual(PassageHint.pick(from: passages, for: "price list")?.text, "The price list is on page 4.")
    }

    func testPluralsMatch() {
        let passages = [passage("All prices include tax.", name: "Sales", id: "p", chunk: 0)]
        XCTAssertEqual(PassageHint.pick(from: passages, for: "What is the price?")?.text, "All prices include tax.")
    }

    func testNoMatchIsNoCard() {
        let passages = [passage("Our offices are in Leeds.", name: "Terms", id: "t", chunk: 0)]
        XCTAssertNil(PassageHint.pick(from: passages, for: "What is the warranty?"))
        XCTAssertNil(PassageHint.pick(from: [], for: "What is the warranty?"))
        XCTAssertNil(PassageHint.pick(from: passages, for: "what is it"), "a query of stop words matches nothing")
    }

    func testALongSentenceIsTrimmedToTheCardAtAWord() {
        let long = "The warranty covers the compressor, the fan motor, the control board, the expansion valve and the reversing valve for five years from installation."
        let hint = PassageHint.pick(from: [passage(long, name: "W", id: "w", chunk: 0)], for: "warranty")
        let text = hint?.text ?? ""
        XCTAssertLessThanOrEqual(text.count, HintLimits.passageCardMaxCharacters)
        XCTAssertTrue(long.hasPrefix(text))
        XCTAssertFalse(text.hasSuffix(","), "no dangling comma")
        XCTAssertEqual(text, "The warranty covers the compressor, the fan motor, the control board, the expansion valve")
    }
}
