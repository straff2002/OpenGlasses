import XCTest
@testable import OpenGlasses

/// Plan KG P0: a model number proposes and ranks passages, and carries none past the gate. On invented
/// models and manuals.
final class ModelEvidenceTests: XCTestCase {

    private let listing = "Wiring diagram for models QX100, QX100-A, QX200."
    private let radiator = "Reseal the radiator loop after draining the hydronic circuit."
    private let fault = "ZX9 low charge."
    private let gate = RetrievalEvidencePolicy(similarityFloor: 0.30, minSharedTerms: 3, sharedFraction: 0.6)

    private func stored(_ index: Int, _ text: String, sim: Float) -> DocumentStore.Passage {
        DocumentStore.Passage(documentId: "d", documentName: "Acme Manual", chunkIndex: index, text: text,
                              similarity: sim, page: index + 1, section: nil)
    }

    /// A store of `chunks`: the search by meaning returns those over 0, the token search any that prints it.
    private func retriever(_ chunks: [(text: String, sim: Float)], scope: VaultRetriever.ModelScope? = nil,
                           names: VaultRetriever.ModelNames? = { ["QX100", "QX100-A", "QX200", "QXB200"].contains($0.uppercased()) }
    ) -> VaultRetriever {
        let all = chunks.enumerated().map { stored($0.offset, $0.element.text, sim: $0.element.sim) }
        return VaultRetriever(query: { _, limit in Array(all.filter { $0.similarity > 0 }.prefix(limit)) },
                              tokenSearch: { token, limit in
            Array(all.filter { CodeTokenizer.contains($0.text, token: token) }.prefix(limit)).map {
                DocumentStore.Passage(documentId: $0.documentId, documentName: $0.documentName, chunkIndex: $0.chunkIndex,
                                      text: $0.text, similarity: 0, page: $0.page, section: nil)
            }
        }, policy: gate, modelScope: scope, modelNames: names)
    }

    func testAQuestionTheManualsCannotAnswerIsRefusedWithTheNumberAsWithoutIt() {
        let chunks: [(text: String, sim: Float)] = [(listing, 0.8)]
        let without = retriever(chunks).retrieve(.init(turn: "how do I bleed a hydronic radiator loop"))
        let with = retriever(chunks).retrieve(.init(turn: "QX100 how do I bleed a hydronic radiator loop"))
        XCTAssertFalse(without.answers)
        XCTAssertFalse(with.answers)
    }

    func testOnlyTheListingPageFoundSaysSoAndKeepsTheMachine() {
        let outcome = retriever([(listing, 0)]).retrieve(.init(turn: "QX100 how do I bleed a hydronic radiator loop"))
        XCTAssertEqual(outcome, .insufficient(reason: RetrievalEvidencePolicy.modelPageOnlySentence))
        let sentence = RetrievalEvidencePolicy.modelPageOnlySentence
        XCTAssertTrue(sentence.contains("found the model's page"), sentence)
        XCTAssertTrue(sentence.contains("offer an expert"), sentence)
        XCTAssertFalse(sentence.lowercased().contains("escalat"), sentence)
        XCTAssertFalse(sentence.contains("not one of them"), "the machine is the vault's own")
    }

    func testABareModelStillFindsItsPage() {
        let outcome = retriever([(listing, 0)]).retrieve(.init(turn: "QX100"))
        XCTAssertTrue(outcome.isSufficient)
        XCTAssertEqual(outcome.passages.first?.text, listing)
        XCTAssertTrue(retriever([(listing, 0)]).retrieve(.init(turn: "what about the QX100?")).isSufficient, "no word to judge by")
    }

    func testAFaultCodeBesideAModelStillPassesAlone() {
        let outcome = retriever([(listing, 0.8), (fault, 0.1)]).retrieve(.init(turn: "QX100 shows ZX9 on the display panel"))
        XCTAssertEqual(outcome.passages.map(\.text), [fault], "the code passes, the listing page does not")
    }

    func testAPartNumberBesideAModelStillPassesAlone() {
        let part = "Order kit PN44871 for this."
        let outcome = retriever([(listing, 0.8), (part, 0.1)]).retrieve(.init(turn: "QX100 where does PN44871 fit"))
        XCTAssertEqual(outcome.passages.map(\.text), [part])
    }

    func testAModelWithAnUnprintedCodeFindsNothingOnThePageListingIt() {
        XCTAssertFalse(retriever([(listing, 0.8)]).retrieve(.init(turn: "QX100 ZX7")).answers)
    }

    func testARealQuestionWithANumberLosesNothing() {
        let page = "On the QX100 reseal the radiator loop after draining the hydronic circuit."
        let outcome = retriever([(page, 0.8), (radiator, 0.7)]).retrieve(.init(turn: "QX100 reseal the radiator loop"))
        XCTAssertEqual(outcome.passages.count, 2)
        XCTAssertEqual(outcome.passages.first?.text, page, "the number still ranks the page that prints it first")
        XCTAssertEqual(outcome.passages.first?.matchedTokens, ["QX100"])
    }

    func testAPagePrintingTheModelThatTheSearchByMeaningNeverReachedIsJudgedByItsWords() {
        let page = "On the QX100 reseal the radiator loop after draining."
        let outcome = retriever([(page, 0)]).retrieve(.init(turn: "QX100 reseal the radiator loop"))
        XCTAssertTrue(outcome.isSufficient, "the token route gives it no similarity to clear the floor with")
    }

    func testTheNumberIsNotOneOfTheWordsAPassageMustShare() {
        // "ABCD" is a term of the number, and four terms ask three where three ask two.
        let names: VaultRetriever.ModelNames = { $0.uppercased() == "ABCD123" }
        let page = "Fit the door seal squarely."
        let outcome = retriever([(page, 0.8)], names: names).retrieve(.init(turn: "ABCD123 door seal gasket"))
        XCTAssertTrue(outcome.isSufficient)
    }

    func testTheRuleHoldsWithNoUnitOnTheJob() {
        XCTAssertFalse(retriever([(listing, 0.8)], scope: nil).retrieve(.init(turn: "QX100 bleed a hydronic radiator loop")).answers)
    }

    func testAScopeAloneNamesItsModels() {
        let scope = VaultRetriever.ModelScope(activeTokens: ["QX100"], otherTokens: ["QX200"])
        let outcome = retriever([(listing, 0.8)], scope: scope, names: nil)
            .retrieve(.init(turn: "QX200 bleed a hydronic radiator loop"))
        XCTAssertFalse(outcome.answers)
    }

    func testAHyphenatedSpellingAndItsPieces() {
        let names: VaultRetriever.ModelNames = { ["QZ44-17B", "QZ44", "17B"].contains($0.uppercased()) }
        let page = "Spare QZ44-17B cabinet label."
        XCTAssertFalse(retriever([(page, 0.8)], names: names).retrieve(.init(turn: "QZ44-17B bleed a hydronic radiator loop")).answers)
        XCTAssertEqual(ModelMention.words(in: "the QZ44-17B again", names: names), ["QZ44-17B", "QZ44", "17B"])
        XCTAssertEqual(ModelMention.removing(from: "the QZ44-17B again", names: names).split(separator: " "), ["the", "again"])
    }

    func testANameplateCountsAsTheSpokenNumberDoes() {
        let plate = "MODEL QX100 SERIAL BK44210 VOLTS"
        XCTAssertFalse(retriever([(listing, 0.8)]).retrieve(.init(turn: "bleed a hydronic radiator loop", ocrText: plate)).answers)
        XCTAssertTrue(retriever([(listing, 0.8)]).retrieve(.init(turn: nil, ocrText: plate)).isSufficient,
                      "a nameplate alone asks which machine this is")
        XCTAssertTrue(retriever([(listing, 0.8)]).retrieve(.init(turn: "  ", ocrText: plate)).isSufficient)
    }

    func testAJobsContextCarriesTheModelToNothing() {
        let context = "QX100. bleed a hydronic radiator loop"
        let outcome = retriever([(listing, 0.8)]).retrieve(.init(turn: "what next", jobContext: context))
        XCTAssertFalse(outcome.answers, "the listing page shares none of the job's words")
        let found = retriever([(radiator, 0.8)]).retrieve(.init(turn: "what next", jobContext: "QX100. reseal the radiator loop"))
        XCTAssertTrue(found.isSufficient, "and the number is not a word the page has to share")
    }

    func testRankingDoesNotMoveOnlyTheGate() {
        let chunks: [(text: String, sim: Float)] = [
            ("Reseal the radiator loop and bleed it, on the QX100.", 0.5), (radiator, 0.9),
            ("The hydronic radiator loop holds the reseal kit.", 0.7),
        ]
        let turn = "QX100 reseal the hydronic radiator loop"
        let known = retriever(chunks).retrieve(.init(turn: turn))
        let unknown = retriever(chunks, names: nil).retrieve(.init(turn: turn))
        XCTAssertEqual(known.passages.map(\.chunkIndex), unknown.passages.map(\.chunkIndex))
    }

    func testARetrieverThatKnowsNoModelsIsAsItWas() {
        // The personal library has no model list: a number there is a code like any other.
        let outcome = retriever([(listing, 0)], names: nil).retrieve(.init(turn: "QX100 bleed a hydronic radiator loop"))
        XCTAssertTrue(outcome.isSufficient)
        XCTAssertEqual(outcome.passages.first?.matchedModels, [])
    }

    func testAnUnreviewedPolicyStillAsksForASimilarity() {
        // With no word count switched on, the floor is all there is to judge a named page by.
        var plain = retriever([(listing, 0)])
        plain.policy = RetrievalEvidencePolicy(similarityFloor: 0.30)
        XCTAssertFalse(plain.retrieve(.init(turn: "QX100 bleed a hydronic radiator loop")).answers)
    }

    func testWhatCountsAsAModelOfTheVault() {
        let index = VaultModelIndex(vaultName: "V", files: [("models.md", "## QXB200 (QXB200-A)\nS:A01. Uses harness PN44871.\n\n## QXB300\nS:A02\n")])
        XCTAssertTrue(index.namesModel("QXB200"))
        XCTAssertTrue(index.namesModel("QXB200A"), "hyphens aside")
        XCTAssertTrue(index.namesModel("QXB20077"), "a spelling with a suffix the list does not hold")
        XCTAssertFalse(index.namesModel("E223"), "a fault code")
        XCTAssertFalse(index.namesModel("PN44871"), "a part number the core only mentions")
        XCTAssertFalse(index.namesModel("R-454B"), "a refrigerant")
    }
}
