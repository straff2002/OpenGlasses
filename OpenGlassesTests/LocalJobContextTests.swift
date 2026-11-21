import XCTest
@testable import OpenGlasses

/// Plan MQ P1: the compact `<field_assist_context>` tier for a downloaded model. Pure.
final class LocalJobContextTests: XCTestCase {

    private func inputs(readings: [String] = ["line pressure 7.0 inWC", "manifold pressure, low fire 0.6 inWC",
                                              "manifold pressure, high fire 3.5 inWC", "flame signal 2.9 µA",
                                              "supply air 128 °F"],
                        procedure: String? = "ACTIVE PROCEDURE — No ignition (step 2, step id: s2):\nStep: Check the ignitor\nInstruction to give the technician: Measure the ignitor resistance with power off.",
                        fieldTools: Bool = true) -> LocalJobContext.Inputs {
        LocalJobContext.Inputs(
            vaultName: "Lennox SLP99 Furnace Service",
            rules: ["Never fabricate equipment data.", "Cite the source file or manual page on every factual claim."],
            summary: .init(reference: "1005", unit: "SLP99UH090XV60CK", openTasks: ["No heat (in progress)"],
                           lastReading: "flame signal 2.9 µA", questions: [], paused: false),
            equipment: "ACTIVE EQUIPMENT: SLP99UH090XV60CK — \"SLP99UH090XV60CK\" (said, 9:14). Answer for this model.",
            readings: readings,
            procedure: procedure,
            ruleChain: nil,
            fieldToolsOffered: fieldTools,
            modelSettingsPath: "Settings > Assistant")
    }

    func testUnfittedCarriesTheJobTheRulesTheLatestReadingsAndTheStep() {
        let text = LocalJobContext.render(inputs(), budgetTokens: .max)
        XCTAssertTrue(text.contains("Lennox SLP99 Furnace Service"))
        XCTAssertTrue(text.contains("- Never fabricate equipment data."))
        XCTAssertTrue(text.contains("Job: 1005. Unit: SLP99UH090XV60CK."))
        XCTAssertTrue(text.contains("ACTIVE EQUIPMENT: SLP99UH090XV60CK"))
        XCTAssertTrue(text.contains("Instruction to give the technician: Measure the ignitor resistance"))
        // The four newest, oldest first; the fifth-newest is gone.
        XCTAssertFalse(text.contains("line pressure 7.0 inWC"))
        XCTAssertTrue(text.contains("manifold pressure, low fire 0.6 inWC; manifold pressure, high fire 3.5 inWC; flame signal 2.9 µA; supply air 128 °F"))
        // The summary's own last-reading line is not repeated.
        XCTAssertFalse(text.contains("Last reading:"))
    }

    func testTheManualsLineNamesTheToolsOnlyWhenTheTurnOffersThem() {
        let withTools = LocalJobContext.render(inputs(fieldTools: true), budgetTokens: .max)
        XCTAssertTrue(withTools.contains("table_lookup"))
        XCTAssertTrue(withTools.contains("equipment_lookup"))
        let without = LocalJobContext.render(inputs(fieldTools: false), budgetTokens: .max)
        XCTAssertFalse(without.contains("table_lookup"))
        XCTAssertTrue(without.contains(AppleOnDeviceInstructions.manualsNote(settingsPath: "Settings > Assistant")))
        XCTAssertTrue(without.contains("safety notes"))
    }

    func testAShortBudgetDropsOldReadingsFirstThenTheNameplateThenCondensesTheStep() {
        let full = LocalJobContext.render(inputs(), budgetTokens: .max)
        let fullTokens = LocalJobContext.estimatedTokens(full)

        let lessReadings = LocalJobContext.render(inputs(), budgetTokens: fullTokens - 5)
        XCTAssertLessThanOrEqual(LocalJobContext.estimatedTokens(lessReadings), fullTokens - 5)
        XCTAssertFalse(lessReadings.contains("manifold pressure, low fire 0.6 inWC"), "the oldest reading goes first")
        XCTAssertTrue(lessReadings.contains("supply air 128 °F"), "the newest stays")
        XCTAssertTrue(lessReadings.contains("ACTIVE EQUIPMENT"))

        let noReadings = LocalJobContext.render(inputs(readings: []), budgetTokens: .max)
        let tight = LocalJobContext.render(inputs(), budgetTokens: LocalJobContext.estimatedTokens(noReadings) - 10)
        XCTAssertFalse(tight.contains("Readings on this unit"))
        XCTAssertFalse(tight.contains("ACTIVE EQUIPMENT"), "the nameplate line goes after the readings")
        XCTAssertTrue(tight.contains("Step: Check the ignitor"), "the step stays")

        // Rules, job and manuals line are never cut, whatever the budget.
        let starved = LocalJobContext.render(inputs(), budgetTokens: 10)
        XCTAssertTrue(starved.contains("- Never fabricate equipment data."))
        XCTAssertTrue(starved.contains("Job: 1005"))
        XCTAssertTrue(starved.contains("MANUALS:"))
    }

    func testTheBudgetIsAQuarterOfEachModelsPromptBudget() {
        for entry in LocalModelCatalog.entries {
            let id = entry.id.rawValue
            XCTAssertEqual(LocalModelBudget.jobContextBudget(for: id), LocalModelBudget.promptBudget(for: id) / 4)
        }
        XCTAssertEqual(LocalModelBudget.jobContextBudget(for: "mlx-community/gemma-4-e2b-it-4bit"), 864)
    }
}
