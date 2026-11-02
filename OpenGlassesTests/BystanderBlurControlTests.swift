import XCTest
@testable import OpenGlasses

/// Plan KH. Blur Bystander Faces is now a tap away from Go Live, so the rules for changing it have
/// to hold however it is reached: an organisation's lock stands, and a live stream doesn't lose the
/// blur without being asked.
final class BystanderBlurControlTests: XCTestCase {

    private func context(lockedKeys: Set<SettingKey> = [], lockdown: ManagedLockdown? = nil,
                         restricted: Bool = false, managed: Bool = true) -> ManagedSettingsContext {
        ManagedSettingsContext(managed: managed, lockdown: lockdown, restricted: restricted, lockedKeys: lockedKeys)
    }

    // MARK: - Who can change it

    func testAnUnmanagedPhoneCanChangeIt() {
        XCTAssertTrue(BystanderBlurControl.isChangeable(in: .unmanaged))
    }

    func testAPinnedBlurCannotBeChanged() {
        XCTAssertFalse(BystanderBlurControl.isChangeable(in: context(lockedKeys: [.privacyFilterEnabled])))
    }

    /// Pinned or not, it stays on show.
    func testAPinnedBlurIsStillShownReadOnly() {
        let pinned = context(lockedKeys: [.privacyFilterEnabled])
        XCTAssertEqual(SettingsVisibilityPolicy.presentation(.key(.privacyFilterEnabled), in: pinned), .readOnly)
        XCTAssertTrue(SettingsVisibilityPolicy.alwaysShown.contains(.key(.privacyFilterEnabled)))
    }

    /// The shortcut must not reach a switch the lockdown closed, even with the key itself unpinned.
    func testALockdownOnDevicesCannotBeSteppedRoundFromThePreview() {
        let lockdown = ManagedLockdown.standard
        let technician = context(lockdown: lockdown, restricted: true)
        XCTAssertEqual(SettingsVisibilityPolicy.presentation(.key(.privacyFilterEnabled), in: technician), .editable)
        XCTAssertFalse(BystanderBlurControl.isChangeable(in: technician))
    }

    func testAnAdministratorPastTheLockdownCanChangeIt() {
        let lockdown = ManagedLockdown.standard
        XCTAssertTrue(BystanderBlurControl.isChangeable(in: context(lockdown: lockdown, restricted: false)))
    }

    /// Simple Mode changes nothing about the switch. It stays where it was, under Devices &
    /// Privacy, and the Live Streaming row goes with that category, as the streaming setup does.
    func testSimpleModeKeepsTheSwitchAndDropsOnlyTheStreamingRow() {
        let shown = Set(SettingsCatalog.visible(simpleMode: true).map(\.id))
        XCTAssertTrue(shown.contains(.devices))
        XCTAssertFalse(shown.contains(.capture))
        XCTAssertTrue(BystanderBlurControl.isChangeable(in: .unmanaged))
    }

    // MARK: - Asking first

    func testOneTapChangesItOffAir() {
        XCTAssertEqual(BystanderBlurControl.request(false, isOn: true, changeable: true, isLive: false), .set(false))
        XCTAssertEqual(BystanderBlurControl.request(true, isOn: false, changeable: true, isLive: false), .set(true))
    }

    func testTurningItOffWhileLiveAsksFirst() {
        XCTAssertEqual(BystanderBlurControl.request(false, isOn: true, changeable: true, isLive: true),
                       .confirmTurningOff)
    }

    func testTurningItOnWhileLiveIsStillOneTap() {
        XCTAssertEqual(BystanderBlurControl.request(true, isOn: false, changeable: true, isLive: true), .set(true))
    }

    func testALockRefusesEveryRequest() {
        for wanted in [true, false] {
            for isLive in [true, false] {
                XCTAssertEqual(BystanderBlurControl.request(wanted, isOn: !wanted, changeable: false, isLive: isLive),
                               .none)
            }
        }
    }

    func testNoChangeDoesNothing() {
        XCTAssertEqual(BystanderBlurControl.request(true, isOn: true, changeable: true, isLive: true), .none)
        XCTAssertEqual(BystanderBlurControl.request(false, isOn: false, changeable: true, isLive: true), .none)
    }

    // MARK: - Go Live's refusal

    func testTheRefusalOffersTheWayOutAndSaysWhatItCosts() {
        let refusal = BystanderBlurControl.refusal(changeable: true, organization: nil)
        XCTAssertTrue(refusal.offersTurningOff)
        XCTAssertTrue(refusal.message.contains("turn the blur off"))
        XCTAssertTrue(refusal.message.contains("applies everywhere"))
        XCTAssertTrue(refusal.message.contains("until you turn it back on"))
    }

    func testALockedRefusalOffersNoChangeAndNamesWhoSetIt() {
        let refusal = BystanderBlurControl.refusal(changeable: false, organization: "Northfield Heating")
        XCTAssertFalse(refusal.offersTurningOff)
        XCTAssertTrue(refusal.message.contains("Northfield Heating"))
        XCTAssertFalse(refusal.message.contains("turn the blur off"))
    }

    func testALockedRefusalStillReadsWithNoOrganisationName() {
        let refusal = BystanderBlurControl.refusal(changeable: false, organization: nil)
        XCTAssertFalse(refusal.offersTurningOff)
        XCTAssertTrue(refusal.message.contains("your organisation"))
    }

    /// The refusal itself stays where it was: this file changes how it is answered, never whether.
    func testTheFallbackIsStillRefusedWithTheBlurOn() {
        XCTAssertEqual(BroadcastGoLive.decide(.init(
            isBroadcasting: false, isConfigured: true, preferredSource: .glasses,
            glassesConnected: false, faceBlurOn: true, phoneCameraDenied: false, setupReachable: true)),
                       .phoneCameraNotBlurred(.fallback))
    }

    // In a phone-only build the fallback and a chosen phone camera are one refusal.
    #if AVENKIN_PHONE_ONLY
    private let routes: [BroadcastGoLive.PhoneRoute] = [.chosen, .inset, .midStreamSwitch]
    #else
    private let routes: [BroadcastGoLive.PhoneRoute] = [.fallback, .chosen, .inset, .midStreamSwitch]
    #endif

    func testEveryRouteHasItsOwnWords() {
        let messages = routes.map { BystanderBlurControl.refusal(route: $0, changeable: true, organization: nil).message }
        XCTAssertEqual(Set(messages).count, routes.count)
        let locked = routes.map { BystanderBlurControl.refusal(route: $0, changeable: false, organization: "Northfield").message }
        XCTAssertEqual(Set(locked).count, routes.count)
    }

    /// Every refusal offers the existing way out, says what it costs, and a locked one offers none.
    func testEveryRouteOffersTheTurnOffPathOnlyWhenItCanBeUsed() {
        for route in routes {
            let open = BystanderBlurControl.refusal(route: route, changeable: true, organization: nil)
            XCTAssertTrue(open.offersTurningOff, "\(route)")
            XCTAssertTrue(open.message.contains("everywhere"), "\(route)")
            let locked = BystanderBlurControl.refusal(route: route, changeable: false, organization: "Northfield")
            XCTAssertFalse(locked.offersTurningOff, "\(route)")
            XCTAssertTrue(locked.message.contains("Northfield"), "\(route)")
        }
    }

    func testTheMidStreamRefusalSaysViewersWouldSeeFaces() {
        let refusal = BystanderBlurControl.refusal(route: .midStreamSwitch, changeable: true, organization: nil)
        XCTAssertTrue(refusal.message.contains("viewers will see faces"))
    }

    /// The switch's own description has to say what it does and does not cover.
    func testTheSwitchSaysWhatItCovers() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/App/Views/BystanderBlurSwitch.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("the glasses camera feed"))
        XCTAssertTrue(source.contains("The phone camera can't be blurred"))
        XCTAssertTrue(source.contains("Photos you take yourself"))
    }
}
