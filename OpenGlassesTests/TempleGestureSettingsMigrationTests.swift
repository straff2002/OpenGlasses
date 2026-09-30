import XCTest
@testable import OpenGlasses

/// Plan GJ P1: the gesture map's persistence and the one-time carry-over from the single-gesture
/// temple tap. Every test uses its own defaults suite — never `.standard`.
final class TempleGestureSettingsMigrationTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TempleGestureSettingsMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Map persistence

    func testEmptyStoreLoadsTheDefaults() {
        let map = TempleGestureMapStore(defaults: defaults).load()
        XCTAssertEqual(map, .defaults)
        XCTAssertEqual(map.one, .startTalking)
        XCTAssertEqual(map.two, .hangUp)
        XCTAssertEqual(map.three, .mute)
    }

    func testRoundTripIncludingQuickActions() {
        let store = TempleGestureMapStore(defaults: defaults)
        let map = TempleGestureMap(one: .photoDescribe, two: .quickAction("qa-42"), three: .nothing)
        store.save(map)
        XCTAssertEqual(store.load(), map)
    }

    func testUnknownRawValueReadsAsNothing() {
        defaults.set("teleport", forKey: TempleGestureMapStore.key(for: .one))
        defaults.set("quickAction:", forKey: TempleGestureMapStore.key(for: .two))
        let map = TempleGestureMapStore(defaults: defaults).load()
        XCTAssertEqual(map.one, .nothing)
        XCTAssertEqual(map.two, .nothing)
        XCTAssertEqual(map.three, .mute)   // missing key → that tap's default
    }

    func testEveryBuiltInRoundTripsThroughItsRawValue() {
        for action in TempleAction.builtIns {
            XCTAssertEqual(TempleAction(rawValue: action.rawValue), action)
        }
        XCTAssertEqual(TempleAction(rawValue: "quickAction:abc"), .quickAction("abc"))
    }

    // MARK: - Migration

    func testLegacyUserKeepsDoubleTapToTalk() {
        defaults.set(true, forKey: "mediaTriggerEnabled")
        XCTAssertEqual(TempleGestureSettingsMigration.run(defaults: defaults), .keptDoubleTapToTalk)
        let map = TempleGestureMapStore(defaults: defaults).load()
        XCTAssertEqual(map, .legacyDoubleTapToTalk)
        // …and under the calibration in force, "two taps" is the next-track command the old
        // trigger listened for, so the gesture they learned still starts a conversation.
        let calibration = TempleCalibration.current
        XCTAssertEqual(calibration.gesture(for: .nextTrack), .two)
        XCTAssertEqual(map.action(for: .two), .startTalking)
        // The taps that did nothing before still do nothing.
        XCTAssertEqual(map.action(for: .one), .nothing)
        XCTAssertEqual(map.action(for: .three), .nothing)
        // The switch itself is untouched: on stays on.
        XCTAssertTrue(defaults.bool(forKey: "mediaTriggerEnabled"))
    }

    func testNewUserGetsTheDefaults() {
        XCTAssertEqual(TempleGestureSettingsMigration.run(defaults: defaults), .defaultsApply)
        XCTAssertEqual(TempleGestureMapStore(defaults: defaults).load(), .defaults)
        XCTAssertFalse(TempleGestureMapStore(defaults: defaults).hasStoredMap)
    }

    func testUserWhoSwitchedItOffGetsTheDefaults() {
        defaults.set(false, forKey: "mediaTriggerEnabled")
        XCTAssertEqual(TempleGestureSettingsMigration.run(defaults: defaults), .defaultsApply)
        XCTAssertEqual(TempleGestureMapStore(defaults: defaults).load(), .defaults)
    }

    func testRunsOnlyOnce() {
        defaults.set(true, forKey: "mediaTriggerEnabled")
        TempleGestureSettingsMigration.run(defaults: defaults)
        // The wearer remaps afterwards; a second launch must not put the legacy map back.
        TempleGestureMapStore(defaults: defaults).save(.defaults)
        XCTAssertEqual(TempleGestureSettingsMigration.run(defaults: defaults), .alreadyDone)
        XCTAssertEqual(TempleGestureMapStore(defaults: defaults).load(), .defaults)
    }

    func testNeverOverwritesAStoredMap() {
        defaults.set(true, forKey: "mediaTriggerEnabled")
        let chosen = TempleGestureMap(one: .readDigest, two: .startTalking, three: .hangUp)
        TempleGestureMapStore(defaults: defaults).save(chosen)
        XCTAssertEqual(TempleGestureSettingsMigration.run(defaults: defaults), .defaultsApply)
        XCTAssertEqual(TempleGestureMapStore(defaults: defaults).load(), chosen)
    }
}
