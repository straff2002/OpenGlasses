import XCTest
@testable import OpenGlasses

final class SimpleModeControlsPlacementTests: XCTestCase {

    func testOffLivesOnTheAdvancedAndSupportPage() {
        XCTAssertEqual(SimpleModeControlsPlacement.place(simpleModeOn: false, ownerControlsShown: true),
                       .handOverSection)
    }

    /// Simple Mode hides Advanced, so the way out has to be on the hub.
    func testOnLeavesOneRowOnTheHub() {
        XCTAssertEqual(SimpleModeControlsPlacement.place(simpleModeOn: true, ownerControlsShown: true),
                       .leaveRowOnHub)
    }

    func testAnOrganisationsLockShowsNeither() {
        XCTAssertEqual(SimpleModeControlsPlacement.place(simpleModeOn: false, ownerControlsShown: false), .none)
        XCTAssertEqual(SimpleModeControlsPlacement.place(simpleModeOn: true, ownerControlsShown: false), .none)
    }

    /// The hand-off section is only ever drawn while Simple Mode is off, and the page that holds it
    /// is reachable then: Diagnostics & Support is shown in Simple Mode or not, so the page is
    /// always on the hub.
    func testThePageThatHoldsTheSectionIsAlwaysOnTheHub() {
        let context = ManagedSettingsContext.unmanaged
        for simpleMode in [false, true] {
            let rows = SettingsHub.visibleRows(simpleMode: simpleMode, in: context,
                                               on: SettingsHubPhone(glassesSupported: true))
            XCTAssertTrue(rows.contains { $0.id == .advancedSupport }, "simpleMode=\(simpleMode)")
        }
    }
}
