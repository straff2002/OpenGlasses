import XCTest
@testable import OpenGlasses

/// Plan HA C2 — the organisation's lockdown on the edition: deny by default, pinned-open categories,
/// the profile's own adjustments as named drops, the administrator's override, and tools clamped
/// on read. Pure throughout — no `UserDefaults`, no `.shared` services.
final class ManagedLockdownTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - The standard set

    func testTheStandardSetLocksEverythingButTheBasicsAndFieldAssist() {
        XCTAssertEqual(ManagedLockdown.standard.lockedCategories,
                       [.intelligence, .voice, .devices, .tools, .connections, .capture, .display, .advanced])
        XCTAssertTrue(ManagedLockdown.standard.closedTools.isEmpty)
    }

    /// Deny by default: the lock set is computed as "everything except", so a category added to
    /// the app later is locked on a technician's phone until someone decides otherwise.
    func testTheLockSetIsTheComplementOfWhatIsOpen() {
        let open = ManagedLockdown.pinnedOpen.union(ManagedLockdown.openByDefault)
        XCTAssertEqual(ManagedLockdown.standard.lockedCategories,
                       Set(SettingsCategoryID.allCases).subtracting(open))
        XCTAssertTrue(ManagedLockdown.pinnedOpen.isDisjoint(with: ManagedLockdown.openByDefault))
    }

    func testAccessibilityIsNeverLocked() {
        let lockEverything = ManagedLockdown(opening: [], locking: Set(SettingsCategoryID.allCases), closedTools: [])
        XCTAssertEqual(lockEverything.lockedCategories.intersection(ManagedLockdown.pinnedOpen), [])
        XCTAssertFalse(lockEverything.lockedCategories.contains(.accessibility))
        for lockdown in [ManagedLockdown.standard, lockEverything] {
            XCTAssertEqual(SettingsLockPolicy.lock(.accessibility, lockdown: lockdown, restricted: true), .open)
            XCTAssertEqual(SettingsLockPolicy.lock(.diagnostics, lockdown: lockdown, restricted: true), .open)
            XCTAssertEqual(SettingsLockPolicy.lock(.lookAndFeel, lockdown: lockdown, restricted: true), .open)
        }
    }

    // MARK: - The decisions

    func testLocksApplyOnlyInTheTechniciansView() {
        let lockdown = ManagedLockdown.standard
        XCTAssertEqual(SettingsLockPolicy.lock(.intelligence, lockdown: lockdown, restricted: true), .locked)
        XCTAssertEqual(SettingsLockPolicy.lock(.intelligence, lockdown: lockdown, restricted: false), .open,
                       "an administrator session (or an administrator phone) can change everything")
        XCTAssertEqual(SettingsLockPolicy.lock(.intelligence, lockdown: nil, restricted: true), .open,
                       "no edition, no lockdown — an unmanaged phone, or a profile without an edition")
        for category in SettingsCategoryID.allCases {
            XCTAssertEqual(SettingsLockPolicy.lock(category, lockdown: lockdown, restricted: false), .open)
            XCTAssertEqual(SettingsLockPolicy.lock(category, lockdown: nil, restricted: false), .open)
        }
    }

    func testDevicesAndPrivacyKeepsGlassesAndTheRoutingDisclosureOpen() {
        let lock = SettingsLockPolicy.lock(.devices, lockdown: .standard, restricted: true)
        XCTAssertEqual(lock, .partlyOpen([.glasses, .requestRouting]))
        XCTAssertTrue(lock.isLocked, "the rest of the screen is read-only")
        XCTAssertFalse(SettingsLockPolicy.isLocked(.glasses, lockdown: .standard, restricted: true),
                       "a technician has to be able to get the glasses working")
    }

    func testFieldAssistIsOpenButItsMasterSwitchIsLocked() {
        XCTAssertEqual(SettingsLockPolicy.lock(.fieldAssist, lockdown: .standard, restricted: true), .open)
        XCTAssertTrue(SettingsLockPolicy.isLocked(.fieldAssistSwitch, lockdown: .standard, restricted: true))
        XCTAssertFalse(SettingsLockPolicy.isLocked(.fieldAssistSwitch, lockdown: .standard, restricted: false))
        XCTAssertFalse(SettingsLockPolicy.isLocked(.fieldAssistSwitch, lockdown: nil, restricted: true))
    }

    func testOwnerControlsAreLockedUnderTheEdition() {
        XCTAssertTrue(SettingsLockPolicy.isLocked(.ownerControls, lockdown: .standard, restricted: true))
        XCTAssertFalse(SettingsLockPolicy.isLocked(.ownerControls, lockdown: .standard, restricted: false))
        XCTAssertNil(ManagedArea.ownerControls.category)
    }

    /// The catalogue still lists every category; it is `SettingsVisibilityPolicy` (Plan HA C4) that
    /// leaves the wholly locked ones out of the technician's hub. Devices & Privacy is locked but
    /// partly open, so it stays.
    func testWhichCategoriesTheStandardSetLocksWhollyAndWhichPartly() {
        let everything = SettingsCatalog.visible(simpleMode: false)
        XCTAssertEqual(everything.count, SettingsCategoryID.allCases.count)
        XCTAssertEqual(everything.filter { SettingsLockPolicy.lock($0.id, lockdown: .standard, restricted: true) == .locked }
                           .map(\.id),
                       [.intelligence, .voice, .tools, .connections, .capture, .display, .advanced])
        XCTAssertEqual(everything.filter { SettingsLockPolicy.lock($0.id, lockdown: .standard, restricted: true).isLocked }
                           .map(\.id),
                       [.intelligence, .voice, .devices, .tools, .connections, .capture, .display, .advanced])
    }

    // MARK: - The profile's adjustments

    func testTheProfileCanOpenAndLock() {
        let (lockdown, drops) = ManagedLockdown.resolve(.init(open: ["voice", "devices"], lock: ["field-assist"]))
        XCTAssertTrue(drops.isEmpty)
        XCTAssertFalse(lockdown.lockedCategories.contains(.voice))
        XCTAssertFalse(lockdown.lockedCategories.contains(.devices))
        XCTAssertTrue(lockdown.lockedCategories.contains(.fieldAssist))
        XCTAssertEqual(SettingsLockPolicy.lock(.fieldAssist, lockdown: lockdown, restricted: true), .locked,
                       "its one open-able area is the switch, which is locked anyway")
        XCTAssertEqual(SettingsLockPolicy.lock(.devices, lockdown: lockdown, restricted: true), .open)
    }

    func testWhatCannotBeUsedIsANamedDrop() {
        let (lockdown, drops) = ManagedLockdown.resolve(.init(
            open: ["voice", "kiosk"], lock: ["accessibility", "voice"], closedTools: ["send_message", "Bad Tool!"]))
        XCTAssertEqual(drops.map(\.key), ["lockdown.open", "lockdown.lock", "lockdown.lock", "lockdown.closedTools"])
        XCTAssertFalse(lockdown.lockedCategories.contains(.accessibility))
        XCTAssertFalse(lockdown.lockedCategories.contains(.voice), "opened and locked — it stays open")
        XCTAssertEqual(lockdown.closedTools, ["send_message"])
    }

    func testTheApplierPutsTheLockdownOnTheEdition() {
        let spec = ConfigProfile.LockdownSpec(open: ["voice"], closedTools: ["broadcast"])
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Org", issued: now,
                                    leaseDays: 30, edition: "fieldAssist", lockdown: spec)
        let result = ProfileApplier.apply(profile: profile, resolvableVaultIds: [])
        XCTAssertEqual(result.adminPolicy?.lockdown.closedTools, ["broadcast"])
        XCTAssertEqual(result.adminPolicy?.lockdown.lockedCategories.contains(.voice), false)
        XCTAssertTrue(result.drops.isEmpty)

        let plain = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Org", issued: now,
                                  leaseDays: 30, edition: "fieldAssist")
        XCTAssertEqual(ProfileApplier.apply(profile: plain, resolvableVaultIds: []).adminPolicy?.lockdown, .standard,
                       "an edition with no lockdown field gets the standard set")
    }

    func testALockdownWithoutAnEditionIsADrop() {
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Org", issued: now,
                                    leaseDays: 30, lockdown: .init(open: ["voice"]))
        let result = ProfileApplier.apply(profile: profile, resolvableVaultIds: [])
        XCTAssertNil(result.adminPolicy)
        XCTAssertEqual(result.drops.map(\.key), ["lockdown"])
    }

    func testTheLockdownDecodesLossily() throws {
        let json = #"{"open": ["voice"], "lock": 7, "closedTools": ["web_search"]}"#
        let spec = try JSONDecoder().decode(ConfigProfile.LockdownSpec.self, from: Data(json.utf8))
        XCTAssertEqual(spec, .init(open: ["voice"], lock: nil, closedTools: ["web_search"]))
    }

    func testTheReviewNamesWhatDiffersFromTheStandardSet() {
        XCTAssertEqual(ManagedLockdown.standard.reviewLines, [])
        let (lockdown, _) = ManagedLockdown.resolve(.init(open: ["voice"], lock: ["field-assist"],
                                                          closedTools: ["web_search", "broadcast"]))
        XCTAssertEqual(lockdown.reviewLines, [
            "Left open: Voice & Triggers",
            "Also locked: Field Assist",
            "Tools switched off: broadcast, web_search",
        ])
    }

    // MARK: - Tools, clamped on read

    func testClosedToolsAreOffForEveryReaderAndTheStoredListIsKept() {
        let (lockdown, _) = ManagedLockdown.resolve(.init(closedTools: ["web_search"]))
        XCTAssertEqual(SettingsLockPolicy.effectiveDisabledTools(stored: ["calendar"], lockdown: lockdown),
                       ["calendar", "web_search"])
        XCTAssertEqual(SettingsLockPolicy.effectiveDisabledTools(stored: ["calendar"], lockdown: nil), ["calendar"])
        XCTAssertTrue(SettingsLockPolicy.isToolClosed("web_search", lockdown: lockdown))
        XCTAssertFalse(SettingsLockPolicy.isToolClosed("web_search", lockdown: nil))

        // A screen that read the clamped list and wrote it back does not store the closed tool…
        XCTAssertEqual(SettingsLockPolicy.storableDisabledTools(
            written: ["calendar", "web_search"], previouslyStored: ["calendar"], lockdown: lockdown), ["calendar"])
        // …and keeps the person's own choice for it, so lifting the lockdown restores theirs.
        XCTAssertEqual(SettingsLockPolicy.storableDisabledTools(
            written: ["web_search"], previouslyStored: ["web_search"], lockdown: lockdown), ["web_search"])
        XCTAssertEqual(SettingsLockPolicy.storableDisabledTools(
            written: ["web_search", "calendar"], previouslyStored: [], lockdown: nil), ["web_search", "calendar"])
    }

    func testToolNamesAreChecked() {
        XCTAssertTrue(ManagedLockdown.isPlausibleToolName("send_message"))
        XCTAssertTrue(ManagedLockdown.isPlausibleToolName("get_weather2"))
        XCTAssertFalse(ManagedLockdown.isPlausibleToolName(""))
        XCTAssertFalse(ManagedLockdown.isPlausibleToolName("Send"))
        XCTAssertFalse(ManagedLockdown.isPlausibleToolName(String(repeating: "a", count: 65)))
    }
}

/// The lockdown through the administrator gate: locked for the technician, open in a session.
@MainActor
final class ManagedLockdownGateTests: XCTestCase {

    func testTheGateLiftsTheLockdownForAnAdministratorSession() throws {
        let salt = Data(base64Encoded: "b3BlbmdsYXNzZXMtc2FsdA==")!
        let hash = Data(base64Encoded: "t3Byn9NtZwgSXo5BLIW88G5uJL/MRsOduKY91xwyFFI=")!
        var policy = AdminPolicy(edition: .fieldAssist,
                                 credentials: AdminCredentials(passcode: .init(salt: salt, iterations: 100_000, hash: hash),
                                                               cardDigest: nil))
        policy.lockdown = .standard
        var failures = 0
        var seams = AdminGate.Seams()
        seams.policy = { policy }
        seams.loadFailures = { failures }
        seams.saveFailures = { failures = $0 }
        seams.loadWaitUntil = { nil }
        seams.saveWaitUntil = { _ in }
        seams.loadCardSecret = { nil }
        seams.saveCardSecret = { _ in }
        let gate = AdminGate(seams: seams)

        XCTAssertEqual(gate.lock(.tools), .locked)
        XCTAssertEqual(gate.lock(.accessibility), .open)
        XCTAssertTrue(gate.isLocked(.ownerControls))
        XCTAssertEqual(gate.tryPasscode("correct horse"), .granted)
        XCTAssertEqual(gate.lock(.tools), .open)
        XCTAssertFalse(gate.isLocked(.ownerControls))
        gate.handleBackground()
        XCTAssertEqual(gate.lock(.tools), .locked, "the session ends with the app in the background")
    }
}
