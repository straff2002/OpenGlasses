import XCTest
@testable import OpenGlasses

/// Plan CT 3b — what the Field Assist edition hides from the technician. Hidden is not forbidden:
/// these are drawing rules, lifted whole by an administrator session.
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

    func testTheShortListIsAccessibilityGlassesAndDiagnostics() {
        let everything = SettingsJourneyState(showsEverything: true).visibleCategories()
        let kept = EditionPresentation.categories(everything, restricted: true).map(\.id)
        XCTAssertEqual(Set(kept), [CapabilityCatalog.accessibility, CapabilityCatalog.glasses,
                                   CapabilityCatalog.diagnostics])
        XCTAssertFalse(kept.contains(CapabilityCatalog.voice), "Voice & Triggers is the administrator's")
        XCTAssertEqual(EditionPresentation.categories(everything, restricted: false), everything)
    }

    func testAccessibilityIsNeverWithheld() {
        for showsEverything in [false, true] {
            for simpleMode in [false, true] {
                let rows = SettingsJourneyState(showsEverything: showsEverything)
                    .visibleCategories(simpleMode: simpleMode)
                XCTAssertTrue(EditionPresentation.categories(rows, restricted: true)
                    .contains { $0.id == CapabilityCatalog.accessibility })
            }
        }
    }

    func testAFeatureAddedLaterIsHiddenFromTechniciansByDefault() {
        let later = CapabilityCategory.everyday(id: "brand-new", title: "New", icon: "sparkles", subtitle: "sub")
        XCTAssertTrue(EditionPresentation.categories([later], restricted: true).isEmpty)
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
