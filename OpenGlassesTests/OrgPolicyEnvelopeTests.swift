import XCTest
@testable import OpenGlasses

/// Plan CT PR 2 — `Config` answers through the real envelope: clamped on read, the person's own
/// value left alone, and setters refused while a key is locked.
final class OrgPolicyEnvelopeTests: XCTestCase {

    private let touchedKeys = ["privacyFilterEnabled", "remoteInvokeCaptureEnabled", "agentModeEnabled",
                               "organizationDisplayName", "organizationAllowsUnsignedVaults"]
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

    private func install(_ settings: [String: RawSetting]) {
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Northbridge Mechanical",
                                    issued: Date(), leaseDays: 30, settings: settings)
        PolicyEnvelope.install(ProfileApplier.apply(profile: profile, resolvableVaultIds: []),
                               organizationName: "Northbridge Mechanical")
    }

    func testAnUnmanagedPhoneReadsItsOwnValues() {
        UserDefaults.standard.set(false, forKey: "privacyFilterEnabled")
        XCTAssertFalse(PolicyEnvelope.isManaged)
        XCTAssertFalse(Config.privacyFilterEnabled)
        XCTAssertFalse(PolicyEnvelope.isLocked(.privacyFilterEnabled))
    }

    func testACeilingWinsOnReadAndLeavesThePersonsValueAlone() {
        UserDefaults.standard.set(false, forKey: "privacyFilterEnabled")
        UserDefaults.standard.set(true, forKey: "remoteInvokeCaptureEnabled")
        install(["privacyFilterEnabled": RawSetting(.bool(true), .ceiling),
                 "remoteInvokeCaptureEnabled": RawSetting(.bool(false), .ceiling)])

        XCTAssertTrue(PolicyEnvelope.isManaged)
        XCTAssertTrue(Config.privacyFilterEnabled)
        XCTAssertFalse(Config.remoteInvokeCaptureEnabled)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "privacyFilterEnabled") as? Bool, false,
                       "a ceiling never overwrites the stored preference")
        XCTAssertEqual(UserDefaults.standard.object(forKey: "remoteInvokeCaptureEnabled") as? Bool, true)
    }

    func testASetterIsRefusedWhileItsKeyIsLocked() {
        UserDefaults.standard.set(false, forKey: "privacyFilterEnabled")
        install(["privacyFilterEnabled": RawSetting(.bool(true), .ceiling)])

        // A disabled switch writing its (clamped) value back on the way out.
        Config.setPrivacyFilterEnabled(true)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "privacyFilterEnabled") as? Bool, false)

        Config.setAgentModeEnabled(true)   // not locked by this profile
        XCTAssertTrue(Config.agentModeEnabled)
    }

    func testRemovalRestoresThePersonsValueWithNothingToPutBack() {
        UserDefaults.standard.set(true, forKey: "remoteInvokeCaptureEnabled")
        install(["remoteInvokeCaptureEnabled": RawSetting(.bool(false), .ceiling)])
        XCTAssertFalse(Config.remoteInvokeCaptureEnabled)

        PolicyEnvelope.clear()
        XCTAssertTrue(Config.remoteInvokeCaptureEnabled)
        XCTAssertNil(PolicyEnvelope.organizationName)
    }

    func testOrganisationValuesComeFromTheProfile() {
        UserDefaults.standard.removeObject(forKey: "organizationDisplayName")
        UserDefaults.standard.removeObject(forKey: "organizationAllowsUnsignedVaults")
        XCTAssertEqual(Config.organizationDisplayName, "")
        XCTAssertTrue(Config.organizationAllowsUnsignedVaults, "the default for a phone never given a profile")

        install(["organizationDisplayName": RawSetting(.string("Northbridge Mechanical"), .default),
                 "organizationAllowsUnsignedVaults": RawSetting(.bool(false), .ceiling)])
        XCTAssertEqual(Config.organizationDisplayName, "Northbridge Mechanical")
        XCTAssertFalse(Config.organizationAllowsUnsignedVaults)
        XCTAssertFalse(VaultLinkInstallPolicy.current().allowsUnsigned,
                       "the FS refusal a profile was always meant to reach")
    }

    func testTheEnvelopeAnnouncesAChange() {
        let changed = expectation(forNotification: .orgPolicyDidChange, object: nil)
        install(["mcpServerEnabled": RawSetting(.bool(false), .ceiling)])
        wait(for: [changed], timeout: 1)
    }
}
