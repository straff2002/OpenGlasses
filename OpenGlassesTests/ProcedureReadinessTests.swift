import XCTest
@testable import OpenGlasses

/// Plan MN P0 §6: "runs on this phone with no assistant", as a fact about a procedure.
final class ProcedureReadinessTests: XCTestCase {

    private typealias F = ProcedureAnswerFixtures

    func testTheExampleRunsWithoutAModel() throws {
        XCTAssertEqual(ProcedureReadiness.of(try F.exampleProcedure()), .runsWithoutModel)
        XCTAssertEqual(ProcedureReadiness.of(F.phProcedure()), .runsWithoutModel)
    }

    func testAStepChoosingFromWordsNeedsAModel() throws {
        let url = F.repoRoot.appendingPathComponent("OpenGlasses/Sources/Resources/Vaults/refrigeration/procedures/low_pressure_diagnostic.json")
        let bundled = try JSONDecoder().decode(Procedure.self, from: Data(contentsOf: url))
        guard case .needsModel(let reasons) = ProcedureReadiness.of(bundled) else {
            return XCTFail("a bundled diagnostic chooses its routes from words")
        }
        XCTAssertFalse(reasons.isEmpty)
        let first = try XCTUnwrap(ProcedureReadiness.blockers(bundled).first)
        XCTAssertEqual(reasons[first.stepId], first.reason)
    }

    func testOneWayOnAndPlainLinearStepsAreFine() {
        let procedure = Procedure(id: "p", title: "P", version: "1", steps: [
            .init(id: "a", title: "A", instruction: "Do it.", branches: [.init(id: "only", condition: "always", next: "b")]),
            .init(id: "b", title: "B", instruction: "Then this.", defaultNext: "c"),
            .init(id: "c", title: "C", instruction: "Done.", terminal: true),
        ])
        XCTAssertEqual(ProcedureReadiness.of(procedure), .runsWithoutModel)
    }

    func testAnObservationAskedInWordsWithNoTypedAnswerNeedsAModel() {
        let procedure = Procedure(id: "p", title: "Line changeover", version: "1", steps: [
            .init(id: "a", title: "A", instruction: "Do it.", defaultNext: "b"),
            .init(id: "b", title: "B", instruction: "Look at it.", expectedInput: "what you see", defaultNext: "c"),
            .init(id: "c", title: "C", instruction: "Done.", terminal: true),
        ])
        XCTAssertEqual(ProcedureReadiness.of(procedure), .needsModel(["b": ProcedureReadiness.asksInWords]))
        XCTAssertEqual(ProcedureReadiness.blockers(procedure).first?.stepNumber, 2)
    }

    func testTheImportSummaryCountsAndNamesTheStepThatStopsEach() {
        let words = Procedure(id: "w", title: "Line changeover", version: "1", steps: [
            .init(id: "a", title: "A", instruction: "Go.", defaultNext: "b"),
            .init(id: "b", title: "B", instruction: "Go.", defaultNext: "c"),
            .init(id: "c", title: "C", instruction: "Go.", defaultNext: "d"),
            .init(id: "d", title: "D", instruction: "Look.", branches: [
                .init(id: "x", condition: "looks clean", next: "e"), .init(id: "y", condition: "looks dirty", next: "e")]),
            .init(id: "e", title: "E", instruction: "Done.", terminal: true),
        ])
        XCTAssertEqual(ProcedureReadiness.importSummary([F.phProcedure(), F.phProcedure(), words]),
                       "3 procedures, 2 run with no assistant; Line changeover step 4 chooses its route from words")
        XCTAssertEqual(ProcedureReadiness.importSummary([F.phProcedure()]), "1 procedure, 1 runs with no assistant")
        XCTAssertEqual(ProcedureReadiness.importSummary([words]),
                       "1 procedure, none run with no assistant; Line changeover step 4 chooses its route from words")
        XCTAssertNil(ProcedureReadiness.importSummary([]))
    }

    /// The screens show `localized`, the tests and `of(_:)` read `english`; in English they are
    /// the same words, so a reworded reason can't drift between the two.
    func testEachReasonShowsTheSameWordsInEnglish() {
        for reason in [ProcedureReadiness.Reason.choosesFromWords, .asksInWords, .unknownAnswerKind] {
            XCTAssertEqual(reason.localized, reason.english)
        }
        XCTAssertEqual(ProcedureReadiness.choosesFromWords, "chooses its route from words")
    }

    func testTheImportSummaryNamesNoMoreThanThreeAndCountsTheRest() {
        let words = Procedure(id: "w", title: "Words", version: "1", steps: [
            .init(id: "a", title: "A", instruction: "Look.", branches: [
                .init(id: "x", condition: "looks clean", next: "b"), .init(id: "y", condition: "looks dirty", next: "b")]),
            .init(id: "b", title: "B", instruction: "Done.", terminal: true),
        ])
        XCTAssertEqual(ProcedureReadiness.importSummary(Array(repeating: words, count: 5)),
                       "5 procedures, none run with no assistant; Words step 1 chooses its route from words; "
                       + "Words step 1 chooses its route from words; Words step 1 chooses its route from words; and 2 more")
    }
}
