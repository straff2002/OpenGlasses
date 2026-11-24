import XCTest
@testable import OpenGlasses

/// Plan NE P2 — pins: at most eight, no duplicates, unknown ids dropped, kept while hidden, and
/// stored as a list of ids in the defaults they are given.
final class SettingsPinsTests: XCTestCase {

    private let ids = SettingsIndexTests.pinnedIDs

    // MARK: - The value

    func testAtMostEightPins() {
        var pins = SettingsPins()
        for id in ids.prefix(SettingsPins.limit) { XCTAssertTrue(pins.pin(id)) }
        XCTAssertTrue(pins.isFull)
        XCTAssertFalse(pins.pin(ids[20]), "a ninth pin is refused")
        XCTAssertEqual(pins.ids, Array(ids.prefix(8)))
        XCTAssertEqual(SettingsPins(ids: Array(ids.prefix(12))).ids, Array(ids.prefix(8)))
    }

    func testDuplicatesAndUnknownIdsAreDroppedOnRead() {
        let read = SettingsPins(ids: ["theme", "theme", "gone-since", "microphone", "theme"])
        XCTAssertEqual(read.ids, ["theme", "microphone"])
        var pins = read
        XCTAssertFalse(pins.pin("theme"), "already pinned")
        XCTAssertFalse(pins.pin("no-such-entry"))
        XCTAssertEqual(pins.ids, ["theme", "microphone"])
    }

    func testToggleAndUnpin() {
        var pins = SettingsPins()
        pins.toggle("theme")
        XCTAssertTrue(pins.contains("theme"))
        pins.toggle("theme")
        XCTAssertFalse(pins.contains("theme"))
        pins.pin("theme")
        pins.pin("microphone")
        pins.unpin("theme")
        XCTAssertEqual(pins.ids, ["microphone"])
    }

    func testMoveUpAndDown() {
        var pins = SettingsPins(ids: ["theme", "microphone", "glasses"])
        pins.move(up: "glasses")
        XCTAssertEqual(pins.ids, ["theme", "glasses", "microphone"])
        pins.move(down: "theme")
        XCTAssertEqual(pins.ids, ["glasses", "theme", "microphone"])
        pins.move(up: "glasses")
        pins.move(down: "microphone")
        XCTAssertEqual(pins.ids, ["glasses", "theme", "microphone"], "the ends do not move")
        XCTAssertFalse(pins.canMove(up: "glasses", among: pins.ids))
        XCTAssertTrue(pins.canMove(down: "glasses", among: pins.ids))
        XCTAssertFalse(pins.canMove(down: "microphone", among: pins.ids))
    }

    /// A move passes the next pin that is drawn, not one kept while hidden.
    func testAMovePassesTheNextVisiblePin() {
        var pins = SettingsPins(ids: ["theme", "agentic-features", "microphone"])
        pins.move(up: "microphone", among: ["theme", "microphone"])
        XCTAssertEqual(pins.ids, ["microphone", "agentic-features", "theme"])
    }

    // MARK: - What is drawn

    func testAHiddenPinIsKeptAndNotDrawn() {
        let pins = SettingsPins(ids: ["agentic-features", "theme", "blur-bystander-faces"])
        let hidesAgentMode = SettingsSearchConditions(context: SettingsIndexTests.ceilingsOnly)
        XCTAssertEqual(pins.visible(in: hidesAgentMode).map(\.id), ["theme", "blur-bystander-faces"])
        XCTAssertEqual(pins.ids.count, 3, "kept while hidden")
        XCTAssertEqual(pins.visible(in: SettingsSearchConditions()).map(\.id),
                       ["agentic-features", "theme", "blur-bystander-faces"], "and back, in pin order")
        let technician = SettingsSearchConditions(context: SettingsIndexTests.technician())
        XCTAssertEqual(pins.visible(in: technician).map(\.id), ["theme"])
        XCTAssertEqual(pins.visible(in: SettingsSearchConditions(simpleMode: true)).map(\.id),
                       ["theme", "blur-bystander-faces"])
    }

    // MARK: - The store

    func testTheStoreRoundTripsInItsOwnSuite() throws {
        let suite = "SettingsPinsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsPinStore(defaults: defaults)

        XCTAssertEqual(store.load(), SettingsPins(), "nothing pinned to begin with")
        var pins = SettingsPins()
        pins.pin("theme")
        pins.pin("microphone")
        store.save(pins)
        XCTAssertEqual(defaults.stringArray(forKey: "settingsPinnedEntries"), ["theme", "microphone"])
        XCTAssertEqual(store.load(), pins)

        // What another version wrote is cleaned as it is read.
        defaults.set(["microphone", "removed-entry", "microphone", "theme"], forKey: SettingsPinStore.key)
        XCTAssertEqual(store.load().ids, ["microphone", "theme"])
    }
}
