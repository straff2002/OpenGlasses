import XCTest
@testable import OpenGlasses

// The licence core is compiled into this bundle too, so its authoring types shadow the app's here.
// Every name below is the app's own copy, the one the phone runs.
private typealias AppTemplate = OpenGlasses.TradeTemplate
private typealias AppStarter = OpenGlasses.VaultStarter
private typealias Row = OpenGlasses.DraftRow
private typealias FaultRow = OpenGlasses.FaultCodeRow
private typealias ModelRowT = OpenGlasses.ModelRow
private typealias SymptomRowT = OpenGlasses.SymptomRow
private typealias Page = OpenGlasses.DraftPage
private typealias Layer = OpenGlasses.DraftLayer

/// Plan LW P1 — the authoring screens' logic without a screen: the New Vault form's reading, where a
/// kept row lands in the vault's Markdown, the publishing check, the review rows and the vault
/// check's mapping. Invented codes, models and wording only.
final class VaultAuthoringPureTests: XCTestCase {

    // MARK: - New Vault

    func testModelsAreReadOnePerLineOrCommaWithSpellingsInBrackets() {
        let models = VaultAuthoring.models(fromText: "QX-100 (QX100, QX 100), QX-100A\nQX-200; ")
        XCTAssertEqual(models.map(\.name), ["QX-100", "QX-100A", "QX-200"])
        XCTAssertEqual(models.first?.aliases, ["QX100", "QX 100"])
        XCTAssertEqual(models[1].aliases, [])
    }

    func testAnEmptyModelsFieldGivesNoModels() {
        XCTAssertTrue(VaultAuthoring.models(fromText: "  \n , ;").isEmpty)
    }

    func testTheDefaultIdIsUsedWhenFreeAndNumberedWhenTaken() {
        XCTAssertNil(VaultAuthoring.freeId(forName: "Rooftop units", taken: ["other"]))
        XCTAssertEqual(VaultAuthoring.freeId(forName: "Rooftop units", taken: ["rooftop_units"]), "rooftop_units_2")
        XCTAssertEqual(VaultAuthoring.freeId(forName: "Rooftop units", taken: ["rooftop_units", "rooftop_units_2"]),
                       "rooftop_units_3")
    }

    func testTheTradeIsInferredFromTheManifestsTrades() {
        XCTAssertEqual(VaultAuthoring.inferredTemplate(trades: ["refrigeration_hvac"]).id, .hvacR)
        XCTAssertEqual(VaultAuthoring.inferredTemplate(trades: nil).id, .general)
        XCTAssertEqual(VaultAuthoring.inferredTemplate(trades: ["plumbing"]).id, .general)
    }

    // MARK: - Names

    func testACoreFileNameIsItsSlugWithMarkdown() {
        XCTAssertEqual(VaultAuthoring.coreFileName("Wiring notes"), "wiring-notes.md")
        XCTAssertEqual(VaultAuthoring.coreFileName("Wiring notes.md"), "wiring-notes.md")
        XCTAssertNil(VaultAuthoring.coreFileName("  .md "))
    }

    func testAManualFileNameIsItsTitlesSlugAndUnique() {
        XCTAssertEqual(VaultAuthoring.manualFileName(title: "Installation manual", extension: "pdf", taken: []),
                       "installation-manual.pdf")
        XCTAssertEqual(VaultAuthoring.manualFileName(title: "Installation manual", extension: "pdf",
                                                     taken: ["Installation-Manual.pdf"]), "installation-manual-2.pdf")
    }

    // MARK: - Keeping a fault code

    private var starterFaultCodes: String {
        get throws {
            try XCTUnwrap(AppStarter.make(name: "Fixture", template: .hvacR).files.first { $0.name == AppStarter.faultCodesFile })
                .contents
        }
    }

    func testAFaultCodeLandsUnderTheTableHeaderAndTheNextAfterIt() throws {
        let first = FaultRow(code: "E9", label: "Low suction pressure", page: Page(cited: "2"))
        let second = FaultRow(code: "F17", label: "Fan motor overload", page: Page(cited: "2"))
        var text = try starterFaultCodes
        text = DraftKeeper.keeping(.faultCode(first), citation: "installation-manual p. 2", in: text).text
        text = DraftKeeper.keeping(.faultCode(second), citation: "installation-manual p. 2", in: text).text
        let lines = text.components(separatedBy: "\n")
        let header = try XCTUnwrap(lines.firstIndex(of: "| Code | Meaning | Manual and page |"))
        XCTAssertEqual(lines[header + 2], "| E9 | Low suction pressure | installation-manual p. 2 |")
        XCTAssertEqual(lines[header + 3], "| F17 | Fan motor overload | installation-manual p. 2 |")
        XCTAssertTrue(text.hasPrefix("# Fault codes"), "The file's heading was disturbed")
    }

    func testAFileWithoutTheTableGetsOneAtItsEnd() {
        let row = FaultRow(code: "E9", label: "Low suction pressure", page: Page(cited: "2"))
        let result = DraftKeeper.keeping(.faultCode(row), citation: "manual p. 2", in: "# Codes\n\nNotes.")
        XCTAssertTrue(result.text.hasSuffix(AppStarter.faultCodeTableHeader + "\n| E9 | Low suction pressure | manual p. 2 |\n"),
                      result.text)
    }

    func testKeepingTheSameRowTwiceLeavesTheFileAsItWas() throws {
        let row = FaultRow(code: "E9", label: "Low suction pressure", page: Page(cited: "2"))
        let once = DraftKeeper.keeping(.faultCode(row), citation: "m p. 2", in: try starterFaultCodes).text
        XCTAssertEqual(DraftKeeper.keeping(.faultCode(row), citation: "m p. 2", in: once).text, once)
    }

    func testAPipeInALabelDoesNotBreakTheTable() {
        let row = FaultRow(code: "E9", label: "Low suction | pressure", page: Page(cited: "2"))
        XCTAssertEqual(DraftKeeper.keeping(.faultCode(row), citation: "m p. 2", in: "").line,
                       "| E9 | Low suction / pressure | m p. 2 |")
    }

    // MARK: - Keeping a model

    func testAModelJoinsItsSectionTakingTheManualAndTheSpellingsItLacks() throws {
        let models = try XCTUnwrap(AppStarter.make(name: "Fixture", template: .hvacR,
                                                   models: [.init("QX-100", aliases: ["QX100"]), .init("QX-200")])
            .files.first { $0.name == AppStarter.modelsFile }).contents
        let row = ModelRowT(model: "QX100", aliases: ["QX 100"])
        let text = DraftKeeper.keeping(.model(row), citation: "installation-manual p. 1", in: models).text
        XCTAssertTrue(text.contains("## QX-100 (QX100, QX 100)\nManuals: installation-manual p. 1."), text)
        XCTAssertTrue(text.contains("## QX-200\nManuals: none yet."), "Another model's section changed")
    }

    func testASecondManualIsAddedToTheModelsManualsLine() {
        let start = "# Models\n\n## QX-100\nManuals: installation-manual p. 1.\n"
        let text = DraftKeeper.keeping(.model(ModelRowT(model: "QX-100")), citation: "service-manual p. 4", in: start).text
        XCTAssertTrue(text.contains("Manuals: installation-manual p. 1; service-manual p. 4."), text)
    }

    func testANewModelGetsASectionTheModelIndexReads() {
        let text = DraftKeeper.keeping(.model(ModelRowT(model: "QX-300", aliases: ["QX300"])),
                                       citation: "installation-manual p. 1", in: "# Models\n").text
        XCTAssertTrue(text.contains("## QX-300 (QX300)\nManuals: installation-manual p. 1."), text)
        let index = VaultModelIndex(vaultName: "Fixture", files: [(filename: "models.md", contents: text)])
        XCTAssertEqual(index.models.first?.name, "QX-300")
        XCTAssertTrue(index.namesModel("QX300"))
    }

    // MARK: - Keeping a symptom

    func testASymptomBecomesTheFirstCheckUnderItsHeading() {
        let start = "# Symptoms\n\n## Not cooling\n\n## Noisy\n"
        let row = SymptomRowT(symptom: "Not cooling", cause: "Dirty outdoor coil", check: "Clean the coil", page: Page(cited: "3"))
        let text = DraftKeeper.keeping(.symptom(row), citation: "installation-manual p. 3", in: start).text
        XCTAssertEqual(text, "# Symptoms\n\n## Not cooling\n\n1. Clean the coil. Likely cause: Dirty outdoor coil. installation-manual p. 3.\n\n## Noisy\n")
    }

    func testASecondCheckIsNumberedAfterTheFirst() {
        let start = "## Not cooling\n\n1. Clean the coil. Likely cause: Dirty coil. m p. 3.\n"
        let row = SymptomRowT(symptom: "not cooling", cause: "Fan stopped", check: "Check the fan turns", page: Page(cited: "4"))
        let text = DraftKeeper.keeping(.symptom(row), citation: "m p. 4", in: start).text
        XCTAssertTrue(text.contains("1. Clean the coil. Likely cause: Dirty coil. m p. 3.\n2. Check the fan turns. Likely cause: Fan stopped. m p. 4."), text)
    }

    func testASymptomNoHeadingSaysGetsItsOwnSection() {
        let row = SymptomRowT(symptom: "Room stays warm", cause: "Dirty coil", check: "Clean the coil", page: Page(cited: "3"))
        let text = DraftKeeper.keeping(.symptom(row), citation: "m p. 3", in: "# Symptoms\n").text
        XCTAssertTrue(text.hasSuffix("## Room stays warm\n\n1. Clean the coil. Likely cause: Dirty coil. m p. 3.\n"), text)
    }

    func testEachLayerGoesToItsStarterFile() {
        XCTAssertEqual(DraftKeeper.file(for: .faultCodes, among: AppStarter.fileNames), "fault-codes.md")
        XCTAssertEqual(DraftKeeper.file(for: .modelMap, among: AppStarter.fileNames), "models.md")
        XCTAssertEqual(DraftKeeper.file(for: .symptoms, among: AppStarter.fileNames), "symptoms.md")
        XCTAssertNil(DraftKeeper.file(for: .symptoms, among: ["safety.md"]))
    }

    // MARK: - The publishing check

    private func record(copied: [VaultAuthoringRecord.CopiedLine] = [], last: VaultAuthoringRecord.LastCheck? = nil,
                        threshold: Double = 0.8) -> VaultAuthoringRecord {
        var record = VaultAuthoringRecord(template: "hvac_r")
        record.copiedLines = copied
        record.lastCheck = last
        record.threshold = threshold
        return record
    }

    func testAPrivateExportShowsNoWarnings() {
        let files = ["models.md": "## QX-100\nManuals: none yet."]
        XCTAssertEqual(PublishingCheck.warnings(files: files, record: record(last: .init(asked: 10, found: 1)),
                                                privateExport: true), [])
    }

    func testOnlyRowsStillInTheManualsWordsAreCounted() {
        let files = ["fault-codes.md": "| E9 | Low suction pressure in the suction line of the unit | m p. 2 |\n| F17 | Fan stuck, my words | m p. 2 |"]
        let copied = [VaultAuthoringRecord.CopiedLine(file: "fault-codes.md", line: "| E9 | Low suction pressure in the suction line of the unit | m p. 2 |"),
                      VaultAuthoringRecord.CopiedLine(file: "fault-codes.md", line: "| F17 | Outdoor fan motor overload as printed in the manual | m p. 2 |")]
        XCTAssertEqual(PublishingCheck.warnings(files: files, record: record(copied: copied), privateExport: false),
                       [.rowsInManualsWords(1)])
    }

    func testModelsWithNoManualAreNamed() {
        let models = "# Models\n\n## QX-100 (QX100)\nManuals: installation-manual p. 1.\n\n## QX-200\nManuals: none yet.\n\n## QX-300\n"
        XCTAssertEqual(PublishingCheck.modelsWithoutManual(models), ["QX-200", "QX-300"])
        XCTAssertEqual(PublishingCheck.warnings(files: ["models.md": models], record: nil, privateExport: false),
                       [.modelsWithoutManual(["QX-200", "QX-300"])])
    }

    func testAVaultCheckBelowTheAuthorsBarWarnsAndOneAtItDoesNot() {
        XCTAssertEqual(PublishingCheck.warnings(files: [:], record: record(last: .init(asked: 10, found: 7)), privateExport: false),
                       [.checkBelowThreshold(found: 7, asked: 10, threshold: 0.8)])
        XCTAssertEqual(PublishingCheck.warnings(files: [:], record: record(last: .init(asked: 10, found: 8)), privateExport: false), [])
        XCTAssertEqual(PublishingCheck.warnings(files: [:], record: record(), privateExport: false), [], "A check never run says nothing")
    }

    func testEveryWarningHasASentence() {
        for warning: PublishingCheck.Warning in [.rowsInManualsWords(1), .rowsInManualsWords(3), .modelsWithoutManual(["QX-200"]),
                                                  .checkBelowThreshold(found: 1, asked: 2, threshold: 0.8)] {
            XCTAssertFalse(PublishingCheck.message(warning).isEmpty)
        }
        XCTAssertTrue(PublishingCheck.message(.checkBelowThreshold(found: 7, asked: 10, threshold: 0.8)).contains("80%"))
    }

    // MARK: - The page text, as the live source assembles it

    func testThePageTextIsAssembledByPageWithRecognitionAndUnclearPages() {
        let noise = "xq zt rr pp kk vv ww nn mm bb cc dd ff gg hh jj ll"
        let text = LiveDraftPageText.assemble(pages: [(page: 1, text: "Cover"), (page: 2, text: "E9 Low suction pressure"),
                                                      (page: 2, text: "more on two"), (page: 3, text: noise)],
                                              labels: PageLabelMap([PageLabel(page: 2, label: "1", source: .printed)]),
                                              recognised: true, unclear: [1])
        XCTAssertEqual(text.pageNumbers, [1, 2, 3])
        XCTAssertEqual(text.text(onPage: 2), "E9 Low suction pressure\nmore on two")
        XCTAssertEqual(text.unclearPages, [1, 3])
        XCTAssertEqual(text.recognisedPages, [1, 2, 3])
        XCTAssertEqual(text.pages(printed: "1"), [2])
        XCTAssertTrue(LiveDraftPageText.assemble(pages: [(page: 1, text: "x")], labels: PageLabelMap([]), recognised: false)
            .recognisedPages.isEmpty)
    }

    // MARK: - The review rows

    private static let manual = LiveDraftPageText.assemble(pages: [
        (page: 1, text: "Installation manual\nRooftop unit QX-100\nThis manual covers the QX-100 and the QX-100A."),
        (page: 2, text: "Fault codes\nE9 Low suction pressure. Look for a restriction in the suction line, then confirm the charge.\nF17 Outdoor fan motor overload. Let the motor cool, then check the fan turns freely.")
    ], labels: PageLabelMap([PageLabel(page: 2, label: "41", source: .printed)]), recognised: false)

    private func pastedItems(_ text: String) -> (items: [DraftReviewItem], unparsed: [OpenGlasses.ParsedDraft.Unparsed]) {
        DraftReview.pasted(text, layer: .faultCodes, in: Self.manual)
    }

    func testAPastedReplyIsCheckedAndItsProseKept() {
        let read = pastedItems("Here are the codes:\nE9 | Low suction pressure | 41\nF17 | Fan motor overload | 5")
        XCTAssertEqual(read.items.count, 2)
        XCTAssertEqual(read.items[0].outcome.mark, .checked)
        XCTAssertEqual(read.items[0].keepPage, 2)
        XCTAssertEqual(read.items[1].outcome.mark, .foundOnAnotherPage(2))
        XCTAssertNil(read.items[1].keepPage, "A row on another page is kept only once the author takes that page")
        XCTAssertEqual(read.unparsed.map(\.text), ["Here are the codes:"])
    }

    func testTakingTheFoundPageMakesTheRowCheckedOnThatPage() {
        let item = pastedItems("F17 | Fan motor overload | 5").items[0]
        let taken = DraftReview.takingFoundPage(item, in: Self.manual)
        XCTAssertEqual(taken.outcome.mark, .checked)
        XCTAssertEqual(taken.keepPage, 2)
        guard case .faultCode(let row) = taken.row else { return XCTFail("Not a fault code") }
        XCTAssertEqual(row.page, Page(cited: "41", physical: 2), "The page is cited as printed")
    }

    func testEditingARowClearsTheManualsWords() {
        let proposed = DraftReview.items([(row: Row.faultCode(FaultRow(code: "E9", label: "Low suction pressure. Look for a restriction",
                                                                      page: Page(cited: "41", physical: 2))), copied: true)],
                                         origin: .proposal, in: Self.manual)[0]
        XCTAssertTrue(proposed.inManualsWords)
        let edited = DraftReview.editing(proposed, to: .faultCode(FaultRow(code: "E9", label: "Suction low", page: Page(cited: "41"))),
                                         in: Self.manual)
        XCTAssertFalse(edited.copiedFromManual)
        XCTAssertFalse(edited.inManualsWords)
        XCTAssertEqual(edited.outcome.mark, .checked)
    }

    func testKeepAllCheckedKeepsOnlyOpenCheckedRows() {
        var items = pastedItems("E9 | Low suction pressure | 41\nF17 | Fan motor overload | 5\nZ99 | Not a code here | 2").items
        XCTAssertEqual(DraftReview.keepAllChecked(items), [items[0].id])
        items[0].state = .kept
        XCTAssertEqual(DraftReview.keepAllChecked(items), [], "A kept row is not kept twice")
        XCTAssertEqual(items[2].outcome.mark, .notFound)
        XCTAssertNil(items[2].keepPage)
    }

    func testPagesAreSaidPrintedBesideThePDFPage() {
        XCTAssertEqual(DraftReview.pageText(2, labels: Self.manual.labels), "page 2 (printed 41)")
        XCTAssertEqual(DraftReview.pageText(1, labels: Self.manual.labels), "page 1")
        XCTAssertEqual(DraftReview.pageList([44, 41, 42, 43]), "41–44")
        XCTAssertEqual(DraftReview.pageList([43, 41]), "41, 43")
    }

    func testTheMarkSaysThePageAndWhatToDo() {
        let read = pastedItems("E9 | Low suction pressure | 41\nF17 | Fan motor overload | 5").items
        XCTAssertEqual(DraftRowText.mark(read[0].outcome, labels: Self.manual.labels), "Checked · page 2 (printed 41)")
        XCTAssertTrue(DraftRowText.mark(read[1].outcome, labels: Self.manual.labels).hasPrefix("Found on page 2"))
        XCTAssertEqual(DraftRowText.identifier(read[1].row), "f17")
    }

    func testTheProposalsReadTheManualsCoverForModels() {
        let proposals = DraftReview.proposals(text: Self.manual, tables: [], template: .hvacR)
        guard case .model(let model)? = proposals.models.first?.row else { return XCTFail("No model proposed") }
        XCTAssertEqual(model.model, "QX-100")
        XCTAssertTrue(proposals.faultCodes.rows.isEmpty, "No table, no fault-code proposal")
    }

    // MARK: - The vault check

    func testAPassageIsReadAsItsManualsKeyAndEveryPageItCovers() {
        var passage = VaultRetriever.Passage(documentId: "doc-1", documentName: "Installation manual", chunkIndex: 0,
                                             text: "x", page: 41, section: nil, similarity: 0.5, score: 0.5, matchedTokens: [])
        passage.pageBreaks = [DocumentChunker.PageBreak(offset: 10, page: 42)]
        let learning = VaultRetriever.Passage(documentId: "learning-1", documentName: "Team learning", chunkIndex: 0,
                                              text: "y", page: nil, section: nil, similarity: 0.4, score: 0.4, matchedTokens: [])
        let read = VaultCheckRunner.retrieved([passage, learning], keyForDocument: { $0 == "doc-1" ? "installation-manual" : nil })
        XCTAssertEqual(read, [VaultCheck.Retrieved(key: "installation-manual", pages: [41, 42]),
                              VaultCheck.Retrieved(key: "Team learning", pages: [])])
    }

    func testTheQuestionsAreTheStartersWithTheirPagesThenTheAuthorsOwn() {
        var record = VaultAuthoringRecord(template: "hvac_r")
        let first = AppTemplate.hvacR.checkQuestions[0].text
        record.starterAnswers[first] = .init(key: "installation-manual", page: 2)
        record.questions = [.init(text: "Where is the fan fuse?", key: "installation-manual", page: 9)]
        let questions = VaultCheckRunner.questions(template: .hvacR, record: record)
        XCTAssertEqual(questions.count, AppTemplate.hvacR.checkQuestions.count + 1)
        XCTAssertEqual(questions[0].expected, [VaultCheck.PageRef(key: "installation-manual", page: 2)])
        XCTAssertEqual(questions[1].expected, [], "A starter without a page is listed, not scored")
        XCTAssertEqual(questions.last?.text, "Where is the fan fuse?")
        let score = VaultCheck.score(questions, retrieved: questions.map { _ in [VaultCheck.Retrieved(key: "installation-manual", pages: [2])] })
        XCTAssertEqual(score.asked, 2)
        XCTAssertEqual(score.found, 1)
    }

    func testTheKeysOfTheVaultsManualsAreFoundByTheirDocumentIds() {
        let manifest = VaultManifest(id: "v", name: "V", version: "1", files: [],
                                     documents: [VaultDocument(file: "installation-manual.pdf", title: "Installation manual")])
        var ledger = VaultDocumentLedger()
        ledger.entries = [.init(file: "installation-manual.pdf", title: "Installation manual", documentId: "doc-7",
                                contentHash: "h", chunkCount: 3)]
        XCTAssertEqual(VaultCheckRunner.keysByDocumentId(manifest: manifest, ledger: ledger), ["doc-7": "installation-manual"])
    }

    // MARK: - The nameplate

    func testANameplatesModelComesBeforeItsOtherTokens() {
        let tokens = NameplateModelRead.tokens(fromOCRText: "MODEL QX-100A SERIAL 2291 VOLTS 230", template: .hvacR)
        XCTAssertEqual(tokens.first, "QX-100A")
    }

    // MARK: - The card

    func testTheMoveCardIsOfferedOnceWithManualsAndOwnVaults() {
        XCTAssertTrue(MyManualsMove.shouldOffer(hasOwnVaults: true, personalManuals: 2, answered: false))
        XCTAssertFalse(MyManualsMove.shouldOffer(hasOwnVaults: false, personalManuals: 2, answered: false))
        XCTAssertFalse(MyManualsMove.shouldOffer(hasOwnVaults: true, personalManuals: 0, answered: false))
        XCTAssertFalse(MyManualsMove.shouldOffer(hasOwnVaults: true, personalManuals: 2, answered: true))
    }
}
