import XCTest
@testable import OpenGlasses

/// Plan MN P3 — editing answers and rules on the authoring screen without a screen: the answer
/// form's round trip and its problems, the rule form's shapes, where the validator's messages land,
/// all-or-none on a step, readiness as rules go in, the rule in words, and a save that writes the
/// overlay and is carried by the export. Invented procedures only.
@MainActor
final class ProcedureRuleEditingTests: XCTestCase {

    private typealias F = ProcedureAnswerFixtures

    /// The pH procedure with its routes chosen from words, and no answer on the step.
    private func wordsProcedure() -> Procedure {
        let base = F.phProcedure()
        let step = base.step(id: "check_ph")!
        return base.replacing(step.with(answer: nil).with(branches: step.branches.map { $0.with(when: nil) }))
    }

    // MARK: - The answer form

    func testANumberAnswerRoundTripsThroughTheForm() throws {
        let draft = try XCTUnwrap(AnswerDraft(F.phAnswer))
        XCTAssertEqual(draft.plausibleLow, "0")
        XCTAssertEqual(draft.specHigh, "4.4")
        XCTAssertEqual(try draft.build().get(), F.phAnswer)
    }

    func testEveryKindRoundTripsThroughTheForm() throws {
        let answers: [StepAnswer] = [
            StepAnswer(recordAs: "seal", kind: .choice, label: "Seal", options: [
                .init(id: "ok", label: "OK", says: ["fine", "good"]), .init(id: "damaged", label: "Damaged")]),
            StepAnswer(recordAs: "guard_on", kind: .yesNo, required: false),
            StepAnswer(recordAs: "note", kind: .text, minLen: 3, maxLen: 80),
            StepAnswer(recordAs: "label_photo", kind: .photo, minPhotos: 1, maxPhotos: 3),
            StepAnswer(recordAs: "lot", kind: .code, symbology: "qr", expected: "LOT-7"),
            StepAnswer(recordAs: "temp", kind: .number, unit: "°C", decimals: 1, plausible: [-20, 120],
                       spec: [2, 8], showSpec: true),
        ]
        for answer in answers {
            XCTAssertEqual(try XCTUnwrap(AnswerDraft(answer)).build().get(), answer, answer.recordAs)
        }
    }

    func testAnAnswerOfAKindThisBuildDoesNotReadIsNotOpenedInTheForm() {
        XCTAssertNil(AnswerDraft(StepAnswer(recordAs: "x", kindName: "hologram")))
    }

    func testOnlyTheChosenKindsFieldsAreWritten() throws {
        var draft = try XCTUnwrap(AnswerDraft(F.phAnswer))
        draft.kind = .yesNo
        let built = try draft.build().get()
        XCTAssertTrue(built.kindSpecificKeys.isEmpty)
        XCTAssertEqual(built.kind, .yesNo)
    }

    func testTheFormSaysWhichFieldDoesNotRead() {
        var draft = AnswerDraft(kind: .number, recordAs: "ph")
        draft.plausibleLow = "0"
        XCTAssertEqual(draft.build(), .failure(.halfARange(String(localized: "Can be"))))
        draft.plausibleHigh = "fourteen"
        XCTAssertEqual(draft.build(), .failure(.notANumber(String(localized: "Can be"))))
        draft.plausibleHigh = "14"
        draft.recordAs = "  "
        XCTAssertEqual(draft.build(), .failure(.noRecordName))
    }

    func testADecimalCommaIsReadAsAPoint() throws {
        var draft = AnswerDraft(kind: .number, recordAs: "ph")
        draft.plausibleLow = "0"; draft.plausibleHigh = "14"
        draft.specLow = "3,8"; draft.specHigh = "4,4"
        XCTAssertEqual(try draft.build().get().spec, [3.8, 4.4])
    }

    func testAChoiceSkipsEmptyRowsAndRefusesAHalfFilledOne() throws {
        var draft = AnswerDraft(kind: .choice, recordAs: "seal")
        XCTAssertEqual(draft.options.count, 2, "a choice starts with the two options it needs")
        draft.options[0] = .init(optionId: "ok", label: "OK")
        draft.options[1] = .init(optionId: "bad", label: "Bad", says: " broken , missing ")
        draft.options.append(.init())
        let built = try draft.build().get()
        XCTAssertEqual(built.options?.count, 2)
        XCTAssertEqual(built.options?.last?.says, ["broken", "missing"])
        draft.options.append(.init(optionId: "torn"))
        XCTAssertEqual(draft.build(), .failure(.incompleteOption(4)))
    }

    // MARK: - The rule form

    func testASimpleRuleRoundTripsThroughTheForm() throws {
        let rules: [BranchRule] = [
            F.test("ph", .between, .pair(3.8, 4.4)),
            .all([F.test("ph", .gt, .number(4.4)), F.test("ph", .lt, .number(9))]),
            .any([F.test("ph", .lt, .number(3.8)), F.test("ph", .outOfSpec, .flag(true))]),
            .not(F.test("ph", .present, .flag(true))),
            .not(.all([F.test("ph", .gte, .number(1)), F.test("ph", .lte, .number(2))])),
        ]
        let answers = ["ph": F.phAnswer]
        for rule in rules {
            XCTAssertEqual(try XCTUnwrap(RuleDraft(rule)).build(answers: answers).get(), rule)
        }
    }

    func testARuleNestedBeyondTheFormIsNotOpenedInIt() {
        XCTAssertNil(RuleDraft(.all([.any([F.test("ph", .gt, .number(1))])])))
        XCTAssertNil(RuleDraft(.not(.not(F.test("ph", .gt, .number(1))))))
        XCTAssertNil(RuleDraft(.malformed("x")))
    }

    func testEqualsComparesANumberOnANumberAndAnIdOnAChoice() throws {
        let seal = StepAnswer(recordAs: "seal", kind: .choice, options: [.init(id: "ok", label: "OK"), .init(id: "bad", label: "Bad")])
        var draft = RuleDraft(answer: F.phAnswer)
        draft.tests[0].op = .eq
        draft.tests[0].value = "4.40"
        XCTAssertEqual(try draft.build(answers: ["ph": F.phAnswer]).get(), F.test("ph", .eq, .number(4.4)))
        draft.tests[0] = .init(answer: "seal", op: .eq)
        draft.tests[0].value = "bad"
        XCTAssertEqual(try draft.build(answers: ["seal": seal]).get(), F.test("seal", .eq, .text("bad")))
    }

    func testTheRuleFormSaysWhatIsMissing() {
        var draft = RuleDraft(answer: F.phAnswer)
        XCTAssertEqual(draft.tests.first?.op, .between, "a number starts with between")
        XCTAssertEqual(draft.build(answers: [:]), .failure(.notANumber(1)))
        draft.tests = []
        XCTAssertEqual(draft.build(answers: [:]), .failure(.noTests))
        draft.tests = [.init(answer: "seal", op: .inList)]
        XCTAssertEqual(draft.build(answers: [:]), .failure(.noOptions(1)))
    }

    func testTheComparisonsOfferedFitTheKind() {
        XCTAssertEqual(RuleDraft.ops(for: F.phAnswer).first, .between)
        XCTAssertTrue(RuleDraft.ops(for: F.phAnswer).contains(.outOfSpec))
        let yes = StepAnswer(recordAs: "guard_on", kind: .yesNo)
        XCTAssertEqual(RuleDraft.ops(for: yes), [.isAnswer, .present])
        let choice = StepAnswer(recordAs: "seal", kind: .choice)
        XCTAssertFalse(RuleDraft.ops(for: choice).contains(.gt))
        XCTAssertFalse(RuleDraft.ops(for: StepAnswer(recordAs: "n", kind: .number, plausible: [0, 1])).contains(.outOfSpec),
                       "out_of_spec is offered only where there is a spec")
    }

    // MARK: - The rule in words

    func testARuleReadsInWordsWithNoValues() {
        let answers = ["ph": F.phAnswer,
                       "seal": StepAnswer(recordAs: "seal", kind: .choice, label: "Seal",
                                          options: [.init(id: "damaged", label: "Damaged"), .init(id: "missing", label: "Missing")])]
        XCTAssertEqual(BranchRuleEvaluator.words(F.test("ph", .gt, .number(4.4)), answers: answers), "pH is above 4.4")
        XCTAssertEqual(BranchRuleEvaluator.words(F.test("ph", .between, .pair(3.8, 4.4)), answers: answers),
                       "pH is between 3.8 and 4.4")
        XCTAssertEqual(BranchRuleEvaluator.words(F.test("seal", .inList, .list(["damaged", "missing"])), answers: answers),
                       "Seal is Damaged or Missing")
        XCTAssertEqual(BranchRuleEvaluator.words(.all([F.test("ph", .gt, .number(4.4)), F.test("ph", .outOfSpec, .flag(true))]),
                                                 answers: answers),
                       "pH is above 4.4 and pH is out of spec (3.8 to 4.4)")
        XCTAssertEqual(BranchRuleEvaluator.words(.not(F.test("ph", .gt, .number(4.4))), answers: answers), "pH is not above 4.4")
        XCTAssertEqual(BranchRuleEvaluator.words(F.test("brix_level", .lt, .number(11)), answers: answers),
                       "brix level is below 11", "an answer the procedure doesn't hold is named by its record name")
    }

    // MARK: - The procedure being edited

    func testNothingChangesUntilAnEditAndAnEditIsCheckedAtOnce() {
        var editing = ProcedureEditing(wordsProcedure())
        XCTAssertFalse(editing.isChanged)
        XCTAssertFalse(editing.canSave)
        XCTAssertTrue(editing.messages.issues.isEmpty)
        editing.setAnswer(F.phAnswer, onStep: "check_ph")
        XCTAssertTrue(editing.isChanged)
        XCTAssertTrue(editing.canSave)
        editing.revert()
        XCTAssertFalse(editing.isChanged)
    }

    func testAStepHalfRulesHalfWordsIsAnIssueBesideItAndCantBeSaved() {
        var editing = ProcedureEditing(wordsProcedure())
        editing.setAnswer(F.phAnswer, onStep: "check_ph")
        editing.setRule(F.test("ph", .gt, .number(4.4)), branch: "high", step: "check_ph")
        XCTAssertTrue(editing.isMixed("check_ph"))
        XCTAssertFalse(editing.canSave)
        XCTAssertTrue(editing.messages(forStep: "check_ph").issues.contains { $0.contains("mixes rule branches") })
        editing.setRule(F.test("ph", .between, .pair(3.8, 4.4)), branch: "in_spec", step: "check_ph")
        editing.setRule(F.test("ph", .lt, .number(3.8)), branch: "low", step: "check_ph")
        XCTAssertFalse(editing.isMixed("check_ph"))
        XCTAssertTrue(editing.canSave)
        editing.removeRules(onStep: "check_ph")
        XCTAssertNil(editing.procedure.step(id: "check_ph")?.branches.first?.when)
    }

    func testMessagesLandBesideTheirStepAndBranch() {
        var editing = ProcedureEditing(wordsProcedure())
        editing.setAnswer(F.phAnswer, onStep: "check_ph")
        // A range written backwards, and a sentence that says another number than its rule.
        let branches: [(String, BranchRule)] = [
            ("in_spec", F.test("ph", .between, .pair(3.8, 4.4))),
            ("high", F.test("ph", .between, .pair(9, 4.4))),
            ("low", F.test("ph", .lt, .number(3.7))),
        ]
        for (id, rule) in branches { editing.setRule(rule, branch: id, step: "check_ph") }
        let high = editing.messages(forBranch: "high", step: "check_ph")
        XCTAssertTrue(high.issues.contains { $0.contains("lo > hi") }, "\(high)")
        let low = editing.messages(forBranch: "low", step: "check_ph")
        XCTAssertTrue(low.warnings.contains { $0.contains("says 3.8") }, "\(low)")
        XCTAssertTrue(editing.messages(forStep: "check_ph").warnings.contains { $0.contains("matches no route") },
                      "the gap between 3.7 and 3.8 is a coverage warning on the step")
        XCTAssertTrue(editing.messages(forStep: "record_brix").isEmpty)
        XCTAssertTrue(editing.procedureMessages.isEmpty)
    }

    func testAMessageIsPlacedByTheFirstStepItNames() {
        XCTAssertEqual(ProcedureEditing.stepId(of: "answer 'ph' on step 'b' is already recorded by step 'a'"), "b")
        XCTAssertEqual(ProcedureEditing.branchId(of: "branch 'high' on step 'x': has lo > hi"), "high")
        XCTAssertNil(ProcedureEditing.branchId(of: "step 'x' mixes rule branches"))
        XCTAssertNil(ProcedureEditing.stepId(of: "no terminal step is reachable from entry"))
    }

    func testReadinessFollowsTheRulesAsTheyGoIn() {
        var editing = ProcedureEditing(wordsProcedure())
        XCTAssertEqual(editing.readiness.map(\.stepId), ["check_ph"])
        XCTAssertEqual(editing.readiness.first?.reason, ProcedureReadiness.choosesFromWords)
        editing = ProcedureEditing(F.phProcedure())
        XCTAssertTrue(editing.readiness.isEmpty)
    }

    func testTheEditedProcedureEncodesAndReadsBack() throws {
        var editing = ProcedureEditing(wordsProcedure())
        editing.setAnswer(F.phAnswer, onStep: "check_ph")
        let decoded = try JSONDecoder().decode(Procedure.self, from: editing.encoded())
        XCTAssertEqual(decoded, editing.procedure)
    }

    // MARK: - Saving into a vault

    func testASavedProcedureIsWrittenToTheOverlayAndTheExportKeepsTheOthers() throws {
        let id = "mn_p3_authoring_test"
        let fm = FileManager.default
        let root = F.temporaryRoot("ProcedureRuleEditingTests")
        defer {
            try? fm.removeItem(at: root)
            VaultImporter.uninstall(id: id)
            VaultRegistry.shared.reloadUserManifests()
            VaultRegistry.shared.resetCache()
        }
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: folder.appendingPathComponent("procedures"), withIntermediateDirectories: true)
        let manifest = VaultManifest(id: id, name: "Rule authoring test", version: "1.0.0", files: ["info.md"],
                                     proceduresDir: "procedures", gating: .init(iap: "enterprise"),
                                     promptRules: ["Never fabricate data.", "Always cite the source file."])
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try "# Info\n\nShipped.".write(to: folder.appendingPathComponent("info.md"), atomically: true, encoding: .utf8)
        let other = Procedure(id: "other_check", title: "Other", version: "1.0.0", steps: [
            .init(id: "only", title: "Only", instruction: "Do it.", terminal: true, outcome: "resolved")])
        try JSONEncoder().encode(wordsProcedure()).write(to: folder.appendingPathComponent("procedures/ph_check.json"))
        try JSONEncoder().encode(other).write(to: folder.appendingPathComponent("procedures/other_check.json"))
        try VaultImporter.install(from: folder)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()

        let entries = ProcedureAuthoring.entries(vaultId: id)
        XCTAssertEqual(entries.map(\.file), ["other_check.json", "ph_check.json"])

        var editing = ProcedureEditing(try XCTUnwrap(entries.last?.procedure))
        editing.setAnswer(F.phAnswer, onStep: "check_ph")
        editing.setRule(F.test("ph", .gt, .number(4.4)), branch: "high", step: "check_ph")
        XCTAssertThrowsError(try ProcedureAuthoring.save(editing, file: "ph_check.json", vaultId: id),
                             "a step half rules, half words is refused, as the importer refuses it")
        for (branch, rule) in [("in_spec", F.test("ph", .between, .pair(3.8, 4.4))), ("low", F.test("ph", .lt, .number(3.8)))] {
            editing.setRule(rule, branch: branch, step: "check_ph")
        }
        XCTAssertThrowsError(try ProcedureAuthoring.save(editing, file: "../ph_check.json", vaultId: id))
        try ProcedureAuthoring.save(editing, file: "ph_check.json", vaultId: id)

        let store = try XCTUnwrap(VaultRegistry.shared.store(forId: id))
        let reread = try XCTUnwrap(ProcedureLibrary(store: store).procedure(id: "ph_check"))
        XCTAssertTrue(reread.step(id: "check_ph")?.isAppDecided == true)
        XCTAssertEqual(ProcedureAuthoring.entries(vaultId: id).first { $0.file == "ph_check.json" }?.fromOverlay, true)

        let exported = try VaultExporter.export(id: id)
        defer { try? fm.removeItem(at: exported.deletingLastPathComponent()) }
        let files = try fm.contentsOfDirectory(atPath: exported.appendingPathComponent("procedures").path).sorted()
        XCTAssertEqual(files, ["other_check.json", "ph_check.json"], "the export keeps the procedures that weren't edited")
        let exportedPh = try JSONDecoder().decode(Procedure.self, from: Data(contentsOf: exported.appendingPathComponent("procedures/ph_check.json")))
        XCTAssertEqual(exportedPh, editing.procedure)
        XCTAssertTrue(VaultValidator.validate(directory: exported).isValid)
    }

    func testOnlyAPlainProcedureFileNameIsWritten() {
        XCTAssertTrue(ProcedureAuthoring.isProcedureFileName("ph_check.json"))
        for bad in ["", ".hidden.json", "a/b.json", "../x.json", "notes.md"] {
            XCTAssertFalse(ProcedureAuthoring.isProcedureFileName(bad), bad)
        }
    }
}
