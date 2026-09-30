import XCTest
@testable import OpenGlasses

/// Plan GB P1 — which manual pages open by themselves, and what a page on screen is evidence of.
@MainActor
final class ManualPagePolicyTests: XCTestCase {

    // MARK: - Turn kinds

    func testTheFieldTestsTurnsClassify() {
        let table: [(String, ManualTurnKind)] = [
            ("0.28", .reading),
            ("0.35", .reading),
            ("supply air is 140", .reading),
            ("inducer pressure 0.28 inches", .reading),
            ("135 not 140", .correction),
            ("sorry I meant 0.35", .correction),
            ("correct the job number to 1011", .jobBookkeeping),
            ("open a new job 108", .jobBookkeeping),
            ("show me the wiring diagram", .showMe),
            ("pull up table 8", .showMe),
            ("open page 30", .showMe),
            ("what's the temperature rise range?", .question),
            ("what does 24VAXC connect to", .question),
            ("is 0.28 inches ok", .question),
            ("the customer says it hums at night and started last week after the storm", .statement),
        ]
        for (turn, kind) in table {
            XCTAssertEqual(ManualTurnClassifier.classify(turn), kind, turn)
        }
    }

    // MARK: - The policy table

    func testOnlyQuestionsAndRequestsPutAPageOnThePhone() {
        typealias P = FigureAutoOpenPolicy
        XCTAssertEqual(P.decide(turnKind: .showMe, passageKind: .captioned, tokenHits: ["35"]),
                       .present(reason: .askedForPage), "asked for: a table opens, numbers and all")
        XCTAssertEqual(P.decide(turnKind: .question, passageKind: .diagram, tokenHits: ["24VAXC"]),
                       .present(reason: .diagramForQuestion))
        XCTAssertEqual(P.decide(turnKind: .question, passageKind: .captioned, tokenHits: []),
                       .attachToModelOnly(reason: .tableNotAskedFor))
        XCTAssertEqual(P.decide(turnKind: .statement, passageKind: .diagram, tokenHits: []),
                       .attachToModelOnly(reason: .notAQuestion), "the model still sees the drawing (EK §4)")
        XCTAssertEqual(P.decide(turnKind: .statement, passageKind: .captioned, tokenHits: []),
                       .none(reason: .notAQuestion))
        for kind in [ManualTurnKind.reading, .correction, .jobBookkeeping] {
            for passage in [P.PassageKind.diagram, .captioned] {
                XCTAssertFalse(P.decide(turnKind: kind, passageKind: passage, tokenHits: ["SLP99"]).stagesFigure,
                               "\(kind) never stages a page")
            }
        }
        XCTAssertEqual(P.decide(turnKind: .question, passageKind: nil, tokenHits: []),
                       .none(reason: .nothingFound))
    }

    func testAPageFoundOnlyThroughNumbersNeverOpens() {
        typealias P = FigureAutoOpenPolicy
        XCTAssertEqual(P.decide(turnKind: .question, passageKind: .captioned, tokenHits: ["135", "140"]),
                       .none(reason: .numbersOnly))
        XCTAssertEqual(P.decide(turnKind: .question, passageKind: .diagram, tokenHits: ["120"]),
                       .attachToModelOnly(reason: .numbersOnly))
        XCTAssertEqual(P.decide(turnKind: .question, passageKind: .diagram, tokenHits: ["120", "24VAXC"]),
                       .present(reason: .diagramForQuestion), "a real code in the hits is a reference")
    }

    // MARK: - Tokens

    func testDecimalsStayWholeAndAreNotCodes() {
        let candidates = CodeTokenizer.candidateTokens(from: "pressure 0.28 not 0.35")
        XCTAssertTrue(candidates.contains("0.28") && candidates.contains("0.35"), "\(candidates)")
        XCTAssertFalse(candidates.contains("28") || candidates.contains("35"), "\(candidates)")
        XCTAssertEqual(CodeTokenizer.codeTokens(from: "pressure 0.28"), [], "a reading is not a code")
        XCTAssertFalse(CodeTokenizer.codeTokens(from: "it reads 0.28").contains("28"))
        XCTAssertFalse(CodeTokenizer.codeTokens(from: "it reads 0.35").contains("35"))
        // Everything that is not a decimal splits as it always did.
        XCTAssertEqual(CodeTokenizer.codeTokens(from: "Model 30RB-060 Carrier fault E5"), ["30RB", "060", "E5"])
        XCTAssertEqual(CodeTokenizer.codeTokens(from: "E5.2"), ["E5"])
        XCTAssertEqual(CodeTokenizer.codeTokens(from: "135 not 140"), ["135", "140"],
                       "bare numbers stay in retrieval")
    }

    func testFullLengthModelNumbersAreKept() {
        XCTAssertEqual(CodeTokenizer.codeTokens(from: "unit SLP99UH090XV48CK"), ["SLP99UH090XV48CK"])
        XCTAssertEqual(CodeTokenizer.codeTokens(from: "unit SLP99UH070XB36B"), ["SLP99UH070XB36B"])
    }

    func testCorrectingTheJobNumberTakesTheNumberOutOfTheSearch() {
        XCTAssertTrue(ManualTurnScope.isJobManagement("correct the job number to 1011"))
        XCTAssertEqual(ManualTurnScope.removingJobReferences(from: "correct the job number to 1011"),
                       "correct the job number to")
        XCTAssertFalse(ManualTurnScope.isJobManagement("what does 24VAXC connect to"))
    }

    // MARK: - Page evidence

    func testOnlyAConfirmationVerifies() {
        typealias P = PageEvidencePolicy
        XCTAssertEqual(P.classify(origin: .automatic, confirmation: .none), .shown)
        XCTAssertEqual(P.classify(origin: .requested, confirmation: .none), .opened)
        XCTAssertEqual(P.classify(origin: .requested, confirmation: .spoken), .verified)
        XCTAssertEqual(P.classify(origin: .requested, confirmation: .tap), .verified)
        XCTAssertEqual(P.classify(origin: .automatic, confirmation: .tap), .verified,
                       "the page's own button is the technician's act on that page")
        XCTAssertEqual(P.classify(origin: .automatic, confirmation: .spoken), .shown,
                       "a sentence is not about a page nobody asked for")
    }

    func testOnePageHasOneLabelHoweverItWasReached() {
        XCTAssertEqual(PageEvidencePolicy.label(title: "Install", page: 65, figure: "Figure 65"),
                       "Install, page 65, Figure 65")
        XCTAssertEqual(PageEvidencePolicy.label(for: Citation(kind: .manual, title: "Install", page: 65,
                                                             figure: "Figure 65", isDiagram: true)),
                       "Install, page 65, Figure 65")
        XCTAssertEqual(PageEvidencePolicy.label(for: Citation(kind: .manual, title: "Install", page: 30)),
                       "Install, page 30")
    }

    func testSpokenConfirmationsAreStrict() {
        for yes in ["checked", "that matches", "that matches the manual", "yep confirmed",
                    "checked against the manual", "matches the table"] {
            XCTAssertTrue(SpokenPageConfirmation.isConfirmation(yes), yes)
        }
        for no in ["I checked the filter", "that doesn't match the manual", "not checked",
                   "what does the manual say", "supply air is 140", ""] {
            XCTAssertFalse(SpokenPageConfirmation.isConfirmation(no), no)
        }
    }

    // MARK: - Through the service

    private func service() throws -> (FieldSessionService, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualPagePolicyTests-\(UUID().uuidString)", isDirectory: true)
        let service = FieldSessionService(sessionsRoot: root)
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil)
        return (service, root)
    }

    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    /// Job 1011: six pages went up by themselves, none was opened, none confirmed.
    func testJob1011sSixPagesAreShownNotVerified() throws {
        let (service, root) = try service()
        defer { try? FileManager.default.removeItem(at: root) }
        for page in [17, 64, 65, 12, 41, 30] {
            service.pageDidOpen(.init(title: "SLP99UHVK Installation Instructions", page: page,
                                      figure: nil, origin: .automatic, source: .manufacturerPDF))
            service.pageDidClose()
        }
        let evidence = try XCTUnwrap(service.activeSession?.jobEvidence)
        XCTAssertEqual(evidence.pagesShown.count, 6)
        XCTAssertTrue(evidence.pagesVerified.isEmpty)
        XCTAssertTrue(evidence.citationsOpened.isEmpty)

        let record = try XCTUnwrap(service.workRecord())
        XCTAssertFalse(record.summaryLines.contains { $0.contains("verified") }, record.summary)
        XCTAssertTrue(record.jsonString.contains("pagesShown"), "kept in the JSON")
    }

    func testASpokenCheckVerifiesTheRequestedPageOnScreenAndNothingElse() throws {
        let (service, root) = try service()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(service.confirmOpenPage(.spoken), "nothing on screen, nothing to confirm")

        service.pageDidOpen(.init(title: "Service Manual", page: 17, figure: nil, origin: .automatic,
                                  source: .extractedText))
        XCTAssertEqual(service.confirmOpenPage(.spoken), .shown)
        service.pageDidOpen(.init(title: "Service Manual", page: 30, figure: nil, origin: .requested,
                                  source: .extractedText))
        XCTAssertEqual(service.confirmOpenPage(.spoken), .verified)
        XCTAssertEqual(service.verifiedPages, ["Service Manual, page 30"])
    }

    func testLegacyEvidenceDecodesAndEncodesUnchanged() throws {
        let legacy = #"{"citationsOpened":["A, page 1"],"pagesVerified":["A, page 1"],"photos":[],"readings":[]}"#
        let decoded = try JSONDecoder().decode(FieldSession.Evidence.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.pagesShown, [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(data: try encoder.encode(decoded), encoding: .utf8), legacy,
                       "nothing shown: byte-for-byte what it was")
    }
}
