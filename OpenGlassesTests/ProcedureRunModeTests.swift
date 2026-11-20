import XCTest
@testable import OpenGlasses

/// Plan MN P2 (§4, decision 5): when a procedure runs with no model, and the `runs` key and the
/// organisation ceiling that ask for it.
final class ProcedureRunModeTests: XCTestCase {

    private typealias Inputs = ProcedureRunMode.Inputs

    func testAUsableModelAndNothingAskingOtherwiseRunsWithTheAssistant() {
        let decision = ProcedureRunMode.decide(Inputs())
        XCTAssertEqual(decision.mode, .assistant)
        XCTAssertEqual(decision.reason, .modelAvailable)
        XCTAssertTrue(decision.personCanChoose)
    }

    func testNoUsableModelConfiguredRunsWithNoModel() {
        let decision = ProcedureRunMode.decide(Inputs(modelConfigured: false))
        XCTAssertEqual(decision, .init(mode: .noModel, reason: .noModelConfigured))
        XCTAssertFalse(decision.personCanChoose, "there is nothing to choose")
    }

    func testOfflineWithNoOnDeviceModelRunsWithNoModel() {
        let offline = Inputs(isOnline: false)
        XCTAssertEqual(ProcedureRunMode.decide(offline), .init(mode: .noModel, reason: .offlineNoOnDeviceModel))
    }

    func testOfflineWithAModelOnThePhoneKeepsTheAssistant() {
        XCTAssertEqual(ProcedureRunMode.decide(Inputs(isOnline: false, offlineHasOnDeviceModel: true)).mode, .assistant,
                       "the offline hand-off has a phone model to hand to")
        XCTAssertEqual(ProcedureRunMode.decide(Inputs(isOnline: false, activeModelOnDevice: true)).mode, .assistant,
                       "the active model runs on the phone")
    }

    func testTheProcedureAskingForItWinsOverAUsableModel() {
        let decision = ProcedureRunMode.decide(Inputs(procedureAsks: true, personChoice: .assistant))
        XCTAssertEqual(decision, .init(mode: .noModel, reason: .procedure))
        XCTAssertFalse(decision.personCanChoose)
    }

    func testTheOrganisationForcingItWinsOverEverything() {
        let decision = ProcedureRunMode.decide(Inputs(modelConfigured: false, procedureAsks: true,
                                                      organisationForces: true))
        XCTAssertEqual(decision, .init(mode: .noModel, reason: .organisation))
        XCTAssertFalse(decision.personCanChoose)
    }

    func testThePersonsChoiceRunsWithNoModelAndCanBeTakenBack() {
        let chosen = ProcedureRunMode.decide(Inputs(personChoice: .noModel))
        XCTAssertEqual(chosen, .init(mode: .noModel, reason: .personChose))
        XCTAssertTrue(chosen.personCanChoose)
        XCTAssertEqual(ProcedureRunMode.decide(Inputs(personChoice: .assistant)).mode, .assistant)
    }

    func testChoosingTheAssistantCannotConjureAModel() {
        XCTAssertEqual(ProcedureRunMode.decide(Inputs(modelConfigured: false, personChoice: .assistant)).mode, .noModel)
        XCTAssertEqual(ProcedureRunMode.decide(Inputs(isOnline: false, personChoice: .assistant)).mode, .noModel)
    }

    func testEveryReasonHasALineThatNamesNoProviderOrPlan() {
        let reasons: [ProcedureRunMode.Reason] = [.organisation, .procedure, .noModelConfigured,
                                                  .offlineNoOnDeviceModel, .personChose, .modelAvailable]
        for reason in reasons {
            let line = ProcedureRunMode.Decision(mode: reason == .modelAvailable ? .assistant : .noModel,
                                                 reason: reason).line
            XCTAssertFalse(line.isEmpty, "\(reason)")
            for banned in ["Plan ", "Claude", "Gemini", "OpenAI", "ChatGPT", "MN"] {
                XCTAssertFalse(line.contains(banned), "\(reason): \(line)")
            }
        }
    }

    // MARK: - The procedure's `runs` key

    private func procedure(runs: String?) -> Procedure {
        Procedure(id: "p", title: "P", version: "1", steps: [
            .init(id: "a", title: "A", instruction: "Do it.", terminal: true, outcome: "resolved"),
        ], runs: runs)
    }

    func testRunsWithoutAssistantDecodesAndIsLeftOutWhenAbsent() throws {
        let json = #"{"id":"p","title":"P","version":"1","safety_notes":[],"runs":"without_assistant","steps":[{"id":"a","title":"A","instruction":"I."}]}"#
        let decoded = try JSONDecoder().decode(Procedure.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.runsWithoutAssistant)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let again = try JSONDecoder().decode(Procedure.self, from: try encoder.encode(decoded))
        XCTAssertEqual(again, decoded)
        XCTAssertEqual(try encoder.encode(again), try encoder.encode(decoded), "encodes byte-identically")

        let plain = procedure(runs: nil)
        XCTAssertFalse(plain.runsWithoutAssistant)
        XCTAssertFalse(String(decoding: try encoder.encode(plain), as: UTF8.self).contains("\"runs\""))
    }

    func testAnOlderProcedureWithoutTheKeyStillReads() throws {
        let json = #"{"id":"p","title":"P","version":"1","safety_notes":[],"steps":[{"id":"a","title":"A","instruction":"I."}]}"#
        XCTAssertNil(try JSONDecoder().decode(Procedure.self, from: Data(json.utf8)).runs)
    }

    func testAnUnknownRunsValueReadsButTheValidatorRefusesIt() throws {
        let json = #"{"id":"p","title":"P","version":"1","safety_notes":[],"runs":"sometimes","steps":[{"id":"a","title":"A","instruction":"I.","terminal":true}]}"#
        let decoded = try JSONDecoder().decode(Procedure.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.runs, "sometimes")
        XCTAssertFalse(decoded.runsWithoutAssistant, "an unknown value never means rule-only")
        let issues = ProcedureAnswerValidator.check(decoded).issues
        XCTAssertTrue(issues.contains { $0.contains("runs") && $0.contains("without_assistant") }, "\(issues)")
        XCTAssertTrue(ProcedureAnswerValidator.check(procedure(runs: "without_assistant")).issues.isEmpty)
        XCTAssertTrue(ProcedureAnswerValidator.check(procedure(runs: nil)).issues.isEmpty)
    }

    func testTheRunsKeyMakesAPackSetItsMinimumBuild() {
        XCTAssertTrue(ProcedureAnswerValidator.usesFormat(procedure(runs: "without_assistant")))
        XCTAssertFalse(ProcedureAnswerValidator.usesFormat(procedure(runs: nil)))
    }

    // MARK: - The organisation ceiling

    private func apply(_ settings: [String: RawSetting]) -> ProfileApplier.Result {
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Invented Bottling",
                                    issued: Date(), leaseDays: 30, settings: settings)
        return ProfileApplier.apply(profile: profile, resolvableVaultIds: [])
    }

    func testRunningWithoutTheAssistantIsACeilingAProfileMayOnlyPinOn() {
        let key = SettingKey.organizationRunsProceduresWithoutAssistant
        XCTAssertEqual(key.kind, .ceiling(pinnedTo: true))
        XCTAssertEqual(apply([key.rawValue: RawSetting(.bool(true), .ceiling)]).ceilings[key], .bool(true))
        let widened = apply([key.rawValue: RawSetting(.bool(false), .ceiling)])
        XCTAssertNil(widened.ceilings[key])
        XCTAssertEqual(widened.drops, [.init(key: key.rawValue, reason: .wrongDirection)])
        XCTAssertEqual(apply([key.rawValue: RawSetting(.bool(true), .default)]).drops,
                       [.init(key: key.rawValue, reason: .dispositionNotAllowed(.default))])
        XCTAssertNotEqual(key.ceilingDescription, key.rawValue)
        XCTAssertFalse(key.ceilingDescription.contains("organization"))
    }

    @MainActor
    func testConfigReadsTheCeilingThroughTheEnvelopeAndItIsOffWithoutAProfile() {
        XCTAssertFalse(Config.organizationRunsProceduresWithoutAssistant)
        PolicyEnvelope.install(apply(["organizationRunsProceduresWithoutAssistant": RawSetting(.bool(true), .ceiling)]),
                               organizationName: "Invented Bottling")
        XCTAssertTrue(Config.organizationRunsProceduresWithoutAssistant)
        XCTAssertTrue(PolicyEnvelope.isLocked(.organizationRunsProceduresWithoutAssistant))
        PolicyEnvelope.clear()
        XCTAssertFalse(Config.organizationRunsProceduresWithoutAssistant)
    }
}
