import XCTest
@testable import OpenGlasses

/// Plan CT 3b — what the Field Assist edition closes for the technician (tabs, the model switcher).
/// Hidden is not forbidden: these are drawing rules, lifted whole by an administrator session.
final class EditionPresentationTests: XCTestCase {

    // MARK: - Tabs

    /// Since Plan HB the Modes slot stays on the technician's bar — drawn as the Field Assist tab,
    /// with the other modes hidden inside it — and only Chat is closed.
    func testTheTechnicianSeesVoiceFieldAssistJobAndSettings() {
        XCTAssertEqual(EditionPresentation.tabs(showingJob: true, restricted: true),
                       [.voice, .modes, .job, .settings])
        XCTAssertEqual(ModesTabPresentation.resolve(.init(entitled: true, entitlementChecked: true,
                                                          restricted: true)),
                       .fieldAssist(otherModes: .hidden))
        XCTAssertEqual(EditionPresentation.tabs(showingJob: true, restricted: false), MainTab.displayOrder,
                       "an administrator session, or no edition, is the full bar")
        XCTAssertEqual(EditionPresentation.tabs(showingJob: false, restricted: false),
                       MainTab.visibleOrder(showingJob: false))
    }

    func testTheRestrictedBarIsStillInDisplayOrder() {
        for showingJob in [true, false] {
            let bar = EditionPresentation.tabs(showingJob: showingJob, restricted: true)
            XCTAssertEqual(bar, MainTab.displayOrder.filter { bar.contains($0) })
        }
    }

    func testAHiddenTabFallsBackToVoice() {
        XCTAssertEqual(EditionPresentation.tab(.chat, restricted: true), .voice,
                       "the Job tab's Open conversation must not land on a tab that is not there")
        XCTAssertEqual(EditionPresentation.tab(.modes, restricted: true), .modes,
                       "the Modes slot is the technician's Field Assist tab")
        XCTAssertEqual(EditionPresentation.tab(.job, restricted: true), .job)
        XCTAssertEqual(EditionPresentation.tab(.chat, restricted: false), .chat)
    }

    // MARK: - Settings

    /// Plan HA C4: what the edition locks whole is not shown to the technician; an administrator
    /// session shows it again. Accessibility is there either way.
    func testTheEditionHidesWhatItLocksFromTheTechnicianOnly() {
        let technician = ManagedSettingsContext(managed: true, lockdown: .standard, restricted: true, lockedKeys: [])
        let administrator = ManagedSettingsContext(managed: true, lockdown: .standard, restricted: false, lockedKeys: [])
        let technicianRows = SettingsVisibilityPolicy.hubCategories(simpleMode: false, in: technician)
        XCTAssertFalse(technicianRows.contains { $0.id == .intelligence })
        XCTAssertTrue(technicianRows.contains { $0.id == .accessibility })
        XCTAssertEqual(SettingsVisibilityPolicy.hubCategories(simpleMode: false, in: administrator).count,
                       SettingsCategoryID.allCases.count)
    }

    // MARK: - The Voice tab

    func testTheModelPickerTileIsHiddenAndNothingElse() {
        XCTAssertTrue(EditionPresentation.hidesDockSlot(.control(.model), restricted: true))
        XCTAssertFalse(EditionPresentation.hidesDockSlot(.control(.model), restricted: false))
        for item in DockItem.allCases where item != .model {
            XCTAssertFalse(EditionPresentation.hidesDockSlot(.control(item), restricted: true), item.rawValue)
        }
    }
}
