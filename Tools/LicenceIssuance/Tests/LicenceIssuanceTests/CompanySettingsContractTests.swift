import XCTest
@testable import LicenceIssuance

/// Plan ND — the contract the portal's company-settings editor builds on: what an administrator may
/// change, the values it refuses before signing, the generation, and the assistant choices. The app's
/// `ProfileContractParityTests` holds the same contract to `SettingKey`.
final class CompanySettingsContractTests: XCTestCase {

    private var input: ProfileContract.Input {
        ProfileContract.Input(profileId: "fixture", organizationName: "Fixture Ltd", leaseDays: 60,
                              settings: ["refrigerationUnits": .init(value: .string("kPa,C,kg"), disposition: "default"),
                                         "privacyFilterEnabled": .init(value: .bool(true), disposition: "ceiling")],
                              profileGeneration: 4)
    }

    func testEveryKeyHasAKind() {
        XCTAssertEqual(ProfileContract.allowList.count, 64)
        XCTAssertTrue(ProfileContract.administratorEditableSettings.isSubset(of: Set(ProfileContract.allowList.keys)))
        XCTAssertTrue(ProfileContract.phoneCheckedSettings.isSubset(of: Set(ProfileContract.allowList.keys)))
    }

    func testAnAdministratorMayChangeADefaultButNotACeilingOrTheLease() {
        var edited = input
        edited.settings?["refrigerationUnits"] = .init(value: .string("psi,F,lb"), disposition: "default")
        XCTAssertNoThrow(try ProfileContract.checkAdministratorEdit(from: input, to: edited))

        var ceiling = input
        ceiling.settings?["privacyFilterEnabled"] = nil
        XCTAssertThrowsError(try ProfileContract.checkAdministratorEdit(from: input, to: ceiling))
        var lease = input
        lease.leaseDays = 30
        XCTAssertThrowsError(try ProfileContract.checkAdministratorEdit(from: input, to: lease))
    }

    func testThePortalRefusesValuesBeforeSigning() {
        XCTAssertThrowsError(try ProfileContract.checkSetting("refrigerationUnits", .init(value: .string("atm,C,kg"), disposition: "default")))
        XCTAssertThrowsError(try ProfileContract.checkSetting("organizationReportRecipients", .init(value: .strings([]), disposition: "default")))
        XCTAssertThrowsError(try ProfileContract.checkSetting("accentColorName", .init(value: .string("coral"), disposition: "default")))
        XCTAssertThrowsError(try ProfileContract.checkSetting("organizationFieldServiceRoute", .init(value: .string("direct"), disposition: "ceiling")))
        XCTAssertNoThrow(try ProfileContract.checkSetting("organizationFieldServiceRoute", .init(value: .string("office"), disposition: "ceiling")))
    }

    func testTheGenerationAndChoicesAreChecked() throws {
        XCTAssertNoThrow(try ProfileContract.check(input, adminPasscode: false, now: Date()))
        var zero = input
        zero.profileGeneration = 0
        XCTAssertThrowsError(try ProfileContract.check(zero, adminPasscode: false, now: Date()))
        var choices = input
        choices.aiChoices = ["chatgpt", "local"]
        XCTAssertNoThrow(try ProfileContract.check(choices, adminPasscode: false, now: Date()))
        choices.aiModel = .init(provider: "anthropic", model: "claude")
        XCTAssertThrowsError(try ProfileContract.check(choices, adminPasscode: false, now: Date()),
                             "choices mean nothing beside a pinned model")
        XCTAssertEqual(ProfileContract.nextGeneration(after: 4), 5)
    }

    func testTheDocumentCarriesTheGenerationOnlyWhenThereIsOne() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let with = try encoder.encode(ProfileContract.document(input, keyId: "k", issued: Date(timeIntervalSince1970: 0), adminPasscode: nil))
        XCTAssertTrue(String(decoding: with, as: UTF8.self).contains("\"profileGeneration\":4"))
        var plain = input
        plain.profileGeneration = nil
        let without = try encoder.encode(ProfileContract.document(plain, keyId: "k", issued: Date(timeIntervalSince1970: 0), adminPasscode: nil))
        XCTAssertFalse(String(decoding: without, as: UTF8.self).contains("profileGeneration"))
    }
}
