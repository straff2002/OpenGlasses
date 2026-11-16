import XCTest
@testable import OpenGlasses

/// The watch's home screen: the phone's first grid tiles on the wrist, what a tap on one runs, and
/// the More items the wearer keeps on the main screen.
final class WatchHomeTests: XCTestCase {

    private let speedDial: [QuickAction] = [
        QuickAction(id: "lights", label: "Lights", icon: "lightbulb", type: .homeAssistant),
        QuickAction(id: "say-hi", label: "Hi", icon: "hand.wave", type: .prompt, promptText: "Say hi"),
        QuickAction(id: "fa-log-photo", label: "Log photo", icon: "camera", type: .prompt,
                    promptText: "Log this"),
    ]

    /// The grid's speed dial without the Field Assist tile, which leads the grid until the wearer
    /// places it (`DockSlot.leadsWhenUnplaced`) and would otherwise come first in every order.
    private var plainSpeedDial: [QuickAction] { Array(speedDial.prefix(2)) }

    private func slots(order: [String] = [], hidden: [String] = [],
                       quickActions: [QuickAction]? = nil) -> [DockSlot] {
        let arrangement = HomeGridArrangement(order: order, hidden: hidden)
        return DockGridCatalog.storedSlots(dockOrder: "",
                                           storedArrangement: HomeGridStore.encode(arrangement),
                                           quickActions: quickActions ?? plainSpeedDial,
                                           showsActions: true,
                                           restricted: false)
    }

    // MARK: - The tiles

    func testTheWatchGetsThePhonesActionTilesInThePhonesOrder() {
        let drawn = slots(order: ["builtin:weather", "control:camera", "quick:lights"])
        let phoneActions = drawn.compactMap { slot -> String? in
            if case .action(let entry) = slot { return entry.id }
            return nil
        }
        let tiles = WatchGridTiles.tiles(slots: drawn, photoBlocked: false)

        XCTAssertEqual(tiles.map(\.id), Array(phoneActions.prefix(WatchGridWire.limit)))
        XCTAssertEqual(Array(tiles.map(\.id).prefix(2)), ["builtin:weather", "quick:lights"])
        XCTAssertFalse(tiles.contains { $0.id.hasPrefix("control:") },
                       "the phone's controls work the phone's screen and stay there")
    }

    func testFourRowsOfThreeAtMost() {
        XCTAssertEqual(WatchGridWire.columns, 3)
        XCTAssertEqual(WatchGridWire.limit, 12)
        let tiles = WatchGridTiles.tiles(slots: slots(quickActions: speedDial), photoBlocked: false)
        XCTAssertEqual(tiles.count, 12, "the catalog has more than twelve; the wrist takes the first twelve")
    }

    func testAHiddenTileIsNotOnTheWatchEither() {
        let tiles = WatchGridTiles.tiles(slots: slots(hidden: ["builtin:meetings-today"]),
                                         photoBlocked: false)
        XCTAssertFalse(tiles.map(\.id).contains("builtin:meetings-today"))
    }

    func testMyManualsStaysOnThePhone() {
        let tiles = WatchGridTiles.tiles(slots: slots(order: ["quick:\(QuickAction.myManuals.id)"],
                                                      quickActions: plainSpeedDial + [.myManuals]),
                                         photoBlocked: false)
        XCTAssertFalse(tiles.map(\.id).contains("quick:\(QuickAction.myManuals.id)"))
    }

    func testPhotoTilesAreDimmedWhereThePhoneDimsThem() {
        let tiles = WatchGridTiles.tiles(slots: slots(order: ["builtin:scan-document", "builtin:weather"]),
                                         photoBlocked: true)
        XCTAssertEqual(tiles[0].id, "builtin:scan-document")
        XCTAssertTrue(tiles[0].takesPhoto)
        XCTAssertTrue(tiles[0].dimmed)
        XCTAssertFalse(tiles[1].dimmed)
    }

    func testAFieldAssistTileTheWearerHasNotPlacedLeadsOnTheWatchAsOnThePhone() {
        let tiles = WatchGridTiles.tiles(slots: slots(order: ["builtin:weather"], quickActions: speedDial),
                                         photoBlocked: false)
        XCTAssertEqual(tiles.first?.id, "quick:fa-log-photo")
    }

    func testTheTilesSurviveTheTrip() {
        let tiles = WatchGridTiles.tiles(slots: slots(), photoBlocked: true)
        XCTAssertEqual(WatchGridWire.decode(WatchGridWire.encode(tiles)), tiles)
    }

    func testAnOlderPhoneSendsNoTilesAndBadRowsAreDropped() {
        XCTAssertNil(WatchGridWire.decode(nil), "no key: the watch falls back to the old quick actions")
        let decoded = WatchGridWire.decode([
            ["id": "builtin:weather", "label": "Weather", "icon": ""],
            ["id": "", "label": "Blank"],
            ["label": "No id"],
        ])
        XCTAssertEqual(decoded?.map(\.id), ["builtin:weather"])
        XCTAssertEqual(decoded?.first?.icon, "star.fill")
        let many = (0..<30).map { ["id": "builtin:\($0)", "label": "\($0)"] }
        XCTAssertEqual(WatchGridWire.decode(many)?.count, WatchGridWire.limit)
    }

    // MARK: - A tap

    private func route(_ id: String?, photoBlocked: Bool = false,
                       glassesConnected: Bool = true) -> WatchGridTiles.Route {
        WatchGridTiles.route(entryId: id, quickActions: speedDial + [.myManuals],
                             photoBlocked: photoBlocked, glassesConnected: glassesConnected)
    }

    func testABuiltInAsksItsOwnQuestion() {
        XCTAssertEqual(route("builtin:weather"), .textTurn(prompt: HomeGridAction.weather.prompt))
        XCTAssertEqual(route("builtin:scan-document"),
                       .photoTurn(prompt: HomeGridAction.scanDocument.prompt))
    }

    /// The old watch path took a photo for a text quick action and asked its label.
    func testASpeedDialPromptIsRunAsThePhoneRunsItNotAsAPhoto() {
        XCTAssertEqual(route("quick:say-hi"), .quickAction(speedDial[1]))
        XCTAssertEqual(route("quick:lights"), .quickAction(speedDial[0]))
    }

    func testTheWristNeverOpensThePhonesCamera() {
        XCTAssertEqual(route("quick:fa-log-photo", glassesConnected: true), .quickAction(speedDial[2]))
        guard case .refused = route("quick:fa-log-photo", glassesConnected: false) else {
            return XCTFail("a tile that opens the phone's camera first ran from the wrist")
        }
    }

    func testWhatCannotRunIsRefusedInWords() {
        for id in [nil, "builtin:gone", "quick:\(QuickAction.myManuals.id)"] {
            guard case .refused(let reason) = route(id) else { return XCTFail("\(String(describing: id)) ran") }
            XCTAssertFalse(reason.isEmpty)
        }
        guard case .refused = route("builtin:read-text", photoBlocked: true) else {
            return XCTFail("a photo tile ran while the model cannot see")
        }
    }

    func testTheTapIsAKnownCommand() {
        XCTAssertNotNil(WatchConnectivityManager.commandToken(WatchGridWire.command))
        XCTAssertEqual(WatchGridWire.message(tileId: "builtin:weather")["entry_id"] as? String,
                       "builtin:weather")
    }

    // MARK: - More pins

    func testPinningAddsAndUnpinningRemoves() {
        var stored = ""
        stored = WatchMorePins.toggling(.connection, in: stored)
        stored = WatchMorePins.toggling(.persona(id: "chef"), in: stored)
        XCTAssertEqual(WatchMorePins.decode(stored), [.connection, .persona(id: "chef")])
        stored = WatchMorePins.toggling(.connection, in: stored)
        XCTAssertEqual(WatchMorePins.decode(stored), [.persona(id: "chef")])
    }

    func testUnknownAndRepeatedPinsAreDropped() {
        XCTAssertEqual(WatchMorePins.decode("private,future-thing,private,persona:,connection"),
                       [.privateConversation, .connection])
    }

    func testAPinnedPersonaThePhoneNoLongerOffersWaits() {
        let stored = WatchMorePins.encode([.persona(id: "chef"), .privateConversation])
        XCTAssertEqual(WatchMorePins.shown(stored, personaIds: []), [.privateConversation])
        XCTAssertEqual(WatchMorePins.shown(stored, personaIds: ["chef"]),
                       [.persona(id: "chef"), .privateConversation])
    }
}
