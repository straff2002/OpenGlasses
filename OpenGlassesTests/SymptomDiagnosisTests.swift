import XCTest
@testable import OpenGlasses

/// Plan KE P1 — the model and the symptom reach the search. A tester's three simulated calls
/// stalled on "model, symptom, what should I check next?": a model said aloud was never recorded,
/// the known model did not pick the manuals, a follow-up searched its own words alone, a retrieval
/// miss became a page to an expert, and the tools looped.
///
/// Every vault, model, manual and page here is invented.

// MARK: - Fixtures

private enum Fixture {
    /// A vault of two families whose model sections say which documents each has.
    static let models = """
    # Models

    ## QX100 (QX100-A; rooftop)
    S:A02; U:A11; O:A21,A41; A02 suffix:00,01
    ### Notes
    Uses the Acme harness SM-70012.

    ## QX200 (rooftop)
    S:A03; U:A12

    ## Glossary terms G400
    S:A99

    ## QY300 (split)
    No documents listed here.
    """

    static let index = VaultModelIndex(vaultName: "Acme Refrigeration", files: [("models.md", models)])

    static func model(_ name: String) -> VaultModelIndex.Model {
        index.models.first { $0.name.hasPrefix(name) }!
    }

    /// A vault written for a whole series, which the sections' documents are read across.
    static let series = VaultModelIndex(vaultName: "Acme Series", files: [("models.md", """
    ## QXT99UH100AB
    S:B01
    ## QXT99UH200AB
    S:B02
    ## QXT99UH300AB
    S:B01
    """)])

    static func identity(_ stated: String, in index: VaultModelIndex = Fixture.index) -> EquipmentIdentity {
        guard case .unit(let identity) = EquipmentRecognition.reading(of: stated, source: .spoken, index: index) else {
            preconditionFailure("\(stated) is not in the fixture")
        }
        return identity
    }

    static func passage(_ documentId: String, _ index: Int = 0, text: String = "Check the flame sensor rod",
                        source: RetrievalSource = .manual, modelToken: String? = nil,
                        similarity: Float = 0.8) -> DocumentStore.Passage {
        var passage = DocumentStore.Passage(documentId: documentId, documentName: documentId, chunkIndex: index,
                                            text: text, similarity: similarity, page: 1, section: nil)
        passage.source = source
        passage.subjectModelToken = modelToken
        return passage
    }

    static func found(_ documentId: String, _ index: Int = 0, source: RetrievalSource = .manual) -> VaultRetriever.Passage {
        VaultRetriever.Passage(documentId: documentId, documentName: documentId, chunkIndex: index, text: "text",
                               page: 1, section: nil, similarity: 0.8, score: 0.8, matchedTokens: [], source: source)
    }
}

// MARK: - The model said aloud counts

final class SpokenModelTests: XCTestCase {

    private func said(_ turn: String, active: EquipmentIdentity? = nil,
                      index: VaultModelIndex = Fixture.index) -> (identity: EquipmentIdentity, change: EquipmentRecognition.Change)? {
        EquipmentRecognition.unitSaid(in: turn, active: active, index: index)
    }

    func testAModelSaidWithNoUnitYetIsTheUnit() throws {
        let unit = try XCTUnwrap(said("the QX100 has no heat"))
        XCTAssertEqual(unit.change, .firstUnit)
        XCTAssertEqual(unit.identity.stated, "QX100")
        XCTAssertEqual(unit.identity.source, .spoken, "the same source the tool records, from the technician")
        XCTAssertEqual(unit.identity.provenancePhrase, "from the technician")
    }

    func testAFullerSpellingKeepsWhatWasStated() throws {
        let unit = try XCTUnwrap(said("it's a QX100-A01 actually", active: Fixture.identity("QX100")))
        XCTAssertEqual(unit.change, .fullerSpelling)
        XCTAssertEqual(unit.identity.stated, "QX100-A01")
    }

    func testTheSameUnitAgainMovesNothing() {
        XCTAssertNil(said("the QX100 still has no heat", active: Fixture.identity("QX100")))
    }

    func testAShorterSpellingNeverLosesTheSuffix() {
        XCTAssertNil(said("the QX100 again", active: Fixture.identity("QX100-A01")))
    }

    func testADifferentModelMovesNothing() {
        XCTAssertNil(said("the QX200 next door has the same fault", active: Fixture.identity("QX100")))
    }

    func testTwoModelsIdentifyNeither() {
        XCTAssertNil(said("the QX100 is fine but the QX200 trips"))
        XCTAssertFalse(Fixture.index.namesOneModel(in: "the QX100 is fine but the QX200 trips"))
        // `match(text:)` keeps its first reading there, which is why the strict check exists.
        XCTAssertEqual(Fixture.index.match(text: "the QX100 is fine but the QX200 trips").count, 1)
    }

    func testTheSameModelTwiceIsOneModel() {
        XCTAssertTrue(Fixture.index.namesOneModel(in: "QX100, yes the QX100-A"))
    }

    func testJobBookkeepingRecordsNothing() {
        XCTAssertNil(said("open a new job 108 on the QX100"))
        XCTAssertNil(said("close the job on the QX100"))
    }

    func testAJobNumberIsNotAModel() {
        XCTAssertNil(said("what's on job QX100 today"))
    }

    func testADenialRecordsNothing() {
        XCTAssertNil(said("no, it's not the QX100"))
        XCTAssertNil(said("this isn't a QX100"))
        XCTAssertNotNil(said("no, it's the QX100"))
    }

    func testAVaultWithNoModelsIsANoOp() {
        XCTAssertNil(said("the QX100 has no heat", index: VaultModelIndex(vaultName: "Empty", files: [])))
    }

    func testAnUnknownMachineIsNotRecorded() {
        XCTAssertNil(said("the ZZ9000 has no heat"))
    }

    func testASeriesMemberIsRecognisedAsTheToolDoes() throws {
        let unit = try XCTUnwrap(said("a QXT99UH400AB with no heat", index: Fixture.series))
        XCTAssertEqual(unit.change, .firstUnit)
        XCTAssertTrue(unit.identity.isSeriesMember)
    }

    func testASeriesMemberSaidInFullKeepsTheLetter() throws {
        let short = Fixture.identity("QXT99UH400A", in: Fixture.series)
        let unit = try XCTUnwrap(said("it's the QXT99UH400AB", active: short, index: Fixture.series))
        XCTAssertEqual(unit.change, .fullerSpelling)
    }

    func testAnotherSeriesMemberIsAnotherUnit() {
        XCTAssertEqual(EquipmentRecognition.change(from: Fixture.identity("QXT99UH400AB", in: Fixture.series),
                                                   to: Fixture.identity("QXT99UH500AB", in: Fixture.series)),
                       .anotherUnit)
    }

    func testChangeAgainstAnotherSection() {
        XCTAssertEqual(EquipmentRecognition.change(from: Fixture.identity("QX100"), to: Fixture.identity("QX200")),
                       .anotherUnit)
        XCTAssertEqual(EquipmentRecognition.change(from: nil, to: Fixture.identity("QX200")), .firstUnit)
    }

    func testTheNameplatesSpellingMovesNothing() {
        let plate = EquipmentIdentity(model: Fixture.model("QX100"), token: "QX100", source: .nameplate)
        XCTAssertEqual(EquipmentRecognition.change(from: Fixture.identity("QX100-A01"), to: plate), .sameUnit)
    }

    func testSeveralModelsStillReachTheToolAsAQuestion() {
        guard case .several(let models) = EquipmentRecognition.reading(of: "QX", source: .spoken, index: Fixture.index) else {
            return
        }
        XCTAssertGreaterThan(models.count, 1)
    }

    func testRestatingTheUnit() {
        let active = Fixture.identity("QX100-A01")
        for text in ["QX100", "QX100-A01", "QX100, no heat, nameplate missing", "the qx100-a01 again"] {
            XCTAssertTrue(EquipmentRecognition.restates(active, in: text), text)
        }
        for text in ["QX200", "QX100 fault E5", "no heat at all"] {
            XCTAssertFalse(EquipmentRecognition.restates(active, in: text), text)
        }
        XCTAssertFalse(EquipmentRecognition.restates(Fixture.identity("QX100"), in: "QX100-A01"), "a fuller spelling can change the unit")
    }
}

// MARK: - Documents by model

final class AssignedDocumentsTests: XCTestCase {

    private let library: [(id: String, title: String)] = [
        ("a02", "A02 Acme Service Manual"), ("a11", "A11 Acme User Manual"), ("a21", "A21 Acme Options Guide"),
        ("a03", "A03 Acme Service Manual"), ("sm7", "Acme Harness Guide SM-70012"), ("plain", "Acme Field Notes"),
    ]

    func testASectionKeepsItsOwnText() {
        let section = Fixture.model("QX100")
        XCTAssertTrue(section.body.contains("S:A02"))
        XCTAssertTrue(section.body.contains("### Notes"), "a sub-heading with no model in it belongs to the section")
        XCTAssertFalse(section.body.contains("A03"), "the next model's section is its own")
        XCTAssertFalse(Fixture.model("QX200").body.contains("A99"), "nor does a section run on past a heading of its depth")
    }

    func testAHeadingWithNoModelEndsTheSection() {
        let index = VaultModelIndex(vaultName: "V", files: [("m.md", "## QX100\nS:A02\n## Safety\nSee A03\n")])
        XCTAssertEqual(index.models[0].body, "S:A02")
    }

    func testIdsAreReadByTheFirstWordOfATitle() {
        XCTAssertEqual(Fixture.model("QX200").assignedDocumentIds(among: library), ["a03"])
    }

    func testIdsAreReadByTheDocumentNumber() {
        let assigned = Fixture.model("QX100").assignedDocumentIds(among: library)
        XCTAssertEqual(assigned, ["a02", "a11", "a21", "sm7"], "any layout, and the number a title carries")
    }

    func testTheNumberNeedNotOpenTheTitle() {
        let section = VaultModelIndex(vaultName: "V", files: [("m.md", "## QX100\nManual AB12345 applies\n")]).models[0]
        XCTAssertEqual(section.assignedDocumentIds(among: [("x", "Acme Service Manual AB12345"), ("y", "Acme Service Manual AB12346")]), ["x"])
    }

    func testAMissNamesTheGapAndNeverAsksToEscalate() {
        let sentence = RetrievalEvidencePolicy.insufficientSentence
        XCTAssertFalse(sentence.contains("escalation"), sentence)
        XCTAssertTrue(sentence.contains("name what is missing"), sentence)
        XCTAssertTrue(sentence.contains("offer an expert"), sentence)
    }

    func testAWordOfATitleMustLookLikeADocumentNumber() {
        XCTAssertTrue(VaultModelIndex.isDocumentNumber("AB12345"))
        XCTAssertTrue(VaultModelIndex.isDocumentNumber("SM-70012"))
        XCTAssertFalse(VaultModelIndex.isDocumentNumber("A123"), "too short")
        XCTAssertFalse(VaultModelIndex.isDocumentNumber("ABCD-123"), "too few digits")
        XCTAssertFalse(VaultModelIndex.isDocumentNumber("R-1234YF"), "a designation with four digits is not a number")
        XCTAssertFalse(VaultModelIndex.isDocumentNumber("SM-7001"), "four digits is one short")
        XCTAssertEqual(VaultModelIndex.documentIdentifiers(title: "Acme Q-99X Guide"), [],
                       "a designation inside a title is not a document's id")
        XCTAssertEqual(VaultModelIndex.documentIdentifiers(title: "A02 Q-99X Guide"), ["A02"], "the first word still is")
    }

    func testARefrigerantInATitleAndInASectionAssignsNothing() {
        let body = "## QX100\nCharged with Q-99X. Service: A02\n"
        let section = VaultModelIndex(vaultName: "V", files: [("m.md", body)]).models[0]
        let documents = [("a02", "A02 Acme Service Manual"), ("guide", "Acme Q-99X Charging Guide"), ("other", "Acme Field Notes")]
        XCTAssertEqual(section.assignedDocumentIds(among: documents), ["a02"], "the guide is not ranked as this model's own")
    }

    func testARefrigerantAloneLeavesTheVaultUnassigned() {
        let section = VaultModelIndex(vaultName: "V", files: [("m.md", "## QX100\nCharged with Q-99X.\n")]).models[0]
        XCTAssertTrue(section.assignedDocumentIds(among: [("guide", "Acme Q-99X Charging Guide"), ("a03", "A03 Manual")]).isEmpty,
                      "or every other document would rank down behind it")
    }

    func testCaseAndHyphensAside() {
        let section = VaultModelIndex(vaultName: "V", files: [("m.md", "## QX100\nsee a-02\n")]).models[0]
        XCTAssertEqual(section.assignedDocumentIds(among: library), ["a02"])
    }

    func testASuffixListNamesNoDocument() {
        let section = VaultModelIndex(vaultName: "V", files: [("m.md", "## QX100\nsuffix:00,01\n")]).models[0]
        XCTAssertTrue(section.assignedDocumentIds(among: [("x", "00 Notes"), ("y", "01 Notes")]).isEmpty)
    }

    func testAWordOfProseNamesNoDocument() {
        let section = VaultModelIndex(vaultName: "V", files: [("m.md", "## QX100\nAcme service notes\n")]).models[0]
        XCTAssertTrue(section.assignedDocumentIds(among: library).isEmpty, "a title's first word needs to be an id")
    }

    func testASectionNamingNothingAssignsNothing() {
        XCTAssertTrue(Fixture.model("QY300").assignedDocumentIds(among: library).isEmpty)
    }

    func testAnUnassignedDocumentTakesTheSamePenalty() {
        let scope = VaultRetriever.ModelScope(activeTokens: ["QX100"], otherTokens: ["QX200"], assignedDocumentIds: ["a02"])
        XCTAssertEqual(scope.penalty(for: "a generic page", documentId: "a03"), scope.penalty)
        XCTAssertEqual(scope.penalty(for: "a generic page", documentId: "a02"), 0)
    }

    func testThePenaltyIsNeverTakenTwice() {
        let scope = VaultRetriever.ModelScope(activeTokens: ["QX100"], otherTokens: ["QX200"], assignedDocumentIds: ["a02"])
        XCTAssertEqual(scope.penalty(for: "applies to the QX200", documentId: "a03"), scope.penalty)
        XCTAssertEqual(scope.penalty(for: "applies to the QX200", documentId: "a02"), scope.penalty,
                       "the existing rule is unchanged inside an assigned document")
    }

    func testNoAssignedDocumentsIsTodaysRule() {
        let scope = VaultRetriever.ModelScope(activeTokens: ["QX100"], otherTokens: ["QX200"])
        XCTAssertEqual(scope.penalty(for: "a generic page", documentId: "a03"), 0)
        XCTAssertEqual(scope.penalty(for: "applies to the QX200", documentId: "a03"), scope.penalty)
    }

    private func retriever(_ passages: [DocumentStore.Passage], assigned: Set<String>) -> VaultRetriever {
        VaultRetriever(query: { _, _ in passages },
                       modelScope: .init(activeTokens: ["QX100"], otherTokens: ["QX200"], assignedDocumentIds: assigned))
    }

    func testAnUnassignedPageRanksDownNotOut() {
        let outcome = retriever([Fixture.passage("a03", similarity: 0.9), Fixture.passage("a02", similarity: 0.7)],
                                assigned: ["a02"]).retrieve(.init(turn: "flame sensor"))
        XCTAssertEqual(outcome.passages.map(\.documentId), ["a02", "a03"])
        XCTAssertEqual(outcome.passages[1].modelPenalty, 0.5)
    }

    func testAVaultNamingNoDocumentsRanksAsToday() {
        let outcome = retriever([Fixture.passage("a03", similarity: 0.9), Fixture.passage("a02", similarity: 0.7)],
                                assigned: []).retrieve(.init(turn: "flame sensor"))
        XCTAssertEqual(outcome.passages.map(\.documentId), ["a03", "a02"])
    }

    func testATeamLearningIsScopedAsBefore() {
        let learning = Fixture.passage("note", source: .teamLearning, modelToken: "QX100", similarity: 0.9)
        let outcome = retriever([learning, Fixture.passage("a02", similarity: 0.7)], assigned: ["a02"])
            .retrieve(.init(turn: "flame sensor"))
        XCTAssertEqual(outcome.passages.first { $0.documentId == "note" }?.modelPenalty, 0)
    }

    func testAPhotographedManualIsTheJobsOwn() {
        let photographed = Fixture.passage("captured:1", source: .capturedManual, similarity: 0.9)
        let outcome = retriever([photographed, Fixture.passage("a02", similarity: 0.7)], assigned: ["a02"])
            .retrieve(.init(turn: "flame sensor"))
        XCTAssertEqual(outcome.passages.first { $0.documentId == "captured:1" }?.modelPenalty, 0)
    }
}

// MARK: - A follow-up keeps the job's subject

final class JobSearchContextTests: XCTestCase {

    func testAQuestionOrADescriptionSaysWhatTheJobIsAbout() {
        for turn in ["why would the igniter not glow", "the fan runs but there is no heat"] {
            XCTAssertTrue(JobSearchContext.describesTheJob(turn), turn)
        }
    }

    func testBookkeepingReadingsCorrectionsAndAYesDoNot() {
        for turn in ["close the job", "supply air is 140", "135 not 140", "show me the wiring diagram", "yes", "ok thanks"] {
            XCTAssertFalse(JobSearchContext.describesTheJob(turn), turn)
        }
    }

    func testKeepingHoldsTheNewestAndDropsARepeat() {
        var turns: [String] = []
        for turn in ["no heat on a call", "the igniter glows briefly", "the igniter glows briefly",
                     "supply air is 140", "the blower never starts", "the inducer hums loudly", "the board flashes twice"] {
            turns = JobSearchContext.keeping(turn, after: turns)
        }
        XCTAssertEqual(turns, ["the igniter glows briefly", "the blower never starts",
                               "the inducer hums loudly", "the board flashes twice"])
        XCTAssertEqual(turns.count, JobSearchContext.turnsHeld)
    }

    func testAJobNumberNeverEntersTheContext() {
        let turns = JobSearchContext.keeping("the customer on job 4417 says it trips", after: [])
        XCTAssertEqual(turns, ["the customer on job says it trips"])
    }

    func testTheContextIsTheUnitAndTheLastTwoTurns() {
        XCTAssertEqual(JobSearchContext.context(unit: "QX100-A01", earlierTurns: ["one thing", "no heat", "igniter glows"],
                                                current: "what next", otherModels: []),
                       "QX100-A01. no heat. igniter glows")
    }

    func testTheTurnInFlightIsNotItsOwnContext() {
        XCTAssertEqual(JobSearchContext.context(unit: nil, earlierTurns: ["no heat", "what next"], current: "what next",
                                                otherModels: []), "no heat")
    }

    func testATurnAboutAnotherModelStaysOut() {
        XCTAssertEqual(JobSearchContext.context(unit: "QX100", earlierTurns: ["no heat", "the QX200 does that too"],
                                                current: "what next", otherModels: ["QX200"]), "QX100. no heat")
    }

    func testNothingToAddIsNil() {
        XCTAssertNil(JobSearchContext.context(unit: nil, earlierTurns: [], current: "what next", otherModels: []))
    }

    func testARefusalSearchesAgain() {
        XCTAssertTrue(JobSearchContext.searchesAgain(after: .insufficient(reason: "no"), assigned: []))
    }

    func testAnAnswerSearchesAgainOnlyWhenItMissedTheAssignedDocuments() {
        let found = RetrievalOutcome.sufficient([Fixture.found("a03")])
        XCTAssertFalse(JobSearchContext.searchesAgain(after: found, assigned: []))
        XCTAssertFalse(JobSearchContext.searchesAgain(after: found, assigned: ["a03"]))
        XCTAssertTrue(JobSearchContext.searchesAgain(after: found, assigned: ["a02"]))
    }

    func testASecondFailureLeavesTheRefusalAsItWas() {
        let refusal = RetrievalOutcome.insufficient(reason: "the turn's own")
        XCTAssertEqual(JobSearchContext.merged(own: refusal, context: .insufficient(reason: "another"), assigned: []), refusal)
    }

    func testARefusedTurnTakesWhatTheSecondSearchCleared() {
        let context = RetrievalOutcome.sufficient([Fixture.found("a02")])
        XCTAssertEqual(JobSearchContext.merged(own: .insufficient(reason: "no"), context: context, assigned: []), context)
    }

    func testItCanOnlyAddPassages() {
        let own = RetrievalOutcome.sufficient([Fixture.found("a03")])
        let context = RetrievalOutcome.sufficient([Fixture.found("a02", 1), Fixture.found("a02", 2), Fixture.found("a02", 3),
                                                   Fixture.found("a03"), Fixture.found("a11")])
        let merged = JobSearchContext.merged(own: own, context: context, assigned: ["a02"])
        XCTAssertEqual(merged.passages.map(\.documentId), ["a03", "a02", "a02"], "what it found stays first")
        XCTAssertTrue(merged.isSufficient)
    }

    func testPassagesFromOtherDocumentsAddNothingToAnAnswer() {
        let own = RetrievalOutcome.sufficient([Fixture.found("a03")])
        XCTAssertEqual(JobSearchContext.merged(own: own, context: .sufficient([Fixture.found("a11")]), assigned: ["a02"]), own)
    }

    func testALearningOnlyTurnGainsItsManualAndKeepsTheLearning() {
        let learning = Fixture.found("note", source: .teamLearning)
        let merged = JobSearchContext.merged(own: .teamLearningOnly([learning]), context: .sufficient([Fixture.found("a02")]),
                                             assigned: ["a02"])
        XCTAssertTrue(merged.isSufficient)
        XCTAssertEqual(merged.passages.map(\.documentId), ["a02", "note"])
    }

    func testTheContextIsSearchedButNeverBoosted() {
        // The model's number is on the page, the only one that shares nothing else with the turn.
        let page = Fixture.passage("a02", text: "QX100 cabinet dimensions", similarity: 0.2)
        var request = VaultRetriever.Request(turn: "the tech sheet is missing")
        request.jobContext = "QX100"
        var searched: [String] = []
        let retriever = VaultRetriever(query: { query, _ in searched.append(query); return [page] },
                                       tokenSearch: { _, _ in [page] },
                                       policy: RetrievalEvidencePolicy(similarityFloor: 0.5))
        XCTAssertFalse(retriever.retrieve(request).answers, "the unit's number vouches for nothing")
        XCTAssertTrue(searched.contains("QX100"), "it is searched like the step's title")
    }
}

// MARK: - A miss is not an escalation

final class ExpertRequestWordsTests: XCTestCase {

    func testAskingForAPerson() {
        for said in ["get me an expert", "I want to talk to a person", "can I speak to someone", "escalate this",
                     "call the supervisor", "I need a human", "page the expert", "expert please", "an expert",
                     "can you get someone on the line", "let's escalate"] {
            XCTAssertTrue(TechnicianRequest.asksForExpert(said), said)
        }
    }

    func testNotAskingForAPerson() {
        for said in ["the tech sheet is missing, what next?", "no heat on a call", "what does an expert do",
                     "I don't need an expert", "without calling anyone or a supervisor", "what's the next check",
                     "the person who installed it left", "not escalating this"] {
            XCTAssertFalse(TechnicianRequest.asksForExpert(said), said)
        }
    }

    func testAYesToAnOffer() {
        let offer = "The manuals don't cover the tech sheet. Want me to get an expert?"
        for said in ["yes", "yeah go ahead", "ok do it"] {
            XCTAssertTrue(TechnicianRequest.confirmsExpertOffer(said, previousReply: offer), said)
        }
    }

    func testAYesToSomethingElse() {
        XCTAssertFalse(TechnicianRequest.confirmsExpertOffer("yes", previousReply: "The next check is the flame sensor. Ready?"))
        XCTAssertFalse(TechnicianRequest.confirmsExpertOffer("yes", previousReply: nil))
        XCTAssertFalse(TechnicianRequest.confirmsExpertOffer("yes, but what about the fan?",
                                                             previousReply: "Want me to get an expert?"))
    }

    // MARK: Plan KJ P2: an offer has to be an offer

    private static let aMention = "If the reading stays there, escalate rather than treating it as a pass. "
        + "Source: Field Guide, page 20."

    func testAYesAfterARealOfferPasses() {
        let offers = [
            "I don't want to guess. Would you like me to escalate this to an expert? Source: Field Guide, page 20.",
            "I don't want to guess. Would you like me to escalate this to an expert?\nSource: Field Guide, page 20.",
            "I can get an expert if you want.",
            "I could call a supervisor.",
            "Happy to bring in a specialist.",
            "Let me know if you need someone.",
            "We can escalate this if you'd like.",
            "We can escalate this if you\u{2019}d like.",
            "Say the word and I'll page the expert.",
            "Want an expert on that 0.28 reading?",
        ]
        for offer in offers {
            XCTAssertTrue(TechnicianRequest.confirmsExpertOffer("yes", previousReply: offer), offer)
            XCTAssertNil(EscalateToExpertTool.refusal(said: "yes", previousReply: offer), offer)
        }
    }

    func testAShortYesAfterAMentionIsRefused() {
        for said in ["Okay I will check it", "Right, the meter is on ohms", "Yeah that's right", "yes"] {
            XCTAssertFalse(TechnicianRequest.confirmsExpertOffer(said, previousReply: Self.aMention), said)
            XCTAssertEqual(EscalateToExpertTool.refusal(said: said, previousReply: Self.aMention),
                           EscalateToExpertTool.notRequested, said)
        }
    }

    /// The person and the offer have to be in the same sentence.
    func testAnOfferFarFromThePersonIsNoOffer() {
        let replies = [
            "I can check the fan next. The expert note says it runs on high.",
            "The supervisor signed it off. Anything else?",
            "I can't reach an expert from here.",
            "The next step is to escalate.\nAnything else?",
        ]
        for reply in replies {
            XCTAssertFalse(TechnicianRequest.confirmsExpertOffer("yes", previousReply: reply), reply)
        }
    }

    func testTheGateFollowsTheWords() {
        XCTAssertEqual(EscalateToExpertTool.refusal(said: "what next", previousReply: nil), EscalateToExpertTool.notRequested)
        XCTAssertNil(EscalateToExpertTool.refusal(said: "get me an expert", previousReply: nil))
        XCTAssertNil(EscalateToExpertTool.refusal(said: "yes", previousReply: "Want me to page an expert?"))
    }

    func testNoCapturedWordsIsNotGated() {
        XCTAssertNil(EscalateToExpertTool.refusal(said: nil, previousReply: nil))
    }

    func testOnlyPagingIsGated() {
        for (tool, action) in [("escalate_to_expert", "request"), ("escalate_to_expert", "escalate"),
                               ("escalate_to_expert", "REQUEST"), ("field_session", "escalate")] {
            XCTAssertTrue(EscalateToExpertTool.pagesAnExpert(tool: tool, args: ["action": action]), action)
        }
        for (tool, action) in [("escalate_to_expert", "status"), ("escalate_to_expert", "resolve"),
                               ("escalate_to_expert", "cancel"), ("field_session", "status"), ("web_search", "escalate")] {
            XCTAssertFalse(EscalateToExpertTool.pagesAnExpert(tool: tool, args: ["action": action]), action)
        }
    }

    func testTheRefusalIsWordForWord() {
        XCTAssertEqual(EscalateToExpertTool.notRequested,
                       "Not requested: name what the manuals do not cover and offer an expert.")
    }

    @MainActor func testTheDescriptionKeepsARequestAndASafetyConcernReachable() {
        let description = EscalateToExpertTool().description
        XCTAssertFalse(description.contains("cannot safely resolve"))
        XCTAssertTrue(description.contains("asks for a person"))
        XCTAssertTrue(description.contains("unsafe"))
    }

    func testDeclinePagingKeepsHelping() {
        let text = ToolAuthorizationPolicy.declineMessage("escalate_to_expert")
        XCTAssertTrue(text.contains("Keep helping with what the manuals support"), text)
        XCTAssertTrue(text.contains("do not stop"), text)
        XCTAssertFalse(text.contains("cancelled"), text)
    }

    func testEveryOtherToolsDeclineIsByteIdentical() {
        for name in ["send_message", "field_session", "smart_home"] {
            XCTAssertEqual(ToolAuthorizationPolicy.declineMessage(name),
                           "The user did NOT approve this action, so '\(name)' was not performed. Do not retry it; tell the user it was cancelled unless they explicitly ask again.")
        }
    }
}

/// The refusal comes before the card: declining a card nobody wanted is what ended the diagnosis.
@MainActor
final class ExpertRequestRouterTests: XCTestCase {

    private final class ExecutionSpy { var count = 0 }

    private struct SpyTool: NativeTool {
        let name: String
        let description = "spy"
        let spy: ExecutionSpy
        var parametersSchema: [String: Any] { ["type": "object"] }
        func execute(args: [String: Any]) async throws -> String {
            spy.count += 1
            return "ran:\(name)"
        }
    }

    private var coordinator: ToolConfirmationCoordinator!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private func router(said: String?, previousReply: String? = nil, spy: ExecutionSpy) -> NativeToolRouter {
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(SpyTool(name: "escalate_to_expert", spy: spy))
        registry.register(SpyTool(name: "field_session", spy: spy))
        let router = NativeToolRouter(registry: registry)
        router.vaultOnlySealed = { false }
        coordinator = ToolConfirmationCoordinator()
        router.confirmationCoordinator = coordinator
        router.technicianWords = { said }
        router.previousReply = { previousReply }
        return router
    }

    /// Answers the card when it goes up; returns whether one did.
    private func answerCard(_ approved: Bool) async throws -> Bool {
        for _ in 0..<50 {
            if coordinator.pending != nil {
                coordinator.resolve(approved)
                return true
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func testAMissIsRefusedWithNoCardByEitherDoor() async throws {
        let spy = ExecutionSpy()
        let router = router(said: "the tech sheet is missing, what next?", spy: spy)
        for (name, action) in [("escalate_to_expert", "request"), ("field_session", "escalate")] {
            let outcome = await router.executeRoot(name: name, args: ["action": action, "reason": "manual miss"])
            XCTAssertEqual(outcome, .rejected(reason: EscalateToExpertTool.notRequested), name)
        }
        XCTAssertNil(coordinator.pending, "no card")
        XCTAssertEqual(spy.count, 0)
        XCTAssertEqual(router.authorizationEvents.events.map(\.verdict),
                       Array(repeating: ToolRefusalReason.expertNotRequested.rawValue, count: 2))
    }

    func testAskingStillGetsTheCard() async throws {
        let spy = ExecutionSpy()
        let router = router(said: "get me an expert", spy: spy)
        async let outcome = router.executeRoot(name: "escalate_to_expert", args: ["action": "request", "reason": "asked"])
        let asked = try await answerCard(true)
        let result = await outcome
        XCTAssertTrue(asked, "the card is still the technician's")
        XCTAssertEqual(result, .completed("ran:escalate_to_expert"))
        XCTAssertEqual(spy.count, 1)
    }

    func testAYesToTheOfferGoesThrough() async throws {
        let spy = ExecutionSpy()
        let router = router(said: "yes", previousReply: "I can't place that. Want me to get an expert?", spy: spy)
        async let outcome = router.executeRoot(name: "escalate_to_expert", args: ["action": "request", "reason": "asked"])
        _ = try await answerCard(true)
        let result = await outcome
        XCTAssertEqual(result, .completed("ran:escalate_to_expert"))
    }

    func testDecliningTheCardKeepsTheDiagnosisGoing() async throws {
        let spy = ExecutionSpy()
        let router = router(said: "get me an expert", spy: spy)
        async let outcome = router.executeRoot(name: "escalate_to_expert", args: ["action": "request", "reason": "asked"])
        _ = try await answerCard(false)
        let result = await outcome
        XCTAssertEqual(result, .rejected(reason: ToolAuthorizationPolicy.declineMessage("escalate_to_expert")))
        XCTAssertEqual(spy.count, 0)
    }

    func testATurnWithNoWordsIsNotGated() async throws {
        let spy = ExecutionSpy()
        let router = router(said: nil, spy: spy)
        async let outcome = router.executeRoot(name: "escalate_to_expert", args: ["action": "request", "reason": "live"])
        let asked = try await answerCard(true)
        _ = await outcome
        XCTAssertTrue(asked, "a live session's call reaches the card as it always did")
    }

    func testStatusIsNeverGated() async {
        let spy = ExecutionSpy()
        let router = router(said: "what next", spy: spy)
        let outcome = await router.executeRoot(name: "field_session", args: ["action": "status"])
        XCTAssertEqual(outcome, .completed("ran:field_session"))
    }
}

// MARK: - The loop

@MainActor
final class ToolRepeatGuardTests: XCTestCase {

    private static let status = ToolInvocation(id: "s", name: "field_session", arguments: ["action": "status"])
    private static let setUnit = ToolInvocation(id: "e", name: "equipment_lookup", arguments: ["set_equipment": "QX100"])
    private static let freeText = ToolInvocation(id: "q", name: "equipment_lookup",
                                                 arguments: ["query": "QX100, no heat, nameplate missing"])

    /// Runs `turns`, recording what ran and what every call was answered.
    private func run(_ turns: [[ToolInvocation]], active: @escaping () -> String = { "QX100" },
                     onRun: @escaping (String, [String: Any]) -> ToolExecutionOutcome = { name, _ in .completed("ok:\(name)") },
                     maxIterations: Int = 10) async throws -> (ran: [String], answers: [ToolDispatchOutcome], spoken: String) {
        var ran: [String] = []
        var answers: [ToolDispatchOutcome] = []
        var index = 0
        let adapter = ProviderLoopAdapter(
            label: "Test",
            dispatcher: ToolDispatcher(execute: { name, args, _, _ in
                ran.append(name)
                return onRun(name, args)
            }, onStatus: { _ in }),
            performTurn: {
                defer { index += 1 }
                guard index < turns.count else { return AssistantTurn(text: "done") }
                return AssistantTurn(text: "", toolCalls: turns[index])
            },
            appendAssistantToolCall: { _ in },
            appendToolResults: { answers += $0 },
            finalize: { $0.text })
        let spoken = try await runToolLoop(
            maxIterations: maxIterations, adapter: adapter,
            repeatGuard: ToolRepeatGuard(namesActiveUnit: { text in
                let unit = active()
                return EquipmentRecognition.restates(EquipmentIdentity(modelToken: unit, heading: unit, file: "m.md", source: .spoken,
                                                                       statedModel: unit), in: text)
            }),
            setStatus: { _ in })
        return (ran, answers, spoken)
    }

    func testTheReplaysCallsAreAnsweredAndTheManualIsNext() async throws {
        let search = ToolInvocation(id: "m", name: "manual_lookup", arguments: ["query": "no heat"])
        let result = try await run([[Self.status], [Self.setUnit], [Self.status], [Self.freeText], [search]])

        XCTAssertEqual(result.ran, ["field_session", "equipment_lookup", "manual_lookup"],
                       "a status and a free-text restatement of the unit do not run")
        XCTAssertEqual(result.answers.count, 5, "every call has its answer, so the history stays whole")
        XCTAssertEqual(result.answers[3].outcome, .rejected(reason: ToolRepeatGuard.youHaveThis("equipment_lookup")))
        XCTAssertEqual(result.answers[2].outcome, .rejected(reason: ToolRepeatGuard.youHaveThis("field_session")))
        XCTAssertEqual(result.spoken, "done", "and the turn ends in the model's words")
    }

    func testTheWordsAreAsPlanned() {
        XCTAssertEqual(ToolRepeatGuard.youHaveThis("field_session"),
                       "'field_session' was not run: you have this; search the manual for the symptom or answer.")
    }

    func testTwoInOneRoundAreOneRepeat() async throws {
        let result = try await run([[Self.status, Self.status]])
        XCTAssertEqual(result.ran, ["field_session"])
        XCTAssertEqual(result.answers.count, 2)
    }

    func testAnotherUnitStillRuns() async throws {
        let other = ToolInvocation(id: "o", name: "equipment_lookup", arguments: ["set_equipment": "QX200"])
        let result = try await run([[Self.setUnit], [other]])
        XCTAssertEqual(result.ran, ["equipment_lookup", "equipment_lookup"])
    }

    func testAFullerSpellingStillRuns() async throws {
        let fuller = ToolInvocation(id: "f", name: "equipment_lookup", arguments: ["set_equipment": "QX100-A01"])
        let result = try await run([[Self.setUnit], [fuller]])
        XCTAssertEqual(result.ran.count, 2)
    }

    func testAFaultCodeBesideTheUnitIsARealLookup() async throws {
        let code = ToolInvocation(id: "c", name: "equipment_lookup", arguments: ["query": "QX100 fault E5"])
        let result = try await run([[Self.setUnit], [code]])
        XCTAssertEqual(result.ran.count, 2)
    }

    func testTwoDifferentCodesBothRun() async throws {
        let first = ToolInvocation(id: "1", name: "equipment_lookup", arguments: ["query": "E5"])
        let second = ToolInvocation(id: "2", name: "equipment_lookup", arguments: ["query": "E7"])
        let result = try await run([[first], [second]], active: { "" })
        XCTAssertEqual(result.ran.count, 2)
    }

    func testTheSameQueryTwiceRunsOnce() async throws {
        let code = ToolInvocation(id: "1", name: "equipment_lookup", arguments: ["query": "E5"])
        let again = ToolInvocation(id: "2", name: "equipment_lookup", arguments: ["query": " e5 "])
        let result = try await run([[code], [again]])
        XCTAssertEqual(result.ran.count, 1)
    }

    func testStatusRunsAgainAfterSomethingChanged() async throws {
        let task = ToolInvocation(id: "t", name: "task", arguments: ["action": "add"])
        let result = try await run([[Self.status], [task], [Self.status]])
        XCTAssertEqual(result.ran, ["field_session", "task", "field_session"])
    }

    func testStatusRunsAgainAfterTheUnitChanged() async throws {
        var unit = ""
        let result = try await run([[Self.status], [Self.setUnit], [Self.status]], active: { unit }, onRun: { name, _ in
            if name == "equipment_lookup" { unit = "QX100" }
            return .completed("ok:\(name)")
        })
        XCTAssertEqual(result.ran, ["field_session", "equipment_lookup", "field_session"],
                       "the status from before the unit is no longer the status")
    }

    func testSearchingTheManualChangesNothing() async throws {
        let search = ToolInvocation(id: "m", name: "manual_lookup", arguments: ["query": "no heat"])
        let result = try await run([[Self.status], [search], [Self.status]])
        XCTAssertEqual(result.ran, ["field_session", "manual_lookup"])
    }

    func testAFailedCallAnswersNothing() async throws {
        var failures = 1
        let result = try await run([[Self.status], [Self.status]], onRun: { name, _ in
            defer { failures -= 1 }
            return failures > 0 ? .failedBeforeExecution(reason: "no") : .completed("ok:\(name)")
        })
        XCTAssertEqual(result.ran.count, 2)
    }

    func testWritesAndTheCameraAlwaysRun() async throws {
        for args: [String: Any] in [["clear_equipment": true], ["use_camera": true], ["serial": "AB123"],
                                    ["field_name": "firmware", "field_value": "2.1"], [:]] {
            let call = ToolInvocation(id: "w", name: "equipment_lookup", arguments: args)
            let result = try await run([[call], [call]], maxIterations: 2)
            XCTAssertEqual(result.ran.count, 2, "\(args)")
        }
    }

    func testOtherFieldSessionActionsAreNotGuarded() async throws {
        let list = ToolInvocation(id: "l", name: "field_session", arguments: ["action": "list"])
        let result = try await run([[list], [list]], maxIterations: 2)
        XCTAssertEqual(result.ran.count, 2)
    }

    func testAModelThatKeepsGoingIsStoppedByTheBackstop() async throws {
        let turns = [[Self.status, Self.freeText]] + Array(repeating: [Self.status, Self.freeText], count: 8)
        let result = try await run(turns, maxIterations: 12)
        XCTAssertEqual(result.ran.count, 2, "only the first round ran")
        XCTAssertLessThanOrEqual(result.answers.count, 8, "told once, then the repeat stop ended the turn")
        XCTAssertGreaterThanOrEqual(ToolLoopBudget.repeatsBeforeWrapUp, 2)
    }
}
