import XCTest
@testable import OpenGlasses

/// Plan MN P2 (§4, "On the lens"): the procedure card offers `choice` and `yes_no` answers as
/// buttons beside the existing branch buttons, answers a read-back, and shows what was recorded
/// for a number — over a real runner, through `ProcedureHUDTaskSource`.
@MainActor
final class ProcedureLensAnswerTests: XCTestCase {

    private typealias F = ProcedureAnswerFixtures
    private var tempRoot: URL!
    private var logger: SessionLogger!
    private let en = Locale(identifier: "en_US")

    override func setUp() {
        super.setUp()
        tempRoot = F.temporaryRoot("ProcedureLensAnswerTests")
        logger = F.makeLogger(root: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testAYesNoAnswerIsTwoButtonsThenDoneTakesTheRulesRoute() async throws {
        let host = try ProcedureRunnerHost(F.exampleProcedure(), logger: logger)
        let source = ProcedureHUDTaskSource(host: host)
        XCTAssertEqual(source.choices.map(\.label), ["Yes", "No"])
        XCTAssertEqual(source.choices.map(\.id), ["answer:yes", "answer:no"])

        await source.choose("answer:no")
        XCTAssertEqual(host.runner?.currentAnswer?.value.option, "no")
        XCTAssertEqual(host.runner?.currentAnswer?.method, .lens)
        XCTAssertTrue(source.choices.isEmpty, "answered: the card is Done / Skip / Back again")
        XCTAssertTrue(source.current?.instruction?.contains("Recorded: Line clear: no") == true)

        await source.complete()
        XCTAssertEqual(host.activeProcedureStep?.id, "clear_line", "the rule took the route, not the lens")
    }

    func testAChoiceAnswerOffersItsOptionLabels() async throws {
        let procedure = Procedure(id: "c", title: "C", version: "1", steps: [
            .init(id: "seal", title: "Seal", instruction: "Look at the seal.",
                  branches: [.init(id: "ok", condition: "Seal good", next: "end",
                                   when: F.test("seal", .inList, .list(["good"]))),
                             .init(id: "replace", condition: "Seal worn", next: "end",
                                   when: F.test("seal", .inList, .list(["worn"])))],
                  answer: StepAnswer(recordAs: "seal", kind: .choice, label: "Seal",
                                     options: [.init(id: "good", label: "Good"), .init(id: "worn", label: "Worn")])),
            .init(id: "end", title: "End", instruction: "Done.", terminal: true, outcome: "resolved"),
        ])
        let host = try ProcedureRunnerHost(procedure, logger: logger)
        let source = ProcedureHUDTaskSource(host: host)
        XCTAssertEqual(source.choices.map(\.label), ["Good", "Worn"])
        await source.choose("answer:worn")
        XCTAssertEqual(host.runner?.currentAnswer?.value.option, "worn")
        await source.complete()
        XCTAssertEqual(host.activeProcedureStep?.id, "end")
    }

    func testANumberIsNotAButtonAndTheCardShowsWhatWasRecorded() throws {
        let host = try ProcedureRunnerHost(F.exampleProcedure(), logger: logger)
        _ = try host.answerProcedure(value: "yes", method: .typed, note: nil, confirmed: false, locale: en)
        try host.advanceProcedure(choice: nil)
        let source = ProcedureHUDTaskSource(host: host)
        XCTAssertTrue(source.choices.isEmpty)
        XCTAssertTrue(source.current?.instruction?.contains("Say or type the CO2 on the phone.") == true)

        _ = try host.answerProcedure(value: "2.55", method: .typed, note: nil, confirmed: false, locale: en)
        XCTAssertTrue(source.current?.instruction?.contains("Recorded: CO2 2.55, in spec") == true,
                      source.current?.instruction ?? "")
    }

    func testAReadBackIsAnsweredOnTheLens() async throws {
        let host = try ProcedureRunnerHost(F.phProcedure(), logger: logger)
        _ = try host.answerProcedure(value: "4.6", method: .spoken, note: nil, confirmed: false, locale: en)
        let source = ProcedureHUDTaskSource(host: host)
        XCTAssertEqual(source.choices.map(\.id), [ProcedureStepPresentation.readBackYesId,
                                                  ProcedureStepPresentation.readBackNoId])
        await source.choose(ProcedureStepPresentation.readBackYesId)
        XCTAssertEqual(host.runner?.currentAnswer?.value.number, Decimal(string: "4.60"))
        XCTAssertTrue(source.current?.instruction?.contains("corrective note") == true,
                      "critical and out of spec: the note is owed before Done goes anywhere")
        await source.complete()
        XCTAssertEqual(host.activeProcedureStep?.id, "check_ph", "no note, no route")
    }

    func testABranchNamedLikeAnAnswerNeverAnswersTheStep() async throws {
        let procedure = Procedure(id: "w", title: "W", version: "1", steps: [
            .init(id: "a", title: "A", instruction: "Look.",
                  branches: [.init(id: "yes", condition: "It's there", next: "b"),
                             .init(id: "no", condition: "It isn't", next: "b")]),
            .init(id: "b", title: "B", instruction: "End.", terminal: true),
        ])
        let host = try ProcedureRunnerHost(procedure, logger: logger)
        let source = ProcedureHUDTaskSource(host: host)
        XCTAssertEqual(source.choices.map(\.id), ["yes", "no"])
        await source.choose("yes")
        XCTAssertEqual(host.activeProcedureStep?.id, "b")
    }

    func testDoneOnAPhotoStepAttachesThePhotosTakenOnIt() async throws {
        let procedure = Procedure(id: "p", title: "P", version: "1", steps: [
            .init(id: "shot", title: "Shot", instruction: "Photograph it.", defaultNext: "end",
                  answer: StepAnswer(recordAs: "shot", kind: .photo)),
            .init(id: "end", title: "End", instruction: "Done.", terminal: true),
        ])
        let host = try ProcedureRunnerHost(procedure, logger: logger)
        let source = ProcedureHUDTaskSource(host: host)
        XCTAssertTrue(source.current?.instruction?.contains("Take the photo, then Done.") == true)
        await source.complete()
        XCTAssertEqual(host.activeProcedureStep?.id, "shot", "no photo yet")
        host.photoIds = ["a", "b"]
        await source.complete()
        XCTAssertEqual(host.activeProcedureStep?.id, "end")
    }
}
