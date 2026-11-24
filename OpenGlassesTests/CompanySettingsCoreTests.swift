import XCTest
@testable import OpenGlasses

/// Plan ND P0 — the pure core behind company settings from the portal: the generation gate, the
/// starting-value follow rule, when the profile is asked for, the managed first run, and the
/// Managed App Configuration reader.
final class CompanySettingsCoreTests: XCTestCase {

    // MARK: - ProfileGenerationGate

    func testTheGateRefusesAnythingOlderThanWhatWasApplied() {
        XCTAssertEqual(ProfileGenerationGate.judge(incoming: nil, highWater: nil), .unversioned)
        XCTAssertEqual(ProfileGenerationGate.judge(incoming: 1, highWater: nil), .newer)
        XCTAssertEqual(ProfileGenerationGate.judge(incoming: 13, highWater: 12), .newer)
        XCTAssertEqual(ProfileGenerationGate.judge(incoming: 12, highWater: 12), .same)
        XCTAssertEqual(ProfileGenerationGate.judge(incoming: 11, highWater: 12), .stale)
        XCTAssertEqual(ProfileGenerationGate.judge(incoming: nil, highWater: 12), .stale,
                       "once a generation was seen, a copy without one is older by definition")
    }

    func testTheHighWaterMarkIsNeverLowered() {
        XCTAssertNil(ProfileGenerationGate.raised(nil, by: nil))
        XCTAssertEqual(ProfileGenerationGate.raised(nil, by: 3), 3)
        XCTAssertEqual(ProfileGenerationGate.raised(5, by: 3), 5)
        XCTAssertEqual(ProfileGenerationGate.raised(5, by: nil), 5)
        XCTAssertEqual(ProfileGenerationGate.raised(5, by: 9), 9)
    }

    // MARK: - StartingValueFollow

    private let kPa = ProfileValue.string("kPa,C,kg")
    private let psi = ProfileValue.string("psi,C,kg")
    private let bar = ProfileValue.string("bar,C,kg")

    func testAnUntouchedDefaultFollowsTheCompany() {
        XCTAssertEqual(StartingValueFollow.decide(profileValue: psi, lastWritten: kPa, wroteBefore: true, stored: kPa),
                       .write(psi))
    }

    func testAPersonsOwnChoiceIsKept() {
        XCTAssertEqual(StartingValueFollow.decide(profileValue: psi, lastWritten: kPa, wroteBefore: true, stored: bar),
                       .keepPersonsChoice)
        XCTAssertEqual(StartingValueFollow.decide(profileValue: psi, lastWritten: kPa, wroteBefore: true, stored: nil),
                       .keepPersonsChoice, "a person who cleared it chose too")
    }

    func testNothingChangesWhenTheCompanysValueDidNot() {
        XCTAssertEqual(StartingValueFollow.decide(profileValue: kPa, lastWritten: kPa, wroteBefore: true, stored: bar), .nothing)
        XCTAssertEqual(StartingValueFollow.decide(profileValue: kPa, lastWritten: kPa, wroteBefore: true, stored: kPa), .nothing)
    }

    func testAPersonAlreadyOnTheNewValueFollowsFromHere() {
        XCTAssertEqual(StartingValueFollow.decide(profileValue: psi, lastWritten: kPa, wroteBefore: true, stored: psi), .adopt(psi))
    }

    func testAKeyTheCompanyAddsLater() {
        XCTAssertEqual(StartingValueFollow.decide(profileValue: psi, lastWritten: nil, wroteBefore: false, stored: nil), .write(psi))
        XCTAssertEqual(StartingValueFollow.decide(profileValue: psi, lastWritten: nil, wroteBefore: false, stored: psi), .adopt(psi))
        XCTAssertEqual(StartingValueFollow.decide(profileValue: psi, lastWritten: nil, wroteBefore: false, stored: bar),
                       .keepPersonsChoice, "set by the person before the company had a default")
    }

    func testAnUnknownLastValueIsReadAsThePersons() {
        XCTAssertEqual(StartingValueFollow.decide(profileValue: psi, lastWritten: nil, wroteBefore: true, stored: kPa),
                       .keepPersonsChoice)
    }

    func testMigrationTakesTheProfileInForceAsWhatWasWritten() {
        let migrated = StartingValueFollow.migratedLastWritten(
            wroteKeys: ["refrigerationUnits", "fieldAssistEnabled", "noLongerAKey"],
            profileInForce: [.refrigerationUnits: kPa])
        XCTAssertEqual(migrated, ["refrigerationUnits": kPa])
    }

    func testKeptChoicesListOnlyStoredValuesThatDiffer() {
        let kept = StartingValueFollow.keptChoices(
            companyValues: [.refrigerationUnits: psi, .fieldAssistEnabled: .bool(true), .accentColorName: .string("#F08A4B")],
            stored: { key in [.refrigerationUnits: self.bar, .fieldAssistEnabled: .bool(true)][key] })
        XCTAssertEqual(kept, [.init(key: .refrigerationUnits, personsValue: bar, companyValue: psi)])
    }

    // MARK: - ProfileRefreshPolicy

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testTheDailyFullFetchIsTheLeases() {
        XCTAssertEqual(ProfileRefreshPolicy.action(trigger: .routine, lastFullAttempt: nil, lastConditionalCheck: nil,
                                                   knownGeneration: 4, now: now), .full)
        XCTAssertEqual(ProfileRefreshPolicy.action(trigger: .routine, lastFullAttempt: now.addingTimeInterval(-86_400),
                                                   lastConditionalCheck: nil, knownGeneration: 4, now: now), .full)
        XCTAssertEqual(ProfileRefreshPolicy.action(trigger: .routine, lastFullAttempt: now.addingTimeInterval(3_600),
                                                   lastConditionalCheck: nil, knownGeneration: 4, now: now), .full,
                       "a clock wound back past the last attempt")
        XCTAssertEqual(ProfileRefreshPolicy.action(trigger: .forced, lastFullAttempt: now, lastConditionalCheck: now,
                                                   knownGeneration: 4, now: now), .full)
    }

    func testBetweenThemAConditionalFetchAtMostEveryFifteenMinutes() {
        let recent = now.addingTimeInterval(-3_600)
        XCTAssertEqual(ProfileRefreshPolicy.action(trigger: .routine, lastFullAttempt: recent, lastConditionalCheck: nil,
                                                   knownGeneration: 4, now: now), .conditional(generation: 4))
        XCTAssertEqual(ProfileRefreshPolicy.action(trigger: .routine, lastFullAttempt: recent,
                                                   lastConditionalCheck: now.addingTimeInterval(-600),
                                                   knownGeneration: 4, now: now), .skip)
        XCTAssertEqual(ProfileRefreshPolicy.action(trigger: .routine, lastFullAttempt: recent,
                                                   lastConditionalCheck: now.addingTimeInterval(-900),
                                                   knownGeneration: 4, now: now), .conditional(generation: 4))
    }

    func testAProfileWithoutAGenerationKeepsTheDailyFetchOnly() {
        XCTAssertEqual(ProfileRefreshPolicy.action(trigger: .routine, lastFullAttempt: now.addingTimeInterval(-3_600),
                                                   lastConditionalCheck: nil, knownGeneration: nil, now: now), .skip)
    }

    func testTheEntityTagIsTheQuotedGeneration() {
        XCTAssertEqual(ProfileRefreshPolicy.entityTag(for: 13), "\"13\"")
    }

    // MARK: - ManagedOnboardingPlan

    func testAPinnedModelLeavesPermissionsAndTheLanguage() {
        XCTAssertEqual(ManagedOnboardingPlan.pages(.init(organisationChoseModel: true, aiChoices: ["chatgpt"],
                                                         editionUsesGlasses: false)),
                       [.welcome, .permissions, .language, .ready])
    }

    func testChoicesOfferOnlyThoseAssistants() {
        XCTAssertEqual(ManagedOnboardingPlan.pages(.init(organisationChoseModel: false, aiChoices: ["chatgpt", "local"],
                                                         editionUsesGlasses: true)),
                       [.welcome, .assistant(choices: ["chatgpt", "local"]), .permissions, .language, .glasses, .ready])
    }

    func testAProfileFromBeforeChoicesKeepsTheProviderList() {
        XCTAssertEqual(ManagedOnboardingPlan.pages(.init(organisationChoseModel: false, aiChoices: nil, editionUsesGlasses: false)),
                       [.welcome, .providerList, .permissions, .language, .ready])
        XCTAssertEqual(ManagedOnboardingPlan.pages(.init(organisationChoseModel: false, aiChoices: [], editionUsesGlasses: false)),
                       [.welcome, .providerList, .permissions, .language, .ready])
    }

    func testOnlyChoicesThisBuildOffersSurvive() {
        XCTAssertEqual(ManagedOnboardingPlan.knownChoices(["local", "anthropic", "local", "chatgpt", "future"]), ["local", "chatgpt"])
        XCTAssertNil(ManagedOnboardingPlan.knownChoices(nil))
    }

    // MARK: - ManagedConfigReading

    func testTheAddressFormIsAPointer() {
        let reading = ManagedConfigReading.read(["orgProfile": "https://licence.example/p/fixture"])
        XCTAssertEqual(reading.delivery, .pointer(URL(string: "https://licence.example/p/fixture")!))
        XCTAssertTrue(reading.problems.isEmpty)
    }

    func testAnInlineDocumentIsHandedToVerification() {
        let reading = ManagedConfigReading.read(["orgProfile": "  eyJmb3JtYXQiOiJ4In0.c2ln \n"])
        XCTAssertEqual(reading.delivery, .inline("eyJmb3JtYXQiOiJ4In0.c2ln"))
    }

    func testAnythingElseIsANamedProblemNeverRawSettings() {
        XCTAssertEqual(ManagedConfigReading.read(["orgProfile": 7]).problems, [.profileNotText])
        XCTAssertEqual(ManagedConfigReading.read(["orgProfile": "http://licence.example/p/x"]).problems, [.profileUnreadable])
        XCTAssertEqual(ManagedConfigReading.read(["orgProfile": "https://user:pw@licence.example/p"]).problems, [.profileUnreadable])
        let reading = ManagedConfigReading.read(["privacyFilterEnabled": false, "agentModeEnabled": true])
        XCTAssertNil(reading.delivery)
        XCTAssertEqual(reading.ignoredKeys, ["agentModeEnabled", "privacyFilterEnabled"], "raw settings are ignored by name")
        XCTAssertFalse(ManagedConfigReading.read(nil).namesAProfile)
    }

    func testTheActivationKeyIsReadLikeATypedOne() {
        var generator = SystemRandomNumberGenerator()
        let key = ActivationKey.generate(using: &generator)
        let reading = ManagedConfigReading.read(["orgProfile": "https://licence.example/p/x", "activationKey": key.canonical])
        XCTAssertEqual(reading.activationKey, key)
        XCTAssertEqual(ManagedConfigReading.read(["activationKey": "not-a-key-0000"]).problems, [.activationKeyUnreadable])
    }

    // MARK: - ManagedConfigAbsence

    func testOneEmptyReadErasesNothing() {
        var absence = ManagedConfigAbsence()
        XCTAssertFalse(absence.observe(profilePresent: false, now: now, launchId: "a"))
        XCTAssertFalse(absence.observe(profilePresent: false, now: now.addingTimeInterval(300), launchId: "a"))
        XCTAssertTrue(absence.observe(profilePresent: false, now: now.addingTimeInterval(600), launchId: "a"))
    }

    func testTheProfileComingBackResetsTheCount() {
        var absence = ManagedConfigAbsence()
        _ = absence.observe(profilePresent: false, now: now, launchId: "a")
        XCTAssertFalse(absence.observe(profilePresent: true, now: now.addingTimeInterval(60), launchId: "a"))
        XCTAssertFalse(absence.observe(profilePresent: false, now: now.addingTimeInterval(700), launchId: "a"))
    }

    func testAbsentAcrossARelaunchIsConfirmed() {
        var absence = ManagedConfigAbsence()
        _ = absence.observe(profilePresent: false, now: now, launchId: "a")
        XCTAssertTrue(absence.observe(profilePresent: false, now: now.addingTimeInterval(5), launchId: "b"))
    }

    func testAClockWoundBackConfirmsNothing() {
        var absence = ManagedConfigAbsence()
        _ = absence.observe(profilePresent: false, now: now, launchId: "a")
        XCTAssertFalse(absence.observe(profilePresent: false, now: now.addingTimeInterval(-3_600), launchId: "a"))
    }
}
