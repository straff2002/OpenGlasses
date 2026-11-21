import XCTest
@testable import OpenGlasses

/// Plan MQ P0: the Field Assist tools a downloaded model is offered per turn, and the keyword hints
/// that order them.
final class FieldAssistLocalToolSetTests: XCTestCase {

    private let everything = FieldAssistLocalToolSet.priority + ["deliver_report", "web_search", "get_weather",
                                                                 "manual_lookup", "rule_chain"]

    private func select(_ utterance: String, registered: [String]? = nil, active: Bool = true,
                        qualified: Bool = true, tokens: @escaping (String) -> Int = { _ in 120 },
                        budget: Int = 10_000) -> [String] {
        FieldAssistLocalToolSet.select(registered: registered ?? everything, fieldAssistActive: active,
                                       modelQualified: qualified, utterance: utterance,
                                       estimatedTokens: tokens, budgetTokens: budget)
    }

    func testThePriorityListIsThePlansAndEveryToolOnItWorksOffline() {
        XCTAssertEqual(FieldAssistLocalToolSet.priority, [
            "field_session", "reading", "evidence", "equipment_lookup", "domain_calc",
            "procedure_runner", "table_lookup", "show_source",
        ])
        for name in FieldAssistLocalToolSet.priority {
            XCTAssertTrue(OfflineToolPolicy.isOfferedOffline(name), name)
        }
        XCTAssertFalse(FieldAssistLocalToolSet.priority.contains("manual_lookup"),
                       "manual questions take Plan MP's read-then-check path, not a tool")
    }

    func testNothingUnlessFieldAssistIsOnAndTheModelIsQualified() {
        XCTAssertEqual(select("open a new job", active: false), [])
        XCTAssertEqual(select("open a new job", qualified: false), [], "decision 6: an unbadged model gets none")
        XCTAssertFalse(select("open a new job").isEmpty)
    }

    func testAtMostFivePerTurn() {
        XCTAssertEqual(FieldAssistLocalToolSet.perTurnLimit, 5, "decision 3")
        XCTAssertEqual(select("hello").count, 5)
        XCTAssertEqual(select("hello"), Array(FieldAssistLocalToolSet.priority.prefix(5)))
    }

    func testTheTurnsWordsComeFirst() {
        let chosen = select("show me the page with that clearance table")
        XCTAssertEqual(Array(chosen.prefix(2)), ["show_source", "table_lookup"])
        XCTAssertEqual(chosen.count, 5)
        XCTAssertTrue(chosen.contains("field_session"), "the rest keep priority order")
    }

    func testACalculationThatNamesAValueLeadsWithTheCalculator() {
        XCTAssertEqual(select("work out the superheat from 118 psi").first, "domain_calc")
    }

    func testNetworkAndUnregisteredToolsAreNeverOffered() {
        let chosen = select("deliver the report", registered: ["field_session", "deliver_report", "reading"])
        XCTAssertEqual(chosen, ["field_session", "reading"])
        XCTAssertFalse(select("search the web").contains("web_search"))
    }

    func testTheModelsBudgetCutsDefinitionsThatDoNotFitButKeepsSmallerOnes() {
        let sizes = ["field_session": 500, "reading": 200, "evidence": 400, "equipment_lookup": 100,
                     "domain_calc": 300]
        let chosen = select("hello", tokens: { sizes[$0] ?? 100 }, budget: 800)
        XCTAssertEqual(chosen, ["field_session", "reading", "equipment_lookup"])
    }

    func testTheDefinitionBudgetIsAQuarterOfThePromptBudget() {
        let id = "mlx-community/gemma-4-e2b-it-4bit"
        XCTAssertEqual(LocalModelBudget.toolDefinitionBudget(for: id), LocalModelBudget.promptBudget(for: id) / 4)
        XCTAssertEqual(LocalModelBudget.toolDefinitionBudget(for: id), 864)
    }

    // MARK: - Keyword hints

    func testHintsMatchWholeWordsOnly() {
        XCTAssertFalse(OfflineKeywordRouter.fieldToolHints("the community centre").contains("equipment_lookup"))
        XCTAssertTrue(OfflineKeywordRouter.fieldToolHints("which unit is this").contains("equipment_lookup"))
    }

    func testHintsNameEachToolOnceInRankOrder() {
        let hints = OfflineKeywordRouter.fieldToolHints("take a photo of the reading then calculate superheat")
        XCTAssertEqual(hints, ["domain_calc", "evidence", "reading"])
        XCTAssertEqual(Set(hints).count, hints.count)
    }

    func testEveryHintedToolIsOnThePriorityList() {
        for utterance in ["start a job", "next step", "log 118 psi", "show me where it says that",
                          "what size breaker", "serial number", "attach a picture", "calculate subcooling"] {
            for tool in OfflineKeywordRouter.fieldToolHints(utterance) {
                XCTAssertTrue(FieldAssistLocalToolSet.priority.contains(tool), "\(utterance) → \(tool)")
            }
        }
    }

    func testSmallTalkHintsNothing() {
        XCTAssertEqual(OfflineKeywordRouter.fieldToolHints("good morning, how are you"), [])
        XCTAssertEqual(OfflineKeywordRouter.fieldToolHints(""), [])
    }
}
