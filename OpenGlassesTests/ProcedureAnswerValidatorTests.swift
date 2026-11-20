import XCTest
@testable import OpenGlasses

/// Plan MN P0 §7: what the importer refuses and warns about in answers and rules.
final class ProcedureAnswerValidatorTests: XCTestCase {

    private typealias F = ProcedureAnswerFixtures
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = F.temporaryRoot("ProcedureAnswerValidatorTests")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func procedure(_ steps: [Procedure.Step]) -> Procedure {
        Procedure(id: "p", title: "P", version: "1", steps: steps + [
            .init(id: "end", title: "End", instruction: "Done.", terminal: true)])
    }

    private func answerStep(_ answer: StepAnswer, branches: [Procedure.Branch] = [],
                            next: String? = "end") -> Procedure.Step {
        answerStep("s", answer, branches: branches, next: next)
    }

    private func answerStep(_ id: String, _ answer: StepAnswer, branches: [Procedure.Branch] = [],
                            next: String? = "end") -> Procedure.Step {
        .init(id: id, title: id, instruction: "Do it.", branches: branches,
              defaultNext: branches.isEmpty ? next : nil, answer: answer)
    }

    private func issues(_ p: Procedure) -> [String] { VaultValidator.validateProcedureGraph(p) }
    private func warnings(_ p: Procedure) -> [String] { ProcedureAnswerValidator.check(p).warnings }

    private func assertIssue(_ p: Procedure, contains text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(issues(p).contains { $0.contains(text) }, "expected an issue with '\(text)', got \(issues(p))", file: file, line: line)
    }

    // MARK: - The example vault

    func testTheExampleVaultImportsCleanAndRunsWithNoAssistant() throws {
        let result = VaultValidator.validate(directory: F.exampleVault)
        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.procedureSummary, "1 procedure, 1 runs with no assistant")
    }

    func testEveryBundledProcedureStillValidates() throws {
        for url in try F.allShippedProcedureFiles() {
            let procedure = try JSONDecoder().decode(Procedure.self, from: Data(contentsOf: url))
            XCTAssertEqual(issues(procedure), [], url.lastPathComponent)
        }
    }

    // MARK: - Answers

    func testRecordAsIsPresentSnakeCaseAndUnique() {
        let yn = { (name: String) in StepAnswer(recordAs: name, kind: .yesNo) }
        assertIssue(procedure([answerStep(yn(""))]), contains: "has no record_as")
        assertIssue(procedure([answerStep(yn("Line Clear"))]), contains: "snake_case")
        assertIssue(procedure([answerStep("a", yn("clear"), next: "b"), answerStep("b", yn("clear"))]),
                    contains: "already recorded by step 'a'")
    }

    func testTheKindIsKnownAndCarriesOnlyItsOwnFields() {
        assertIssue(procedure([answerStep(StepAnswer(recordAs: "x", kindName: "slider"))]), contains: "unknown kind 'slider'")
        assertIssue(procedure([answerStep(StepAnswer(recordAs: "x", kind: .yesNo, unit: "psi"))]),
                    contains: "fields of another kind: unit")
    }

    func testNumberDecimalsAndRanges() {
        let number = { (decimals: Int?, plausible: [Double]?, spec: [Double]?) in
            StepAnswer(recordAs: "n", kind: .number, decimals: decimals, plausible: plausible, spec: spec)
        }
        assertIssue(procedure([answerStep(number(4, [0, 10], nil))]), contains: "decimals 4")
        assertIssue(procedure([answerStep(number(1, nil, nil))]), contains: "needs plausible")
        assertIssue(procedure([answerStep(number(1, [10, 10], nil))]), contains: "plausible has lo ≥ hi")
        assertIssue(procedure([answerStep(number(1, [0, 10], [5, 12]))]), contains: "spec lies outside plausible")
        assertIssue(procedure([answerStep(number(1, [0, 10], [6, 5]))]), contains: "spec has lo > hi")
        XCTAssertEqual(issues(procedure([answerStep(number(1, [0, 10], [5, 6]))])), [])
    }

    func testAnUnknownUnitIsAWarning() {
        let odd = procedure([answerStep(StepAnswer(recordAs: "n", kind: .number, unit: "furlongs", plausible: [0, 9]))])
        XCTAssertEqual(issues(odd), [])
        XCTAssertTrue(warnings(odd).contains { $0.contains("furlongs") })
        let known = procedure([answerStep(StepAnswer(recordAs: "n", kind: .number, unit: "psig", plausible: [0, 900]))])
        XCTAssertEqual(warnings(known), [])
    }

    func testChoicesHaveTwoToTwelveDistinctOptions() {
        let one = StepAnswer(recordAs: "c", kind: .choice, options: [.init(id: "a", label: "A")])
        assertIssue(procedure([answerStep(one)]), contains: "has 1 option")
        let twice = StepAnswer(recordAs: "c", kind: .choice, options: [.init(id: "a", label: "A"), .init(id: "a", label: "B")])
        assertIssue(procedure([answerStep(twice)]), contains: "option id 'a' is used twice")
        let shared = StepAnswer(recordAs: "c", kind: .choice, options: [
            .init(id: "ok", label: "Straight", says: ["fine"]), .init(id: "bad", label: "Skewed", says: ["Fine"])])
        assertIssue(procedure([answerStep(shared)]), contains: "'fine' on step 's' is said for both 'ok' and 'bad'")
    }

    func testPhotoBounds() {
        assertIssue(procedure([answerStep(StepAnswer(recordAs: "ph_otos", kind: .photo, minPhotos: 3, maxPhotos: 2))]),
                    contains: "1 ≤ min ≤ max ≤ 5")
        assertIssue(procedure([answerStep(StepAnswer(recordAs: "shots", kind: .photo, maxPhotos: 6))]), contains: "max 6")
    }

    // MARK: - Rules

    private func ruled(_ answer: StepAnswer, _ rule: BranchRule, condition: String = "it holds") -> Procedure {
        procedure([answerStep(answer, branches: [
            .init(id: "yes", condition: condition, next: "end", when: rule),
            .init(id: "no", condition: "otherwise", next: "end", when: .not(rule)),
        ])])
    }

    func testARuleReadsAnAnswerRecordedOnOrBeforeItsStep() {
        let later = Procedure(id: "p", title: "P", version: "1", steps: [
            .init(id: "a", title: "A", instruction: "i", branches: [
                .init(id: "x", condition: "c", next: "b", when: F.test("late", .present, .flag(true)))]),
            answerStep("b", StepAnswer(recordAs: "late", kind: .yesNo)),
            .init(id: "end", title: "End", instruction: "Done.", terminal: true),
        ])
        assertIssue(later, contains: "a step that never comes before it")
        assertIssue(ruled(StepAnswer(recordAs: "x", kind: .yesNo), F.test("nobody", .present, .flag(true))),
                    contains: "reads 'nobody', which no step records")
    }

    func testAnAnswerOnOnlySomePathsIsAWarning() {
        let sometimes = Procedure(id: "p", title: "P", version: "1", steps: [
            .init(id: "fork", title: "Fork", instruction: "i", branches: [
                .init(id: "via", condition: "via", next: "measure"), .init(id: "skip", condition: "skip", next: "decide")]),
            answerStep("measure", StepAnswer(recordAs: "temp", kind: .number, plausible: [0, 100]), next: "decide"),
            .init(id: "decide", title: "Decide", instruction: "i", branches: [
                .init(id: "hot", condition: "temp above 50", next: "end", when: F.test("temp", .gt, .number(50))),
                .init(id: "else", condition: "otherwise", next: "end", when: .not(F.test("temp", .gt, .number(50)))),
            ]),
            .init(id: "end", title: "End", instruction: "Done.", terminal: true),
        ])
        XCTAssertFalse(issues(sometimes).contains { $0.contains("temp") })
        XCTAssertTrue(warnings(sometimes).contains { $0.contains("recorded only on some paths") })
    }

    func testTheComparisonFitsTheKind() {
        let choice = StepAnswer(recordAs: "c", kind: .choice, options: [.init(id: "a", label: "A"), .init(id: "b", label: "B")])
        assertIssue(ruled(choice, F.test("c", .gt, .number(1))), contains: "it compares numbers")
        assertIssue(ruled(choice, F.test("c", .inList, .list(["a", "z"]))), contains: "names z, not among its options")
        assertIssue(ruled(StepAnswer(recordAs: "y", kind: .yesNo), F.test("y", .isAnswer, .text("maybe"))), contains: "\"yes\" or \"no\"")
        assertIssue(ruled(StepAnswer(recordAs: "n", kind: .number, plausible: [0, 9]), F.test("n", .outOfSpec, .flag(true))),
                    contains: "no spec to be out of")
        assertIssue(ruled(StepAnswer(recordAs: "n", kind: .number, plausible: [0, 9]), F.test("n", .between, .pair(5, 2))),
                    contains: "lo > hi")
    }

    func testRulesNestAtMostThreeDeepAndCanBeRead() {
        let yn = StepAnswer(recordAs: "y", kind: .yesNo)
        let deep = BranchRule.not(.not(.not(.not(F.test("y", .isAnswer, .text("yes"))))))
        assertIssue(ruled(yn, deep), contains: "nests 4 deep")
        assertIssue(ruled(yn, .malformed("unknown comparison 'gtt' on 'y'")), contains: "unknown comparison 'gtt'")
    }

    func testAStepIsAllRulesOrNone() {
        let mixed = procedure([answerStep(StepAnswer(recordAs: "y", kind: .yesNo), branches: [
            .init(id: "a", condition: "yes", next: "end", when: F.test("y", .isAnswer, .text("yes"))),
            .init(id: "b", condition: "no", next: "end"),
        ])])
        assertIssue(mixed, contains: "mixes rule branches and branches chosen from words")
    }

    func testAConditionWhoseNumbersTheRuleDoesntTestIsAWarning() {
        let ph = ProcedureAnswerFixtures.phAnswer
        let wrong = ruled(ph, F.test("ph", .gt, .number(4.4)), condition: "pH above 4.5")
        XCTAssertTrue(warnings(wrong).contains { $0.contains("says 4.5, which its rule doesn't test") })
        let right = ruled(ph, F.test("ph", .gt, .number(4.4)), condition: "pH above 4.4")
        XCTAssertFalse(warnings(right).contains { $0.contains("its rule doesn't test") })
        let spec = ruled(ph, F.test("ph", .outOfSpec, .flag(true)), condition: "pH outside 3.8 to 4.4")
        XCTAssertFalse(warnings(spec).contains { $0.contains("its rule doesn't test") }, "out_of_spec tests the spec's bounds")
    }

    func testCoverageFindingsAreWarnings() {
        let gappy = F.phProcedure(branches: [
            .init(id: "in_spec", condition: "pH 3.8 to 4.4", next: "record_brix", when: F.test("ph", .between, .pair(3.8, 4.4))),
        ])
        XCTAssertEqual(issues(gappy), [])
        XCTAssertTrue(warnings(gappy).contains { $0.contains("matches no route and there is no default") })
    }

    // MARK: - Packs

    private func copyExample(minAppBuild: Int?) throws -> URL {
        let folder = tempRoot.appendingPathComponent("bottling", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.copyItem(at: F.exampleVault, to: folder)
        let pack = VaultPackManifest(id: "com.openglasses.vault.bottling_line_check", vaultId: "bottling_line_check",
                                     version: "1.0.0", name: "Example", minAppBuild: minAppBuild)
        try JSONEncoder().encode(pack).write(to: folder.appendingPathComponent(VaultPackManifest.filename))
        return folder
    }

    func testAPackUsingTheFormatShouldSetMinAppBuild() throws {
        let unset = VaultValidator.validate(directory: try copyExample(minAppBuild: nil))
        XCTAssertTrue(unset.warnings.contains { $0.contains("set minAppBuild to at least 738") }, "\(unset.warnings)")
        let old = VaultValidator.validate(directory: try copyExample(minAppBuild: 700))
        XCTAssertTrue(old.warnings.contains { $0.contains("minAppBuild") })
        let current = VaultValidator.validate(directory: try copyExample(minAppBuild: ProcedureAnswerFormat.firstAppBuild))
        XCTAssertFalse(current.warnings.contains { $0.contains("minAppBuild") })
        XCTAssertFalse(VaultValidator.validate(directory: F.exampleVault).warnings.contains { $0.contains("minAppBuild") },
                       "a folder without pack.json is not a pack")
    }
}
