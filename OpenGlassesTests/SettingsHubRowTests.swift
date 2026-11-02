import XCTest
@testable import OpenGlasses

/// Plan KH P2 — the eight rows of the hub. A drawing layer: what a person can reach is decided per
/// category, exactly as before, and these tests hold the rows to that. Pure — no `.shared`.
final class SettingsHubRowTests: XCTestCase {

    private typealias Hub = SettingsHub

    private let personal = SettingsHubPhone(fieldAssistOn: false, glassesSupported: true)
    private let fieldPhone = SettingsHubPhone(fieldAssistOn: true, glassesSupported: true)
    private let noGlasses = SettingsHubPhone(fieldAssistOn: false, glassesSupported: false)
    private var phones: [SettingsHubPhone] { [personal, fieldPhone, noGlasses] }

    private func technician(_ lockdown: ManagedLockdown = .standard) -> ManagedSettingsContext {
        ManagedSettingsContext(managed: true, lockdown: lockdown, restricted: true, lockedKeys: [])
    }

    private func administrator(_ lockdown: ManagedLockdown = .standard) -> ManagedSettingsContext {
        ManagedSettingsContext(managed: true, lockdown: lockdown, restricted: false, lockedKeys: [])
    }

    private let ceilingsOnly = ManagedSettingsContext(managed: true, lockdown: nil, restricted: false,
                                                      lockedKeys: [.agentModeEnabled])

    private func visible(simpleMode: Bool = false, in context: ManagedSettingsContext = .unmanaged,
                         on phone: SettingsHubPhone) -> [SettingsCategory] {
        Hub.visibleCategories(simpleMode: simpleMode, in: context, on: phone)
    }

    private func rowIDs(simpleMode: Bool = false, in context: ManagedSettingsContext = .unmanaged,
                        on phone: SettingsHubPhone) -> [SettingsHubRowID] {
        Hub.visibleRows(simpleMode: simpleMode, in: context, on: phone).map(\.id)
    }

    private func row(_ id: SettingsHubRowID, simpleMode: Bool = false,
                     in context: ManagedSettingsContext = .unmanaged,
                     on phone: SettingsHubPhone) throws -> SettingsHub.VisibleRow {
        try XCTUnwrap(Hub.visibleRows(simpleMode: simpleMode, in: context, on: phone).first { $0.id == id })
    }

    // MARK: - The eight rows

    func testTheHubHasEightRowsInTheAgreedOrder() {
        for phone in phones {
            XCTAssertEqual(Hub.rows(on: phone).map(\.title), [
                "Assistant", "Everyday", "Devices & Privacy", "Connections", "Accessibility",
                "Field Assist", "Look & Feel", "Advanced & Support",
            ])
            XCTAssertEqual(rowIDs(on: phone), SettingsHubRowID.allCases)
        }
    }

    func testEveryCategoryBelongsToExactlyOneRow() {
        for phone in phones {
            let held = Hub.rows(on: phone).flatMap(\.children)
            XCTAssertEqual(held.count, Set(held).count, "a category is in two rows")
            XCTAssertEqual(Set(held), Set(SettingsCategoryID.allCases), "a category is in no row")
            for id in SettingsCategoryID.allCases {
                XCTAssertTrue(Hub.row(Hub.home(of: id, on: phone), on: phone).children.contains(id), id.rawValue)
            }
        }
    }

    func testEachRowHoldsWhatTheOwnerAskedFor() {
        func children(_ id: SettingsHubRowID) -> Set<SettingsCategoryID> { Set(Hub.row(id, on: personal).children) }
        XCTAssertEqual(children(.assistant), [.intelligence, .voice])
        XCTAssertEqual(children(.everyday), [.everyday, .myManuals])
        XCTAssertEqual(children(.devicesPrivacy), [.devices, .display, .capture])
        XCTAssertEqual(children(.connections), [.connections, .tools])
        XCTAssertEqual(children(.accessibility), [.accessibility])
        XCTAssertEqual(children(.fieldAssist), [.fieldAssist])
        XCTAssertEqual(children(.lookAndFeel), [.lookAndFeel])
        XCTAssertEqual(children(.advancedSupport), [.advanced, .diagnostics])
    }

    func testEveryRowHasWordsAndAnIcon() {
        for phone in phones {
            for row in Hub.rows(on: phone) {
                XCTAssertFalse(row.title.isEmpty)
                XCTAssertFalse(row.subtitle.isEmpty, row.title)
                XCTAssertFalse(row.icon.isEmpty, row.title)
            }
        }
    }

    // MARK: - A drawing change only

    /// Everything a profile names. The rows are not in this list on purpose.
    func testEveryRawValueIsPinned() {
        XCTAssertEqual(SettingsCategoryID.allCases.map(\.rawValue), [
            "intelligence", "voice", "everyday", "devices", "accessibility", "field-assist", "my-manuals",
            "look-and-feel", "tools", "connections", "capture", "display", "advanced", "diagnostics",
        ])
        XCTAssertEqual(ProfileContract.settingsCategoryIds, SettingsCategoryID.allCases.map(\.rawValue))
        XCTAssertEqual(ManagedLockdown.pinnedOpen, [.accessibility, .lookAndFeel, .diagnostics])
        XCTAssertEqual(ManagedLockdown.openByDefault, [.fieldAssist])
    }

    func testTheCatalogStillListsEveryCategoryInItsOwnOrder() {
        XCTAssertEqual(SettingsCatalog.all.map(\.id), SettingsCategoryID.allCases)
        XCTAssertEqual(SettingsCatalog.visible(simpleMode: true).map(\.id),
                       [.voice, .devices, .accessibility, .myManuals, .lookAndFeel, .diagnostics])
    }

    // MARK: - The same categories as before

    /// The sets the hub drew as fourteen rows, written out so they cannot follow a change here.
    func testSimpleModeShowsTheSameCategories() {
        for phone in [personal, fieldPhone] {
            XCTAssertEqual(Set(visible(simpleMode: true, on: phone).map(\.id)),
                           [.voice, .devices, .accessibility, .myManuals, .lookAndFeel, .diagnostics])
        }
        XCTAssertEqual(Set(visible(on: personal).map(\.id)), Set(SettingsCategoryID.allCases))
    }

    func testTheStandardLockdownShowsTheSameCategories() {
        for phone in [personal, fieldPhone] {
            XCTAssertEqual(Set(visible(in: technician(), on: phone).map(\.id)),
                           [.devices, .accessibility, .fieldAssist, .lookAndFeel, .diagnostics])
            XCTAssertEqual(Set(visible(simpleMode: true, in: technician(), on: phone).map(\.id)),
                           [.devices, .accessibility, .lookAndFeel, .diagnostics])
        }
    }

    func testAnOpenedOrLockedCategoryFollowsTheProfile() {
        let opened = ManagedLockdown(opening: [.voice, .capture, .everyday], locking: [.fieldAssist], closedTools: [])
        XCTAssertEqual(Set(visible(in: technician(opened), on: personal).map(\.id)),
                       [.voice, .everyday, .devices, .accessibility, .capture, .lookAndFeel, .diagnostics])
    }

    func testAnAdministratorAndACeilingsOnlyProfileLoseNothing() {
        for context in [administrator(), ceilingsOnly] {
            XCTAssertEqual(Set(visible(in: context, on: personal).map(\.id)), Set(SettingsCategoryID.allCases))
            XCTAssertEqual(rowIDs(in: context, on: personal), SettingsHubRowID.allCases)
        }
    }

    func testACopyWithoutGlassesHasNoDisplaySettings() {
        XCTAssertFalse(visible(on: noGlasses).contains { $0.id == .display })
    }

    func testTheRowsDrawExactlyTheVisibleCategories() throws {
        let contexts: [ManagedSettingsContext] = [
            .unmanaged, technician(), administrator(), ceilingsOnly,
            technician(ManagedLockdown(opening: [.voice, .tools], locking: [.fieldAssist], closedTools: [])),
        ]
        for phone in phones {
            for context in contexts {
                for simpleMode in [false, true] {
                    let drawn = Hub.visibleRows(simpleMode: simpleMode, in: context, on: phone)
                        .flatMap(\.children).map(\.id)
                    XCTAssertEqual(drawn.count, Set(drawn).count)
                    XCTAssertEqual(Set(drawn), Set(visible(simpleMode: simpleMode, in: context, on: phone).map(\.id)))
                }
            }
        }
    }

    // MARK: - Accessibility

    func testAccessibilityIsAlwaysOnTheHub() {
        let lockEverything = ManagedLockdown(opening: [], locking: Set(SettingsCategoryID.allCases), closedTools: [])
        for phone in phones {
            for context in [ManagedSettingsContext.unmanaged, technician(), technician(lockEverything), administrator(), ceilingsOnly] {
                for simpleMode in [false, true] {
                    XCTAssertTrue(rowIDs(simpleMode: simpleMode, in: context, on: phone).contains(.accessibility))
                }
            }
        }
    }

    // MARK: - A row with nothing behind it

    func testARowWithNoVisibleCategoryDisappears() {
        XCTAssertEqual(rowIDs(in: technician(), on: personal),
                       [.devicesPrivacy, .accessibility, .fieldAssist, .lookAndFeel, .advancedSupport],
                       "no Assistant, Everyday or Connections on the standard lockdown")
    }

    func testSimpleModeDrawsOnlyTheRowsWithSomethingInThem() {
        XCTAssertEqual(rowIDs(simpleMode: true, on: personal),
                       [.assistant, .everyday, .devicesPrivacy, .accessibility, .lookAndFeel, .advancedSupport])
        XCTAssertEqual(rowIDs(simpleMode: true, on: fieldPhone),
                       [.assistant, .devicesPrivacy, .accessibility, .fieldAssist, .lookAndFeel, .advancedSupport])
    }

    // MARK: - One visible category

    func testSimpleModeRowsGoStraightToTheOneCategory() throws {
        XCTAssertEqual(try row(.assistant, simpleMode: true, on: personal).page, .category(.voice))
        XCTAssertEqual(try row(.everyday, simpleMode: true, on: personal).page, .category(.myManuals))
        XCTAssertEqual(try row(.fieldAssist, simpleMode: true, on: fieldPhone).page, .category(.myManuals))
        XCTAssertEqual(try row(.devicesPrivacy, simpleMode: true, on: personal).page, .category(.devices))
        XCTAssertEqual(try row(.advancedSupport, simpleMode: true, on: personal).page, .category(.diagnostics))
    }

    func testATechnicianGetsDiagnosticsAndDevicesWithNoExtraPage() throws {
        XCTAssertEqual(try row(.advancedSupport, in: technician(), on: personal).page, .category(.diagnostics))
        XCTAssertEqual(try row(.devicesPrivacy, in: technician(), on: personal).page, .category(.devices))
    }

    func testAOneCategoryRowUsesThatCategorysWords() throws {
        let voice = try row(.assistant, simpleMode: true, on: personal)
        XCTAssertEqual(voice.title, "Assistant")
        XCTAssertEqual(voice.subtitle, SettingsCatalog.category(.voice).subtitle)
        XCTAssertEqual(voice.summaryCategory, .voice)
        let full = try row(.assistant, on: personal)
        XCTAssertEqual(full.subtitle, SettingsHub.row(.assistant, on: personal).subtitle)
        XCTAssertEqual(full.summaryCategory, .intelligence)
    }

    func testAMergedRowShowsOnlyWhatIsVisibleInItsOwnOrder() throws {
        XCTAssertEqual(try row(.devicesPrivacy, on: personal).page, .merged([.devices, .capture, .display]))
        XCTAssertEqual(try row(.devicesPrivacy, on: noGlasses).page, .merged([.devices, .capture]))
        let captureOpen = technician(ManagedLockdown(opening: [.capture], locking: [], closedTools: []))
        XCTAssertEqual(try row(.devicesPrivacy, in: captureOpen, on: personal).page, .merged([.devices, .capture]))
        XCTAssertEqual(try row(.connections, on: personal).page, .merged([.connections, .tools]))
        XCTAssertEqual(try row(.assistant, on: personal).page, .merged([.intelligence, .voice]))
        XCTAssertEqual(try row(.advancedSupport, on: personal).page, .merged([.diagnostics, .advanced]))
    }

    func testEverydayAndFieldAssistOpenTheirOwnScreen() throws {
        XCTAssertEqual(try row(.everyday, on: personal).page, .category(.everyday))
        XCTAssertEqual(try row(.fieldAssist, on: fieldPhone).page, .category(.fieldAssist))
    }

    // MARK: - My Manuals

    func testMyManualsIsUnderFieldAssistOnAFieldAssistPhone() {
        XCTAssertEqual(Hub.home(of: .myManuals, on: fieldPhone), .fieldAssist)
        XCTAssertTrue(Hub.showsMyManuals(on: .fieldAssist, visible: visible(on: fieldPhone), phone: fieldPhone))
        XCTAssertFalse(Hub.showsMyManuals(on: .everyday, visible: visible(on: fieldPhone), phone: fieldPhone))
    }

    func testMyManualsIsInEverydayOnAPersonalPhone() {
        XCTAssertEqual(Hub.home(of: .myManuals, on: personal), .everyday)
        XCTAssertTrue(Hub.showsMyManuals(on: .everyday, visible: visible(on: personal), phone: personal))
        XCTAssertFalse(Hub.showsMyManuals(on: .fieldAssist, visible: visible(on: personal), phone: personal))
    }

    func testATechnicianIsNotOfferedMyManuals() {
        let opened = technician(ManagedLockdown(opening: [.myManuals, .everyday], locking: [], closedTools: []))
        for phone in [personal, fieldPhone] {
            XCTAssertFalse(visible(in: opened, on: phone).contains { $0.id == .myManuals })
            for host in [SettingsHubRowID.everyday, .fieldAssist] {
                XCTAssertFalse(Hub.showsMyManuals(on: host, visible: visible(in: opened, on: phone), phone: phone))
            }
        }
    }

    /// The Voice tab's "Add your first manual", which only a personal phone shows.
    func testTheVoiceTabsManualRouteStillLands() {
        XCTAssertEqual(Hub.route(.myManuals, visible: visible(on: personal)), .category(.myManuals))
        XCTAssertEqual(Hub.route(.myManuals, visible: visible(simpleMode: true, on: personal)), .category(.myManuals))
    }

    // MARK: - Things to Try

    func testThingsToTryIsTheFirstRowOfEveryday() {
        XCTAssertEqual(Hub.thingsToTryPlace(visible: visible(on: personal)), .everyday)
        XCTAssertEqual(Hub.thingsToTryPlace(visible: visible(on: fieldPhone)), .everyday)
        XCTAssertEqual(Hub.thingsToTryPlace(visible: visible(in: administrator(), on: personal)), .everyday)
    }

    func testThingsToTryStaysReachableWhereEverydayIsNot() {
        XCTAssertEqual(Hub.thingsToTryPlace(visible: visible(simpleMode: true, on: personal)), .besideAbout,
                       "the Everyday row can be drawn in Simple Mode, with only My Manuals behind it")
        XCTAssertEqual(Hub.thingsToTryPlace(visible: visible(in: technician(), on: personal)), .besideAbout)
    }

    // MARK: - Opening a category from elsewhere

    func testEveryCategoryOpensAsItselfWhereItIsVisible() {
        for phone in [personal, fieldPhone] {
            for id in SettingsCategoryID.allCases {
                XCTAssertEqual(Hub.route(id, visible: visible(on: phone)), .category(id), id.rawValue)
            }
        }
    }

    func testAShortcutDoesNotGetRoundSimpleModeOrALockdown() {
        let simple = visible(simpleMode: true, on: personal)
        for id in SettingsCategoryID.allCases {
            let expected: SettingsHub.Route = simple.contains { $0.id == id } ? .category(id) : .hub
            XCTAssertEqual(Hub.route(id, visible: simple), expected, id.rawValue)
        }
        XCTAssertEqual(Hub.route(.capture, visible: simple), .hub)
        XCTAssertEqual(Hub.route(.capture, visible: visible(in: technician(), on: personal)), .hub)
        XCTAssertEqual(Hub.route(.fieldAssist, visible: visible(in: technician(), on: personal)), .category(.fieldAssist))
    }
}
