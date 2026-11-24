import XCTest
@testable import OpenGlasses

/// The in-lens display settings live behind Devices & Privacy › Glasses, for someone with display
/// glasses, rather than at the bottom of Devices & Privacy for everyone. Pure — no `.shared`.
final class DisplaySettingsPlacementTests: XCTestCase {

    private typealias Placement = DisplaySettingsPlacement

    private let personal = SettingsHubPhone(glassesSupported: true)
    private let noGlasses = SettingsHubPhone(glassesSupported: false)

    private func technician(_ lockdown: ManagedLockdown = .standard) -> ManagedSettingsContext {
        ManagedSettingsContext(managed: true, lockdown: lockdown, restricted: true, lockedKeys: [])
    }

    private func administrator(_ lockdown: ManagedLockdown = .standard) -> ManagedSettingsContext {
        ManagedSettingsContext(managed: true, lockdown: lockdown, restricted: false, lockedKeys: [])
    }

    private func displayVisible(simpleMode: Bool = false, in context: ManagedSettingsContext = .unmanaged,
                                on phone: SettingsHubPhone) -> Bool {
        SettingsHub.visibleCategories(simpleMode: simpleMode, in: context, on: phone).contains { $0.id == .display }
    }

    /// Each piece of evidence alone, then none.
    private var eachPieceOfEvidence: [Placement.Evidence] {
        [.init(displayGlassesSeen: true), .init(displayEnabled: true), .init(displayOfferAnswered: true),
         .init(evenBackendChosen: true), .init(organisationOpensDisplay: true)]
    }

    // MARK: - Who sees it

    func testNoDisplayGlassesMeansNoDisplaySettingsOnTheGlassesPage() {
        XCTAssertFalse(Placement.Evidence().hasDisplayGlasses)
        XCTAssertFalse(Placement.showsOnGlassesPage(categoryVisible: true, evidence: .init()))
    }

    func testAnyOnePieceOfEvidenceIsEnough() {
        for evidence in eachPieceOfEvidence {
            XCTAssertTrue(evidence.hasDisplayGlasses, "\(evidence)")
            XCTAssertTrue(Placement.showsOnGlassesPage(categoryVisible: true, evidence: evidence), "\(evidence)")
        }
    }

    /// Moving the link does not get round Simple Mode, a lockdown, or a copy without glasses.
    func testAHiddenCategoryStaysHiddenWhateverTheEvidence() {
        let all = Placement.Evidence(displayGlassesSeen: true, displayEnabled: true, displayOfferAnswered: true,
                                     evenBackendChosen: true, organisationOpensDisplay: true)
        XCTAssertFalse(Placement.showsOnGlassesPage(categoryVisible: false, evidence: all))

        XCTAssertTrue(displayVisible(on: personal))
        XCTAssertFalse(displayVisible(simpleMode: true, on: personal), "Simple Mode hides Display & HUD")
        XCTAssertFalse(displayVisible(in: technician(), on: personal), "the standard lockdown locks it")
        XCTAssertFalse(displayVisible(on: noGlasses), "a copy without glasses has no display settings")
        XCTAssertTrue(displayVisible(in: administrator(), on: personal), "an administrator session shows it")
    }

    // MARK: - The remembered flag

    /// The live capability is true only while connected; the flag outlives it.
    func testTheSeenFlagIsSetOnceAndNeverCleared() {
        XCTAssertFalse(Placement.remembersSeen(previously: false, hasDisplayCapability: false))
        XCTAssertTrue(Placement.remembersSeen(previously: false, hasDisplayCapability: true))
        XCTAssertTrue(Placement.remembersSeen(previously: true, hasDisplayCapability: false),
                      "glasses switched off or out of range keep their settings")
        XCTAssertTrue(Placement.remembersSeen(previously: true, hasDisplayCapability: true))
    }

    func testTheSeenFlagDefaultsOffForAFreshInstall() {
        let key = "displayGlassesSeen"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(Config.displayGlassesSeen)
    }

    // MARK: - An organisation

    func testAnOrganisationOpensDisplayOnlyOnPurpose() {
        XCTAssertFalse(Placement.organisationOpensDisplay(nil), "no edition")
        XCTAssertFalse(Placement.organisationOpensDisplay(.standard), "the standard lockdown locks it")
        let opened = ManagedLockdown(opening: [.display], locking: [], closedTools: [])
        XCTAssertTrue(Placement.organisationOpensDisplay(opened))
        XCTAssertTrue(displayVisible(in: technician(opened), on: personal),
                      "a technician whose organisation opened it can reach it")
        let otherOpened = ManagedLockdown(opening: [.capture], locking: [], closedTools: [])
        XCTAssertFalse(Placement.organisationOpensDisplay(otherOpened))
    }

    /// The backend choice waits for nothing but the category: EVEN G2 glasses are recognised only
    /// once chosen.
    func testTheBackendChoiceIsOfferedWhereverTheCategoryIs() {
        XCTAssertTrue(Placement.showsBackendChoiceOnGlassesPage(categoryVisible: true))
        XCTAssertFalse(Placement.showsBackendChoiceOnGlassesPage(categoryVisible: false))
    }

    // MARK: - Devices & Privacy no longer draws it

    func testDevicesAndPrivacyNeverDrawsTheDisplaySections() {
        let contexts: [ManagedSettingsContext] = [
            .unmanaged, technician(), administrator(),
            technician(ManagedLockdown(opening: Set(SettingsCategoryID.allCases), locking: [], closedTools: [])),
        ]
        for phone in [personal, noGlasses] {
            for simpleMode in [false, true] {
                for context in contexts {
                    guard let row = SettingsHub.visibleRows(simpleMode: simpleMode, in: context, on: phone)
                        .first(where: { $0.id == .devicesPrivacy }) else { continue }
                    let sections = Placement.sectionsOnDevicesPage(alsoShowing: row.children.map(\.id))
                    XCTAssertFalse(sections.contains(.display))
                    XCTAssertFalse(sections.contains(.devices), "the page's own category is not drawn twice")
                }
            }
        }
        XCTAssertEqual(Placement.sectionsOnDevicesPage(alsoShowing: [.devices, .capture, .display]), [.capture])
    }

    /// The category keeps its row, so its lock, its profile id and `openSettings(.display)` are
    /// untouched; only where it is drawn moved.
    func testDisplayStaysACategoryOfDevicesAndPrivacy() {
        XCTAssertEqual(SettingsHub.home(of: .display, on: personal), .devicesPrivacy)
        XCTAssertEqual(SettingsHub.route(.display, visible: SettingsHub.visibleCategories(
            simpleMode: false, in: .unmanaged, on: personal)), .category(.display))
        XCTAssertEqual(SettingsHub.route(.display, visible: SettingsHub.visibleCategories(
            simpleMode: true, in: .unmanaged, on: personal)), .hub)
        XCTAssertEqual(SettingsHub.route(.display, visible: SettingsHub.visibleCategories(
            simpleMode: false, in: .unmanaged, on: noGlasses)), .hub)
    }

    func testThePathNamesTheGlassesPage() {
        XCTAssertEqual(SettingsHub.path(to: .display, on: personal),
                       "Devices & Privacy > Glasses > \(SettingsCatalog.category(.display).title)")
    }

    // MARK: - The pages use the rule

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: SettingsHubTests.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The views are not unit-testable; this holds them to the rule rather than a copy of it.
    func testThePagesAskThisRule() throws {
        let rowScreen = try Self.source("OpenGlasses/Sources/App/Views/SettingsHubRowScreen.swift")
        XCTAssertTrue(rowScreen.contains("DisplaySettingsPlacement.sectionsOnDevicesPage(alsoShowing: children)"))
        XCTAssertFalse(rowScreen.contains("alsoShows: Array(children.dropFirst())"))
        let glasses = try Self.source("OpenGlasses/Sources/App/Views/SettingsView.swift")
        XCTAssertTrue(glasses.contains("DisplaySettingsPlacement.showsOnGlassesPage("))
        XCTAssertTrue(glasses.contains("SettingsCategoryScreen(appState: appState, id: .display)"),
                      "the link goes through the category's lock wrapper")
        let hardware = try XCTUnwrap(glasses.components(separatedBy: "struct HardwarePrivacyView: View {").dropFirst().first?
            .components(separatedBy: "// MARK: - Glasses Sub-View").first, "HardwarePrivacyView is gone")
        for row in ["glassesDisplayEnabled", "hudChoiceButtonsEnabled", "HUDMirrorView(", "EvenDisplaySettingsView("] {
            XCTAssertFalse(hardware.contains(row), "\(row) is in Hardware & Privacy too; it has one home, Display & HUD")
        }
        let glassesPage = try XCTUnwrap(glasses.components(separatedBy: "struct GlassesSettingsView: View {").dropFirst()
            .first?.components(separatedBy: "// MARK: - Info Status Row").first, "GlassesSettingsView is gone")
        XCTAssertTrue(glassesPage.contains("EvenDisplaySettingsView("), "which glasses draw the lens is chosen on Glasses")
        XCTAssertTrue(glassesPage.contains("DisplaySettingsPlacement.showsBackendChoiceOnGlassesPage("))
        let display = try Self.source("OpenGlasses/Sources/App/Views/SettingsCategoryScreens.swift")
        let sections = try XCTUnwrap(display.components(separatedBy: "struct DisplayHUDSections: View {").dropFirst().first)
        XCTAssertFalse(sections.contains("EvenDisplaySettingsView("), "the backend choice has one home, the Glasses page")
        XCTAssertTrue(sections.contains("TeleprompterSettingsView("), "the teleprompter is on Display & HUD")
        // Hardware & Privacy keeps the teleprompter only on the phone-only copy, which has no display page.
        let teleprompter = try XCTUnwrap(hardware.range(of: "TeleprompterSettingsView("))
        let directives = hardware[..<teleprompter.lowerBound].components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("#") }
        XCTAssertEqual(directives.suffix(2), ["#if !AVENKIN_PHONE_ONLY", "#else"],
                       "Hardware & Privacy's teleprompter is the phone-only copy's")
        let service = try Self.source("OpenGlasses/Sources/Services/GlassesDisplayService.swift")
        XCTAssertTrue(service.contains("DisplaySettingsPlacement.remembersSeen("))
    }
}
