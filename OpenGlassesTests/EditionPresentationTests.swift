import XCTest
@testable import OpenGlasses

/// Plan CT 3b — what the Field Assist edition closes for the technician (tabs, the model switcher).
/// Hidden is not forbidden: these are drawing rules, lifted whole by an administrator session.
final class EditionPresentationTests: XCTestCase {

    // MARK: - Tabs

    func testTheTechnicianSeesVoiceJobAndSettings() {
        XCTAssertEqual(EditionPresentation.tabs(showingJob: true, restricted: true), [.voice, .job, .settings])
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
        XCTAssertEqual(EditionPresentation.tab(.modes, restricted: true), .voice)
        XCTAssertEqual(EditionPresentation.tab(.job, restricted: true), .job)
        XCTAssertEqual(EditionPresentation.tab(.chat, restricted: false), .chat)
    }

    // MARK: - Settings

    /// Since Plan HA the edition hides no settings category: locked rows stay rows, read-only.
    func testTheEditionLocksSettingsRatherThanHidingThem() {
        let rows = SettingsCatalog.visible(simpleMode: false)
        XCTAssertEqual(rows.count, SettingsCategoryID.allCases.count)
        XCTAssertTrue(rows.contains { SettingsLockPolicy.lock($0.id, lockdown: .standard, restricted: true) == .readOnly })
        XCTAssertTrue(rows.contains { $0.id == .accessibility })
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
