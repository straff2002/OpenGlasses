import XCTest
@testable import OpenGlasses

/// Plan JI §7a (P6b): a step's hint is what its author wrote, in a fixed order, and nothing else.
@MainActor
final class TalkThroughHintTests: XCTestCase {

    private func step(safety: String? = nil, expect: String? = nil, calcHint: String? = nil,
                      calc: Bool = false) -> Procedure.Step {
        Procedure.Step(id: "s", title: "Prime the pump", instruction: "Fill the priming chamber.",
                       expectedInput: expect, safetyNote: safety,
                       calcRef: calc ? Procedure.CalcRef(tool: "domain_calc", op: "flow_rate", hint: calcHint) : nil)
    }

    func testTheAuthoredOrderIsSafetyThenExpectThenTheCalculation() throws {
        let hint = try XCTUnwrap(TalkThroughHint.make(for: step(
            safety: "Unplug the lead first.", expect: "a steady stream", calcHint: "Flow is volume over time.", calc: true)))
        XCTAssertEqual(hint.items, [.safety("Unplug the lead first."), .expect("a steady stream"),
                                    .calculation("Flow is volume over time.")])
        XCTAssertEqual(hint.phoneLines, ["Safety: Unplug the lead first.", "Expect: a steady stream",
                                         "Calculation: Flow is volume over time."])
    }

    func testOnlyWhatTheStepCarries() throws {
        let hint = try XCTUnwrap(TalkThroughHint.make(for: step(expect: "a steady stream")))
        XCTAssertEqual(hint.items, [.expect("a steady stream")])
    }

    func testAResolvedCalculationTakesThePlaceOfTheAuthorsWords() throws {
        let hint = try XCTUnwrap(TalkThroughHint.make(for: step(calcHint: "Flow is volume over time.", calc: true),
                                                      calculationResult: "12 litres a minute"))
        XCTAssertEqual(hint.items, [.calculation("12 litres a minute")])
    }

    func testAStepWithNothingAuthoredGetsNoHint() {
        XCTAssertNil(TalkThroughHint.make(for: step()))
        XCTAssertNil(TalkThroughHint.make(for: step(safety: "  ", expect: "")))
        XCTAssertNil(TalkThroughHint.make(for: step(calc: true)), "a calculation with no words of its author's is nothing to show")
    }

    func testTheEarSaysTheFirstItemInAFewWords() throws {
        let hint = try XCTUnwrap(TalkThroughHint.make(for: step(
            safety: "Unplug the lead before you open the housing or touch the impeller.", expect: "a steady stream")))
        XCTAssertLessThanOrEqual(hint.spoken.split(separator: " ").count, HintLimits.spokenHintMaxWords)
        XCTAssertTrue(hint.spoken.hasPrefix("Unplug the lead"))
        let expectOnly = try XCTUnwrap(TalkThroughHint.make(for: step(expect: "a steady stream")))
        XCTAssertEqual(expectOnly.spoken, "Expect a steady stream")
    }

    func testTheLensIsTwoLinesUnderTheStepsTitle() throws {
        let hint = try XCTUnwrap(TalkThroughHint.make(for: step(
            safety: "Unplug the lead before you open the housing.",
            expect: "a steady stream from the outlet with no air in it for a full minute")))
        XCTAssertEqual(hint.lensTitle, "Prime the pump")
        XCTAssertLessThanOrEqual(hint.lensBody.count, HintLimits.passageCardMaxCharacters + 1)
        XCTAssertTrue(hint.lensBody.hasPrefix("Safety: Unplug the lead"))
        XCTAssertTrue(hint.lensBody.hasSuffix("…"), "a cut line says it was cut")
    }

    func testTheSafetyNoteIsKeptWholeForACaughtPhrase() throws {
        let note = "Unplug the lead before you open the housing or touch the impeller."
        XCTAssertEqual(TalkThroughHint.make(for: step(safety: note))?.safetyNote, note)
    }

    // MARK: - No model writes a hint

    func testTheHintTypesNameNoModel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/TalkThrough")
        for name in ["TalkThroughHint.swift", "TalkThroughLocator.swift"] {
            let code = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            for forbidden in ["HintModel", "LLMService", "complete(system", "completeStateless", "LocalLLM", "FoundationModels"] {
                XCTAssertFalse(code.contains(forbidden), "\(name) names \(forbidden): a hint is never written by a model")
            }
        }
    }

    func testASessionShowsEveryStepsHintWithoutAModelCall() throws {
        let rig = try TalkThroughRig(lensAvailable: true)
        XCTAssertEqual(rig.service.start(), .started)
        XCTAssertEqual(rig.lens.presented.last?.keyword, "Isolate the pump")
        XCTAssertEqual(rig.lens.presented.last?.line, "Safety: Unplug the lead before opening the housing.")
        XCTAssertEqual(rig.lens.presented.last?.source, .authored)
        _ = try rig.host.advanceProcedure(choice: nil)
        rig.clock.advance(by: 0.1)
        XCTAssertEqual(rig.service.currentHint?.items, [.expect("chamber empty")])
        XCTAssertEqual(rig.lens.presented.last?.keyword, "Drain the chamber")
        _ = try rig.host.advanceProcedure(choice: nil)
        rig.clock.advance(by: 0.1)
        XCTAssertNil(rig.service.currentHint, "the filter step carries nothing authored")
        XCTAssertEqual(rig.model.calls.count, 0, "no model call ever writes a hint")
        rig.service.stop()
    }

    func testTheEarGetsTheHintWhenThereIsNoLens() throws {
        let rig = try TalkThroughRig(lensAvailable: false)
        rig.service.start()
        XCTAssertEqual(rig.ear.spoken.last, HintReply.cutSpoken("Unplug the lead before opening the housing."))
        rig.service.stop()
    }
}
