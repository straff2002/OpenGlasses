import XCTest
@testable import OpenGlasses

/// Plan NJ §7 (Plan CT's ceiling-only Medical Compliance pin) — a profile can only make a phone
/// stricter: it may pin Medical Compliance and Local Only on and never off, and its retention is
/// the longest a phone keeps clinical files, never longer than the person chose. Each pin shows as
/// locked, the person's own value is left alone, and removing the profile gives it back.
@MainActor
final class HIPAACeilingKeyTests: XCTestCase {

    private let touchedKeys = ["hipaaMode", "hipaaLocalOnly", "hipaaRetentionDays", MedicalModePin.appliedKey]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        saved = [:]
        for key in touchedKeys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
        }
        PolicyEnvelope.clear()
    }

    override func tearDown() {
        PolicyEnvelope.clear()
        for key in touchedKeys {
            if let value = saved[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    private func apply(_ settings: [String: RawSetting]) -> ProfileApplier.Result {
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Example Clinic",
                                    issued: Date(), leaseDays: 30, settings: settings)
        return ProfileApplier.apply(profile: profile, resolvableVaultIds: [])
    }

    private func install(_ settings: [String: RawSetting]) {
        PolicyEnvelope.install(apply(settings), organizationName: "Example Clinic")
    }

    // MARK: - Direction

    func testTheKeysAreCeilingsThatOnlyTighten() {
        XCTAssertEqual(SettingKey.hipaaMode.kind, .ceiling(pinnedTo: true))
        XCTAssertEqual(SettingKey.hipaaLocalOnly.kind, .ceiling(pinnedTo: true))
        XCTAssertEqual(SettingKey.hipaaRetentionDays.kind, .daysCeiling(maximum: 3_650))
        XCTAssertEqual(SettingKey(rawValue: "hipaaMode"), .hipaaMode, "the key is the setting's own UserDefaults key")
    }

    func testAProfileMayTurnTheModeAndLocalOnlyOnAndNeverOff() {
        let on = apply(["hipaaMode": RawSetting(.bool(true), .ceiling), "hipaaLocalOnly": RawSetting(.bool(true), .ceiling)])
        XCTAssertEqual(on.ceilings[.hipaaMode], .bool(true))
        XCTAssertEqual(on.ceilings[.hipaaLocalOnly], .bool(true))
        XCTAssertTrue(on.drops.isEmpty)
        let off = apply(["hipaaMode": RawSetting(.bool(false), .ceiling), "hipaaLocalOnly": RawSetting(.bool(false), .ceiling)])
        XCTAssertTrue(off.ceilings.isEmpty)
        XCTAssertEqual(off.drops, [.init(key: "hipaaLocalOnly", reason: .wrongDirection),
                                   .init(key: "hipaaMode", reason: .wrongDirection)])
        let asDefault = apply(["hipaaMode": RawSetting(.bool(true), .default)])
        XCTAssertEqual(asDefault.drops, [.init(key: "hipaaMode", reason: .dispositionNotAllowed(.default))],
                       "a starting value the person could turn off is not how a clinic pins it")
    }

    func testTheRetentionCeilingTakesWholeDaysOnly() {
        XCTAssertEqual(apply(["hipaaRetentionDays": RawSetting(.string("90"), .ceiling)]).ceilings[.hipaaRetentionDays],
                       .string("90"))
        for bad in ["0", "-5", "abc", "3651", "90 days", ""] {
            let result = apply(["hipaaRetentionDays": RawSetting(.string(bad), .ceiling)])
            XCTAssertNil(result.ceilings[.hipaaRetentionDays], bad)
            guard case .invalidValue? = result.drops.first?.reason else { return XCTFail("\(bad): \(result.drops)") }
        }
        XCTAssertEqual(apply(["hipaaRetentionDays": RawSetting(.bool(true), .ceiling)]).drops,
                       [.init(key: "hipaaRetentionDays", reason: .wrongType(expected: .string))])
        XCTAssertEqual(apply(["hipaaRetentionDays": RawSetting(.string("90"), .default)]).drops,
                       [.init(key: "hipaaRetentionDays", reason: .dispositionNotAllowed(.default))])
    }

    func testTheRetentionCeilingOnlyShortens() {
        XCTAssertEqual(HIPAARetentionCeiling.effective(stored: 30, ceiling: 90), 30, "a phone set shorter keeps its own")
        XCTAssertEqual(HIPAARetentionCeiling.effective(stored: 365, ceiling: 90), 90)
        XCTAssertEqual(HIPAARetentionCeiling.effective(stored: 0, ceiling: 90), 90, "'never' is held to the figure")
        XCTAssertEqual(HIPAARetentionCeiling.effective(stored: 180, ceiling: nil), 180)
        XCTAssertEqual(HIPAARetentionCeiling.effective(stored: 0, ceiling: nil), 0)
        XCTAssertEqual(HIPAARetentionCeiling.days("365"), 365)
        XCTAssertNil(HIPAARetentionCeiling.days("3651"))
    }

    // MARK: - Through Config

    func testConfigReadsThePinAndLeavesThePersonsValueAlone() {
        UserDefaults.standard.set(false, forKey: "hipaaMode")
        UserDefaults.standard.set(false, forKey: "hipaaLocalOnly")
        UserDefaults.standard.set(365, forKey: "hipaaRetentionDays")
        install(["hipaaMode": RawSetting(.bool(true), .ceiling), "hipaaLocalOnly": RawSetting(.bool(true), .ceiling),
                 "hipaaRetentionDays": RawSetting(.string("90"), .ceiling)])
        XCTAssertTrue(Config.hipaaMode)
        XCTAssertTrue(Config.hipaaLocalOnly)
        XCTAssertEqual(Config.hipaaRetentionDays, 90)
        XCTAssertEqual(Config.hipaaRetentionCeilingDays, 90)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "hipaaMode"), "a ceiling never overwrites the stored value")

        Config.hipaaMode = false
        Config.hipaaLocalOnly = false
        Config.hipaaRetentionDays = 0
        XCTAssertTrue(Config.hipaaMode, "the setter is refused while pinned")
        XCTAssertTrue(Config.hipaaLocalOnly)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "hipaaRetentionDays"), 365)

        PolicyEnvelope.clear()
        XCTAssertFalse(Config.hipaaMode, "removing the profile gives the person's own choice back")
        XCTAssertFalse(Config.hipaaLocalOnly)
        XCTAssertEqual(Config.hipaaRetentionDays, 365)
        XCTAssertNil(Config.hipaaRetentionCeilingDays)
    }

    func testTheMedicalEgressGuardSeesThePinnedMode() {
        UserDefaults.standard.set(false, forKey: "hipaaMode")
        UserDefaults.standard.set(false, forKey: "hipaaLocalOnly")
        install(["hipaaMode": RawSetting(.bool(true), .ceiling), "hipaaLocalOnly": RawSetting(.bool(true), .ceiling)])
        XCTAssertEqual(MedicalEgressGuard.currentMode(), .init(hipaaMode: true, localOnly: true))
    }

    // MARK: - Shown as locked

    func testEachPinShowsLockedNamingTheOrganisation() {
        let result = apply(["hipaaMode": RawSetting(.bool(true), .ceiling), "hipaaLocalOnly": RawSetting(.bool(true), .ceiling),
                            "hipaaRetentionDays": RawSetting(.string("90"), .ceiling)])
        let context = ManagedSettingsContext(managed: true, lockdown: .standard, restricted: true,
                                             lockedKeys: Set(result.ceilings.keys))
        for key in [SettingKey.hipaaMode, .hipaaLocalOnly, .hipaaRetentionDays] {
            XCTAssertTrue(result.isLocked(key), key.rawValue)
            XCTAssertEqual(SettingsVisibilityPolicy.presentation(.key(key), in: context), .readOnly,
                           "\(key.rawValue): drawn read-only even for the technician, never hidden")
            XCTAssertNotEqual(key.ceilingDescription, key.rawValue, "the review sheet says what it does")
        }
        XCTAssertEqual(SettingsVisibilityPolicy.presentation(.key(.hipaaMode), in: .unmanaged), .editable)
    }

    // MARK: - What turning it on does, once per pin

    func testThePinRunsTheTurnOnOnceAndTellsWhenItGoes() {
        XCTAssertEqual(MedicalModePin.action(pinned: true, storedOn: false, applied: false), .apply)
        XCTAssertEqual(MedicalModePin.action(pinned: true, storedOn: false, applied: true), .none, "once per pin")
        XCTAssertEqual(MedicalModePin.action(pinned: true, storedOn: true, applied: false), .none,
                       "the person had it on already; turning it on ran then")
        XCTAssertEqual(MedicalModePin.action(pinned: false, storedOn: false, applied: true), .lift(modeEnds: true))
        XCTAssertEqual(MedicalModePin.action(pinned: false, storedOn: true, applied: true), .lift(modeEnds: false))
        XCTAssertEqual(MedicalModePin.action(pinned: false, storedOn: false, applied: false), .none)
    }
}
