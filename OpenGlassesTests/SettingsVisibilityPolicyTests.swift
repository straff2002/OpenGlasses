import XCTest
@testable import OpenGlasses

/// Plan HA C4 — a setting the organisation locked is not shown to the technician; an administrator
/// sees it, read-only where it still binds; an unmanaged phone is untouched; and the protections in
/// `alwaysShown` are read-only rather than hidden. Pure — no `PolicyEnvelope`, no `.shared`.
final class SettingsVisibilityPolicyTests: XCTestCase {

    private typealias Policy = SettingsVisibilityPolicy

    private let ceilings: Set<SettingKey> = [.privacyFilterEnabled, .agentModeEnabled, .mcpServerEnabled,
                                             .remoteInvokeObserveEnabled, .organizationDisplayName]

    private func technician(_ lockdown: ManagedLockdown = .standard,
                            keys: Set<SettingKey> = []) -> ManagedSettingsContext {
        ManagedSettingsContext(managed: true, lockdown: lockdown, restricted: true, lockedKeys: keys)
    }

    private func administrator(_ lockdown: ManagedLockdown = .standard,
                               keys: Set<SettingKey> = []) -> ManagedSettingsContext {
        ManagedSettingsContext(managed: true, lockdown: lockdown, restricted: false, lockedKeys: keys)
    }

    /// A profile without an edition: ceilings only, and nobody but the technician to show them to.
    private func ceilingsOnly(_ keys: Set<SettingKey>) -> ManagedSettingsContext {
        ManagedSettingsContext(managed: true, lockdown: nil, restricted: false, lockedKeys: keys)
    }

    private var everySetting: [ManagedSetting] {
        SettingsCategoryID.allCases.flatMap { [ManagedSetting.category($0), .row(in: $0)] }
            + ManagedArea.allCases.map { .area($0) }
            + SettingKey.allCases.map { .key($0) }
            + ["get_weather", "send_message"].map { .tool($0) }
    }

    // MARK: - Who is looking

    func testTheViewerFollowsTheProfileAndTheAdministratorView() {
        XCTAssertEqual(ManagedSettingsContext.unmanaged.viewer, .unmanaged)
        XCTAssertEqual(technician().viewer, .technician)
        XCTAssertEqual(administrator().viewer, .administrator)
        XCTAssertEqual(ceilingsOnly([.agentModeEnabled]).viewer, .technician,
                       "without an edition there is no administrator view to open")
    }

    // MARK: - An unmanaged phone is unchanged

    func testAnUnmanagedPhoneShowsEverythingEditable() {
        for setting in everySetting {
            XCTAssertEqual(Policy.presentation(setting, in: .unmanaged), .editable, "\(setting)")
        }
        XCTAssertEqual(Policy.hubCategories(simpleMode: false, in: .unmanaged).map(\.id),
                       SettingsCatalog.visible(simpleMode: false).map(\.id))
        XCTAssertEqual(Policy.hubCategories(simpleMode: true, in: .unmanaged).map(\.id),
                       SettingsCatalog.visible(simpleMode: true).map(\.id))
        XCTAssertFalse(Policy.hidesSettings(in: .unmanaged))
        XCTAssertEqual(Policy.hiddenSummary(in: .unmanaged), [])
    }

    // MARK: - The technician under the edition

    func testTheTechnicianHubLeavesOutEveryWhollyLockedCategory() {
        XCTAssertEqual(Policy.hubCategories(simpleMode: false, in: technician()).map(\.id),
                       [.devices, .accessibility, .fieldAssist, .lookAndFeel, .diagnostics],
                       "hub order kept; Devices & Privacy stays because Glasses and the disclosure are open")
        XCTAssertEqual(Policy.hubCategories(simpleMode: true, in: technician()).map(\.id),
                       [.devices, .accessibility, .lookAndFeel, .diagnostics],
                       "Simple Mode's filter and the lockdown's compose")
        for id in ManagedLockdown.standard.lockedCategories where id != .devices {
            XCTAssertEqual(Policy.presentation(.category(id), in: technician()), .hidden, id.rawValue)
            XCTAssertEqual(Policy.presentation(.row(in: id), in: technician()), .hidden, id.rawValue)
        }
    }

    func testAPartlyOpenCategoryShowsOnlyItsOpenRows() {
        let context = technician()
        XCTAssertEqual(Policy.presentation(.category(.devices), in: context), .editable)
        XCTAssertEqual(Policy.presentation(.area(.glasses), in: context), .editable)
        XCTAssertEqual(Policy.presentation(.area(.requestRouting), in: context), .editable)
        XCTAssertEqual(Policy.presentation(.row(in: .devices), in: context), .hidden,
                       "Hardware & Privacy and Medical Compliance are not drawn")
    }

    func testTheFieldAssistSwitchAndOwnerControlsAreHiddenButFieldAssistIsNot() {
        let context = technician()
        XCTAssertEqual(Policy.presentation(.category(.fieldAssist), in: context), .editable)
        XCTAssertEqual(Policy.presentation(.row(in: .fieldAssist), in: context), .editable)
        XCTAssertEqual(Policy.presentation(.area(.fieldAssistSwitch), in: context), .hidden)
        XCTAssertEqual(Policy.presentation(.area(.ownerControls), in: context), .hidden)
    }

    /// Nothing safety- or privacy-critical can be hidden: the pinned-open categories survive a
    /// profile that tries to lock everything, and so do the open areas.
    func testWhatThePersonAlwaysNeedsIsNeverHidden() {
        let (lockEverything, _) = ManagedLockdown.resolve(.init(
            open: nil, lock: SettingsCategoryID.allCases.map(\.rawValue), closedTools: nil))
        let context = technician(lockEverything, keys: [.privacyFilterEnabled])
        for id in ManagedLockdown.pinnedOpen {
            XCTAssertEqual(Policy.presentation(.category(id), in: context), .editable, id.rawValue)
            XCTAssertEqual(Policy.presentation(.row(in: id), in: context), .editable, id.rawValue)
        }
        XCTAssertTrue(Policy.presentation(.area(.glasses), in: context).isShown)
        XCTAssertTrue(Policy.presentation(.area(.requestRouting), in: context).isShown)
        XCTAssertEqual(Policy.presentation(.key(.privacyFilterEnabled), in: context), .readOnly,
                       "bystander blurring, pinned on, is shown read-only to the technician")
        XCTAssertEqual(Policy.alwaysShown, [.key(.privacyFilterEnabled), .area(.requestRouting),
                                            .key(.faceRecognitionEnabled), .key(.aiConnectionCueEnabled)])
        // Plan HP P2: face recognition pinned off and the AI cue pinned on are both drawn read-only
        // for the technician — one protects bystanders, the other is a disclosure.
        let hpContext = technician(lockEverything, keys: [.faceRecognitionEnabled, .aiConnectionCueEnabled])
        XCTAssertEqual(Policy.presentation(.key(.faceRecognitionEnabled), in: hpContext), .readOnly)
        XCTAssertEqual(Policy.presentation(.key(.aiConnectionCueEnabled), in: hpContext), .readOnly)
    }

    func testPinnedKeysAndClosedToolsAreHiddenFromTheTechnician() {
        let lockdown = ManagedLockdown(opening: [.tools, .connections, .intelligence], locking: [],
                                       closedTools: ["send_message"])
        let context = technician(lockdown, keys: ceilings)
        for key in [SettingKey.agentModeEnabled, .mcpServerEnabled, .remoteInvokeObserveEnabled] {
            XCTAssertEqual(Policy.presentation(.key(key), in: context), .hidden, key.rawValue)
        }
        XCTAssertEqual(Policy.presentation(.key(.remoteInvokeCaptureEnabled), in: context), .editable,
                       "only what the profile pins")
        XCTAssertEqual(Policy.presentation(.tool("send_message"), in: context), .hidden)
        XCTAssertEqual(Policy.presentation(.tool("get_weather"), in: context), .editable)
        XCTAssertEqual(Policy.presentation(.category(.tools), in: context), .editable, "the profile opened it")
    }

    // MARK: - The administrator

    func testTheAdministratorSeesEverythingAndWhatStillBindsReadOnly() {
        let lockdown = ManagedLockdown(opening: [], locking: [], closedTools: ["send_message"])
        let context = administrator(lockdown, keys: ceilings)
        XCTAssertEqual(Policy.hubCategories(simpleMode: false, in: context).map(\.id),
                       SettingsCatalog.visible(simpleMode: false).map(\.id))
        for id in SettingsCategoryID.allCases {
            XCTAssertEqual(Policy.presentation(.category(id), in: context), .editable, id.rawValue)
            XCTAssertEqual(Policy.presentation(.row(in: id), in: context), .editable, id.rawValue)
        }
        for area in ManagedArea.allCases {
            XCTAssertEqual(Policy.presentation(.area(area), in: context), .editable, area.rawValue)
        }
        XCTAssertEqual(Policy.presentation(.key(.agentModeEnabled), in: context), .readOnly,
                       "a ceiling binds the administrator too, so it is drawn locked, never hidden")
        XCTAssertEqual(Policy.presentation(.tool("send_message"), in: context), .readOnly,
                       "an administrator session does not reopen a closed tool")
        XCTAssertFalse(Policy.hidesSettings(in: context))
        XCTAssertEqual(Policy.hiddenSummary(in: context), [])
    }

    // MARK: - A profile with ceilings and no edition

    func testCeilingsWithoutAnEditionHideTheirSwitchesAndNothingElse() {
        let context = ceilingsOnly(ceilings)
        XCTAssertEqual(Policy.hubCategories(simpleMode: false, in: context).map(\.id),
                       SettingsCatalog.visible(simpleMode: false).map(\.id), "no lockdown, every category")
        XCTAssertEqual(Policy.presentation(.key(.agentModeEnabled), in: context), .hidden)
        XCTAssertEqual(Policy.presentation(.key(.privacyFilterEnabled), in: context), .readOnly)
        XCTAssertEqual(Policy.presentation(.key(.fieldAssistEnabled), in: context), .editable,
                       "a starting value is not a lock")
        XCTAssertTrue(Policy.hidesSettings(in: context))
        XCTAssertEqual(Policy.hiddenSummary(in: context), [], "the page lists pinned keys under Locks instead")
    }

    func testOrganisationIdentityAloneHidesNoSetting() {
        let context = ceilingsOnly([.organizationDisplayName, .organizationJobSigningKey])
        XCTAssertFalse(Policy.hidesSettings(in: context),
                       "the organisation's name and report route never had a settings row to hide")
        XCTAssertFalse(Policy.hidesSettings(in: ceilingsOnly([.privacyFilterEnabled])),
                       "a protection shown read-only is not hidden")
    }

    // MARK: - Saying so

    func testTheHubSaysSomethingIsHiddenAndThePageNamesIt() {
        XCTAssertTrue(Policy.hidesSettings(in: technician()))
        XCTAssertEqual(Policy.hiddenSummary(in: technician()), [
            "AI & Personality", "Voice & Triggers", "Parts of Devices & Privacy", "Tools & Actions",
            "Connections", "Capture & Streaming", "Display & HUD", "Advanced",
            "Turning Field Assist off", "Simple Mode and Lock Settings",
        ])
        let openedEverything = ManagedLockdown(opening: Set(SettingsCategoryID.allCases), locking: [], closedTools: [])
        XCTAssertEqual(Policy.hiddenSummary(in: technician(openedEverything)),
                       ["Turning Field Assist off", "Simple Mode and Lock Settings"])
        let closedTool = ManagedLockdown(opening: Set(SettingsCategoryID.allCases), locking: [],
                                         closedTools: ["send_message"])
        XCTAssertTrue(Policy.hidesSettings(in: technician(closedTool)))
    }
}

/// The rule through the administrator gate: hidden for the technician, shown in a session, hidden
/// again when the session ends.
@MainActor
final class SettingsVisibilityGateTests: XCTestCase {

    func testTheGateShowsHiddenSettingsOnlyForAnAdministratorSession() {
        let salt = Data(base64Encoded: "b3BlbmdsYXNzZXMtc2FsdA==")!
        let hash = Data(base64Encoded: "t3Byn9NtZwgSXo5BLIW88G5uJL/MRsOduKY91xwyFFI=")!
        var policy = AdminPolicy(edition: .fieldAssist,
                                 credentials: AdminCredentials(passcode: .init(salt: salt, iterations: 100_000, hash: hash),
                                                               cardDigest: nil))
        policy.lockdown = .standard
        var seams = AdminGate.Seams()
        seams.policy = { policy }
        var failures = 0
        seams.loadFailures = { failures }
        seams.saveFailures = { failures = $0 }
        seams.loadWaitUntil = { nil }
        seams.saveWaitUntil = { _ in }
        seams.loadCardSecret = { nil }
        seams.saveCardSecret = { _ in }
        let gate = AdminGate(seams: seams)

        XCTAssertEqual(gate.presentation(.category(.tools)), .hidden)
        XCTAssertEqual(gate.presentation(.area(.ownerControls)), .hidden)
        XCTAssertEqual(gate.presentation(.category(.accessibility)), .editable)
        XCTAssertEqual(gate.tryPasscode("correct horse"), .granted)
        XCTAssertEqual(gate.presentation(.category(.tools)), .editable)
        XCTAssertEqual(gate.presentation(.area(.ownerControls)), .editable)
        gate.handleBackground()
        XCTAssertEqual(gate.presentation(.category(.tools)), .hidden, "hidden again once the session ends")
    }
}
