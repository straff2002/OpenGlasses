import XCTest
@testable import OpenGlasses

/// Plan FP P3 — the technician's name as their team sees it (owed since P1): `Config.technicianDisplayName`
/// trims, refuses control characters, caps at the contract's 120 characters and treats empty as unset;
/// a candidate is filed under it and falls back to the device's name; an organisation profile can
/// set it and lock it, and a profile's bad name is a named drop.
@MainActor
final class TechnicianNameSettingTests: XCTestCase {

    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: "technicianDisplayName")
        UserDefaults.standard.removeObject(forKey: "technicianDisplayName")
        PolicyEnvelope.clear()
    }

    override func tearDown() {
        PolicyEnvelope.clear()
        if let saved { UserDefaults.standard.set(saved, forKey: "technicianDisplayName") }
        else { UserDefaults.standard.removeObject(forKey: "technicianDisplayName") }
        super.tearDown()
    }

    private func install(_ settings: [String: RawSetting]) -> ProfileApplier.Result {
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Northbridge Mechanical",
                                    issued: Date(), leaseDays: 30, settings: settings)
        let result = ProfileApplier.apply(profile: profile, resolvableVaultIds: [])
        PolicyEnvelope.install(result, organizationName: "Northbridge Mechanical")
        return result
    }

    // MARK: - The setting

    func testTheNameIsTrimmedPlainAndCappedAndEmptyIsUnset() {
        XCTAssertEqual(Config.technicianDisplayName, "", "unset by default")
        Config.technicianDisplayName = "  Sam Tane \n"
        XCTAssertEqual(Config.technicianDisplayName, "Sam Tane")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "technicianDisplayName"), "Sam Tane", "stored cleaned")

        Config.technicianDisplayName = "Sam\u{07}Tane"
        XCTAssertEqual(Config.technicianDisplayName, "Sam Tane", "a control character becomes a space")

        Config.technicianDisplayName = String(repeating: "a", count: 150)
        XCTAssertEqual(LearningCandidateText.length(Config.technicianDisplayName), 120)

        Config.technicianDisplayName = "   "
        XCTAssertEqual(Config.technicianDisplayName, "")
        XCTAssertNil(UserDefaults.standard.object(forKey: "technicianDisplayName"), "empty means unset")
    }

    func testACandidateIsFiledUnderTheNameAndFallsBackToTheDevice() {
        XCTAssertEqual(TechnicianName.author(configured: "Sam Tane", deviceName: "iPhone"), "Sam Tane")
        XCTAssertEqual(TechnicianName.author(configured: "  ", deviceName: "iPhone"), "iPhone")
        XCTAssertEqual(TechnicianName.author(configured: "", deviceName: ""), "Technician", "never empty")

        Config.technicianDisplayName = "Mere Hohaia"
        let service = LearningCandidateService(store: LearningCandidateStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("TechName-\(UUID().uuidString)")))
        XCTAssertEqual(service.authorName(), "Mere Hohaia", "the default reads the setting")
    }

    // MARK: - An organisation profile

    func testAProfileSetsAndLocksTheName() {
        Config.technicianDisplayName = "Sam"
        let result = install(["technicianDisplayName": RawSetting(.string("Samuel Tane"), .default)])
        XCTAssertEqual(SettingKey.technicianDisplayName.kind, .profileOwned(.string))
        XCTAssertEqual(result.owned[.technicianDisplayName], .string("Samuel Tane"))
        XCTAssertTrue(result.drops.isEmpty)
        XCTAssertEqual(Config.technicianDisplayName, "Samuel Tane")
        XCTAssertTrue(PolicyEnvelope.isLocked(.technicianDisplayName))

        Config.technicianDisplayName = "Someone else"
        XCTAssertEqual(Config.technicianDisplayName, "Samuel Tane", "locked: the setter is refused")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "technicianDisplayName"), "Sam",
                       "the person's own value is left where it was")

        PolicyEnvelope.clear()
        XCTAssertEqual(Config.technicianDisplayName, "Sam", "removing the profile restores it")
        XCTAssertEqual(SettingKey.technicianDisplayName.ownedDescription, "Your name, as your team sees it")
    }

    func testAProfilesBadNameIsANamedDrop() {
        for (value, problem) in [("   ", "the name is empty"),
                                 (String(repeating: "x", count: 121), "the name is longer than 120 characters"),
                                 ("Sam\u{202E}enaT", "the name contains a control character")] {
            let result = ProfileApplier.apply(
                profile: ConfigProfile(keyId: "k", profileId: "p", organizationName: "N", issued: Date(), leaseDays: 30,
                                       settings: ["technicianDisplayName": RawSetting(.string(value), .default)]),
                resolvableVaultIds: [])
            XCTAssertNil(result.owned[.technicianDisplayName])
            XCTAssertEqual(result.drops, [.init(key: "technicianDisplayName", reason: .invalidValue(problem))])
        }
    }

    func testTheRowFollowsTheVisibilityPolicy() {
        let locked = ManagedSettingsContext(managed: true, lockdown: nil, restricted: false,
                                            lockedKeys: [.technicianDisplayName])
        XCTAssertEqual(SettingsVisibilityPolicy.presentation(.key(.technicianDisplayName), in: .unmanaged), .editable)
        XCTAssertEqual(SettingsVisibilityPolicy.presentation(.key(.technicianDisplayName), in: locked), .hidden,
                       "named by the organisation: the technician does not see an editable field")
    }
}
