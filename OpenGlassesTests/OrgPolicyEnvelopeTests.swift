import XCTest
@testable import OpenGlasses

/// Plan CT PR 2 — `Config` answers through the real envelope: clamped on read, the person's own
/// value left alone, and setters refused while a key is locked.
final class OrgPolicyEnvelopeTests: XCTestCase {

    private let touchedKeys = ["privacyFilterEnabled", "remoteInvokeCaptureEnabled", "agentModeEnabled",
                               "organizationDisplayName", "organizationAllowsUnsignedVaults",
                               "faceRecognitionEnabled", "cloudDictationEnabled", "interpreterEnabled"]
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

    /// Plan HP P1 item 2: face recognition defaults off, and an organisation's off-ceiling wins on
    /// read — through `Config` and so through the AI feature gate — without touching the wearer's
    /// own stored choice.
    func testFaceRecognitionDefaultsOffAndAnOrganisationCanPinItOff() {
        UserDefaults.standard.removeObject(forKey: "faceRecognitionEnabled")
        XCTAssertFalse(Config.faceRecognitionEnabled, "a fresh install's default is off")

        UserDefaults.standard.set(true, forKey: "faceRecognitionEnabled")
        XCTAssertTrue(AIFeatureGate.isEnabled(.faceRecognition))

        install(["faceRecognitionEnabled": RawSetting(.bool(false), .ceiling)])
        XCTAssertFalse(Config.faceRecognitionEnabled)
        XCTAssertFalse(AIFeatureGate.isEnabled(.faceRecognition))
        XCTAssertTrue(PolicyEnvelope.isLocked(.faceRecognitionEnabled))

        Config.faceRecognitionEnabled = false   // a locked switch writing back on the way out
        XCTAssertEqual(UserDefaults.standard.object(forKey: "faceRecognitionEnabled") as? Bool, true,
                       "a ceiling never overwrites the stored preference")

        PolicyEnvelope.clear()
        XCTAssertTrue(Config.faceRecognitionEnabled, "removing the profile restores the wearer's choice")
    }

    /// The spoken interpreter defaults off, and an organisation's off-ceiling reaches its gate.
    func testTheInterpreterDefaultsOffAndAnOrganisationCanPinItOff() {
        UserDefaults.standard.removeObject(forKey: "interpreterEnabled")
        XCTAssertFalse(Config.interpreterEnabled, "a fresh install's default is off")

        UserDefaults.standard.set(true, forKey: "interpreterEnabled")
        XCTAssertTrue(Config.interpreterEnabled)

        install(["interpreterEnabled": RawSetting(.bool(false), .ceiling)])
        XCTAssertFalse(Config.interpreterEnabled)
        let inputs = Config.interpreterGateInputs(pair: InterpreterPair(wearer: "en", other: "es"),
                                                  usesGeminiLive: true)
        XCTAssertEqual(InterpreterGate.refusal(inputs), .pinnedOff)

        Config.interpreterEnabled = true   // a locked switch refuses the write
        XCTAssertFalse(Config.interpreterEnabled)
        PolicyEnvelope.clear()
    }

    /// Plan JM P2: cloud dictation defaults off, and an organisation's off-ceiling wins on read —
    /// through `Config` and so through the dictation gate — without touching the wearer's choice.
    func testCloudDictationDefaultsOffAndAnOrganisationCanPinItOff() {
        UserDefaults.standard.removeObject(forKey: "cloudDictationEnabled")
        XCTAssertFalse(Config.cloudDictationEnabled, "a fresh install's default is off")

        UserDefaults.standard.set(true, forKey: "cloudDictationEnabled")
        XCTAssertTrue(Config.cloudDictationEnabled)
        XCTAssertFalse(PolicyEnvelope.isLocked(.cloudDictationEnabled))

        install(["cloudDictationEnabled": RawSetting(.bool(false), .ceiling)])
        XCTAssertFalse(Config.cloudDictationEnabled)
        XCTAssertTrue(PolicyEnvelope.isLocked(.cloudDictationEnabled))

        // The live gate's two organisation inputs both read closed.
        let live = CloudDictationGate.live
        XCTAssertFalse(live.optedIn())
        XCTAssertTrue(live.orgPinnedOff())

        Config.cloudDictationEnabled = true   // a locked switch refuses the write
        XCTAssertFalse(Config.cloudDictationEnabled)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "cloudDictationEnabled") as? Bool, true,
                       "a ceiling never overwrites the stored preference")

        PolicyEnvelope.clear()
        XCTAssertTrue(Config.cloudDictationEnabled, "removing the profile restores the wearer's choice")
    }

    func testTheEnvelopeAnnouncesAChange() {
        let changed = expectation(forNotification: .orgPolicyDidChange, object: nil)
        install(["mcpServerEnabled": RawSetting(.bool(false), .ceiling)])
        wait(for: [changed], timeout: 1)
    }
}
