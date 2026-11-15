import XCTest
@testable import OpenGlasses

private typealias Template = OpenGlasses.TradeTemplate
private typealias FaultRow = OpenGlasses.FaultCodeRow
private typealias ModelRowT = OpenGlasses.ModelRow
private typealias SymptomRowT = OpenGlasses.SymptomRow
private typealias Page = OpenGlasses.DraftPage
private typealias Writer = OpenGlasses.IndexRowWriter

/// Plan LW §4 — what the phone proposes from a manual it has indexed, over fixture tables and pages.
/// Every code, model and sentence is invented.
final class DraftProposalsTests: XCTestCase {

    private func cell(_ text: String) -> ManualTable.Cell { ManualTable.Cell(text: text) }

    private func faultTable(page: Int = 41, printed: String? = "39") -> ManualTable {
        let at = ManualTable.Page(physical: page, printed: printed)
        return ManualTable(label: "Table 4", title: "Fault codes", page: at, rowHeaders: ["Code"],
                           columns: [.init(path: ["Meaning"]), .init(path: ["What to do"])],
                           rows: [.init(path: ["E9"], cells: [cell("Low refrigerant  charge"), cell("Look at the pressures")], page: at),
                                  .init(path: ["F17"], cells: [cell("Outdoor fan not turning"), cell("Test the fan motor")], page: at),
                                  .init(path: ["E-12"], cells: [cell(""), cell("Sensor open circuit")], page: at),
                                  .init(path: ["Note"], cells: [cell("Codes flash twice"), cell("")], page: at)])
    }

    // MARK: - Fault codes

    func testAFaultCodeTableBecomesRowsInTheManualsWords() {
        let result = FaultCodeProposals.propose(tables: [faultTable()], template: .hvacR)
        XCTAssertEqual(result.tableCount, 1)
        XCTAssertEqual(result.pages, [41])
        XCTAssertEqual(result.rows.map(\.row), [
            .faultCode(FaultRow(code: "E9", label: "Low refrigerant charge", page: Page(cited: "39", physical: 41))),
            .faultCode(FaultRow(code: "F17", label: "Outdoor fan not turning", page: Page(cited: "39", physical: 41))),
            .faultCode(FaultRow(code: "E-12", label: "Sensor open circuit", page: Page(cited: "39", physical: 41)))
        ], "an empty meaning takes the next column; a row that is not a code is left out")
        XCTAssertTrue(result.rows.allSatisfy(\.copiedFromManual))
    }

    func testCodesInTheFirstColumnOfATableWithNoRowHeadings() {
        let at = ManualTable.Page(physical: 12)
        let table = ManualTable(label: "Table 1", title: "Display codes", page: at,
                                columns: [.init(path: ["Code"]), .init(path: ["Meaning"])],
                                rows: [.init(path: [], cells: [cell("A1"), cell("Door open")], page: at),
                                       .init(path: [], cells: [cell("A2"), cell("Water low")], page: at)])
        let rows = FaultCodeProposals.propose(tables: [table], template: .general).rows.map(\.row)
        XCTAssertEqual(rows, [.faultCode(FaultRow(code: "A1", label: "Door open", page: Page(cited: "12", physical: 12))),
                              .faultCode(FaultRow(code: "A2", label: "Water low", page: Page(cited: "12", physical: 12)))])
    }

    func testATableThatIsNotOfCodesProposesNothing() {
        let at = ManualTable.Page(physical: 70)
        let specs = ManualTable(label: "Table 9", title: "Specifications", page: at, rowHeaders: ["Item"],
                                columns: [.init(path: ["QX-100"])],
                                rows: [.init(path: ["Charge"], cells: [cell("2.1 kg")], page: at),
                                       .init(path: ["Weight"], cells: [cell("48 kg")], page: at),
                                       .init(path: ["F17"], cells: [cell("odd row")], page: at)])
        XCTAssertEqual(FaultCodeProposals.propose(tables: [specs], template: .hvacR),
                       .init(rows: [], tableCount: 0, pages: []))
    }

    func testACodeIsProposedOnceAndUnreadableTablesAndRowsAreSkipped() {
        var uncertain = faultTable(page: 43, printed: nil)
        uncertain.rows[0].keyUncertain = true
        var failed = faultTable(page: 44)
        failed.failure = .tooFewRows
        let result = FaultCodeProposals.propose(tables: [faultTable(), uncertain, failed], template: .hvacR)
        XCTAssertEqual(result.rows.count, 3, "the second table repeats the first's codes")
        XCTAssertEqual(result.tableCount, 1)
    }

    func testAProposedRowPassesTheCheckAndStaysInTheManualsWords() {
        let manual = ManualPageText(texts: [41: "Fault codes\nE9 Low refrigerant charge\nF17 Outdoor fan not turning\nE-12 Sensor open circuit"])
        for proposal in FaultCodeProposals.propose(tables: [faultTable()], template: .hvacR).rows {
            let outcome = DraftRowCheck.check(proposal.row, copiedFromManual: proposal.copiedFromManual, in: manual)
            XCTAssertEqual(outcome.mark, .checked)
            XCTAssertTrue(outcome.inManualsWords)
        }
    }

    // MARK: - Models

    func testModelsFromTheCoverAndTheSpecificationTablesGroupedBySpelling() {
        let pages: [(page: Int, text: String)] = [
            (1, "Installation manual SM-500210\nQX-100 and QX-100A outdoor units"),
            (2, "Fault E9 and F17 are listed later."),
            (50, "The QX-900 is a different product.")
        ]
        let at = ManualTable.Page(physical: 70, printed: "68")
        let specs = ManualTable(label: "Table 9", title: "Model specifications", page: at, rowHeaders: ["Model"],
                                columns: [.init(path: ["Charge"])],
                                rows: [.init(path: ["QX100"], cells: [cell("2.1 kg")], page: at),
                                       .init(path: ["QX-300"], cells: [cell("2.6 kg")], page: at)])
        let rows = ModelMapProposals.propose(pages: pages, tables: [specs], template: .hvacR)
        XCTAssertEqual(rows.map(\.row), [
            .model(ModelRowT(model: "QX-100", aliases: ["QX100"], page: Page(cited: "1", physical: 1))),
            .model(ModelRowT(model: "QX-100A", aliases: [], page: Page(cited: "1", physical: 1))),
            .model(ModelRowT(model: "QX-300", aliases: [], page: Page(cited: "68", physical: 70)))
        ], "no document number, no fault code, nothing past the cover outside a specification table")
        XCTAssertFalse(rows.contains(where: \.copiedFromManual), "a model number is not wording")
    }

    func testProposedModelsWrittenOutAreReadByTheModelIndex() {
        let rows = ModelMapProposals.propose(pages: [(1, "QX-100 and QX100 and QX-100A")], tables: [], template: .hvacR)
        let sections = rows.compactMap { proposal -> String? in
            guard case .model(let model) = proposal.row else { return nil }
            return Writer.modelSection(model, citations: [Writer.citation(key: "installation-manual", page: 1)])
        }
        let index = VaultModelIndex(vaultName: "Units", files: [("models.md", "# Models\n\n" + sections.joined(separator: "\n\n"))])
        XCTAssertEqual(index.models.map(\.name), ["QX-100", "QX-100A"])
        XCTAssertEqual(index.resolve(token: "QX100").map(\.name), ["QX-100"])
    }

    // MARK: - Symptoms

    func testATroubleshootingTableBecomesDraftSymptoms() {
        let at = ManualTable.Page(physical: 58, printed: "56")
        let table = ManualTable(label: "Table 12", title: "Troubleshooting", page: at, rowHeaders: ["Symptom"],
                                columns: [.init(path: ["Possible cause"]), .init(path: ["Check"])],
                                rows: [.init(path: ["Room stays warm"], cells: [cell("Dirty outdoor coil"), cell("Clean the coil")], page: at),
                                       .init(path: [""], cells: [cell("Fan not turning"), cell("Test the fan motor")], page: at),
                                       .init(path: ["Ice on the coil"], cells: [cell("Low airflow"), cell("")], page: at),
                                       .init(path: ["Noisy"], cells: [cell(""), cell("")], page: at)])
        let rows = SymptomProposals.propose(tables: [table]).map(\.row)
        XCTAssertEqual(rows, [
            .symptom(SymptomRowT(symptom: "Room stays warm", cause: "Dirty outdoor coil", check: "Clean the coil", page: Page(cited: "56", physical: 58))),
            .symptom(SymptomRowT(symptom: "Room stays warm", cause: "Fan not turning", check: "Test the fan motor", page: Page(cited: "56", physical: 58))),
            .symptom(SymptomRowT(symptom: "Ice on the coil", cause: "Low airflow", check: "", page: Page(cited: "56", physical: 58)))
        ], "a symptom printed once covers the rows under it; a row with nothing to check is left out")
    }

    func testAGroupHeadingIsTheSymptom() {
        let at = ManualTable.Page(physical: 59)
        let table = ManualTable(label: "Table 13", title: "Fault finding", page: at, rowHeaders: ["Problem"],
                                columns: [.init(path: ["Cause"]), .init(path: ["Remedy"])],
                                rows: [.init(path: ["Will not start", ""], cells: [cell("No supply"), cell("Reset the breaker")], page: at)])
        XCTAssertEqual(SymptomProposals.propose(tables: [table]).first?.row,
                       .symptom(SymptomRowT(symptom: "Will not start", cause: "No supply", check: "Reset the breaker",
                                            page: Page(cited: "59", physical: 59))))
    }

    func testLabelledBlocksOnAPageBecomeDraftSymptoms() {
        let text = """
        Troubleshooting
        Problem: Water on the floor
        Possible cause: Blocked drain
        Check: Clear the drain line
        Problem: Noisy fan
        Remedy: Tighten the fan guard
        Note: keep this page.
        """
        let rows = SymptomProposals.propose(tables: [], pages: [(62, text)]).map(\.row)
        XCTAssertEqual(rows, [
            .symptom(SymptomRowT(symptom: "Water on the floor", cause: "Blocked drain", check: "Clear the drain line", page: Page(cited: "62", physical: 62))),
            .symptom(SymptomRowT(symptom: "Noisy fan", cause: "", check: "Tighten the fan guard", page: Page(cited: "62", physical: 62)))
        ])
    }

    func testATableThatIsNotTroubleshootingProposesNoSymptoms() {
        XCTAssertTrue(SymptomProposals.propose(tables: [faultTable()]).isEmpty)
    }
}
