import XCTest
@testable import OpenGlasses

/// The organisation's three keys for recorded jobs (Plan HE §5), through the real applier and the
/// envelope `Config` reads — the same road every other organisation ceiling takes.
final class JobRecordingPolicyKeysTests: XCTestCase {

    private let keys: [SettingKey] = [.organizationForbidsJobRecording, .organizationRequiresBlurBeforeOfficeSync,
                                      .organizationForbidsRecordingSyncOnCellular]

    override func setUp() {
        super.setUp()
        PolicyEnvelope.clear()
    }

    override func tearDown() {
        PolicyEnvelope.clear()
        super.tearDown()
    }

    private func apply(_ settings: [String: RawSetting]) -> ProfileApplier.Result {
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Northbridge Mechanical",
                                    issued: Date(), leaseDays: 30, settings: settings)
        return ProfileApplier.apply(profile: profile, resolvableVaultIds: [])
    }

    /// Each can only tighten: a profile may forbid or require, and never take that back.
    func testEachIsACeilingPinnedOn() {
        for key in keys {
            XCTAssertEqual(key.kind, .ceiling(pinnedTo: true), key.rawValue)
            let pinned = apply([key.rawValue: RawSetting(.bool(true), .ceiling)])
            XCTAssertEqual(pinned.ceilings[key], .bool(true), key.rawValue)
            XCTAssertTrue(pinned.drops.isEmpty, key.rawValue)

            let widened = apply([key.rawValue: RawSetting(.bool(false), .ceiling)])
            XCTAssertNil(widened.ceilings[key], key.rawValue)
            XCTAssertEqual(widened.drops, [.init(key: key.rawValue, reason: .wrongDirection)], key.rawValue)

            let asAStartingValue = apply([key.rawValue: RawSetting(.bool(true), .default)])
            XCTAssertEqual(asAStartingValue.drops, [.init(key: key.rawValue, reason: .dispositionNotAllowed(.default))],
                           "\(key.rawValue) is not something a technician may then switch off")
        }
    }

    func testWithoutAProfileNothingIsForbiddenOrRequired() {
        XCTAssertFalse(Config.organizationForbidsJobRecording)
        XCTAssertFalse(Config.organizationRequiresBlurBeforeOfficeSync)
        XCTAssertFalse(Config.organizationForbidsRecordingSyncOnCellular)
    }

    func testConfigReadsEachThroughTheEnvelope() {
        PolicyEnvelope.install(apply([
            "organizationForbidsJobRecording": RawSetting(.bool(true), .ceiling),
            "organizationRequiresBlurBeforeOfficeSync": RawSetting(.bool(true), .ceiling),
            "organizationForbidsRecordingSyncOnCellular": RawSetting(.bool(true), .ceiling),
        ]), organizationName: "Northbridge Mechanical")

        XCTAssertTrue(Config.organizationForbidsJobRecording)
        XCTAssertTrue(Config.organizationRequiresBlurBeforeOfficeSync)
        XCTAssertTrue(Config.organizationForbidsRecordingSyncOnCellular)
        for key in keys { XCTAssertTrue(PolicyEnvelope.isLocked(key), key.rawValue) }

        PolicyEnvelope.clear()
        XCTAssertFalse(Config.organizationForbidsJobRecording, "read-side: removing the profile lifts it")
    }

    /// A pinned key is locked like every other organisation ceiling: the technician has no control
    /// for it, and an administrator sees it read-only.
    func testAPinnedKeyIsLockedLikeEveryOtherCeiling() {
        for key in keys {
            let technician = ManagedSettingsContext(managed: true, lockdown: .standard, restricted: true, lockedKeys: [key])
            XCTAssertEqual(SettingsVisibilityPolicy.presentation(.key(key), in: technician), .hidden, key.rawValue)
            let administrator = ManagedSettingsContext(managed: true, lockdown: .standard, restricted: false,
                                                       lockedKeys: [key])
            XCTAssertEqual(SettingsVisibilityPolicy.presentation(.key(key), in: administrator), .readOnly, key.rawValue)
            XCTAssertEqual(SettingsVisibilityPolicy.presentation(.key(key), in: .unmanaged), .editable, key.rawValue)
        }
    }

    /// The review sheet names each in words, not by its key.
    func testTheReviewSheetNamesEachInWords() {
        for key in keys {
            let line = key.ceilingDescription
            XCTAssertNotEqual(line, key.rawValue)
            XCTAssertFalse(line.contains("organization"), line)
        }
        XCTAssertTrue(SettingKey.organizationRequiresBlurBeforeOfficeSync.ceilingDescription.contains("blurred"))
    }

    /// The keys feed the two decisions they exist for.
    func testTheKeysDecideWhetherAJobIsRecordedAndHowItIsSent() {
        var facts = JobRecordingAvailability.Facts(
            officeTransportInBuild: true, fieldAssistEntitled: true, officeBindingCurrent: true,
            organizationForbidsRecording: false, organizationRequiresBlur: false, medicalComplianceMode: false,
            officeRouteRefused: false, jobIsOpen: true, jobAlreadyRecorded: false, unsyncedBytes: 0)
        XCTAssertEqual(JobRecordingAvailability.evaluate(facts), .available)
        facts.organizationForbidsRecording = true
        XCTAssertEqual(JobRecordingAvailability.evaluate(facts), .unavailable(.forbiddenByOrganization))
        facts.organizationForbidsRecording = false
        facts.organizationRequiresBlur = true
        XCTAssertEqual(JobRecordingAvailability.evaluate(facts), .unavailable(.blurRequiredButNotPossible))

        var conditions = SyncEligibility.Conditions(network: .cellular, cellularAllowedByUser: true, isCharging: true,
                                                    batteryLevel: 1, profileIsCurrent: true, leaseIsCurrent: true,
                                                    bindingIsCurrent: true, officeIsReachable: true)
        XCTAssertEqual(SyncEligibility.evaluate(conditions), .eligible)
        conditions.cellularForbiddenByOrganization = true
        XCTAssertEqual(SyncEligibility.evaluate(conditions), .notEligible(.cellularForbiddenByOrganization))
        conditions.network = .wifi
        conditions.blurRequiredAndNotDone = true
        XCTAssertEqual(SyncEligibility.evaluate(conditions), .notEligible(.blurRequired))
    }
}
