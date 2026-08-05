import XCTest
@testable import OpenGlasses

final class SavedNotesStoreTests: XCTestCase {
    private final class TrackingUserDefaults: UserDefaults {
        var savedNotesWriteCount = 0

        override func set(_ value: Any?, forKey defaultName: String) {
            if defaultName == SavedNotesStore.storageKey {
                savedNotesWriteCount += 1
            }
            super.set(value, forKey: defaultName)
        }
    }

    private var suiteName: String!
    private var defaults: TrackingUserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SavedNotesStoreTests-\(UUID().uuidString)"
        defaults = TrackingUserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMixedLegacyAndCanonicalNotesSurviveInOriginalOrder() {
        let canonical = [
            "title": "Meeting Summary — later",
            "content": "Canonical content",
            "date": "2026-07-27T09:00:00Z",
        ]
        defaults.set(["Legacy content", canonical], forKey: SavedNotesStore.storageKey)

        let notes = SavedNotesStore.load(defaults: defaults)

        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0]["content"], "Legacy content")
        XCTAssertEqual(notes[1], canonical)
    }

    func testLegacyWorkoutGetsCanonicalTitleContentAndDate() {
        defaults.set(
            ["[26 Jul 2026] Workout: ran 5k"],
            forKey: SavedNotesStore.storageKey
        )

        let note = SavedNotesStore.load(defaults: defaults)[0]

        XCTAssertTrue(note["title"]?.hasPrefix("Workout Note —") == true)
        XCTAssertEqual(note["content"], "ran 5k")
        XCTAssertNotNil(note["date"].flatMap { ISO8601DateFormatter().date(from: $0) })
    }

    func testMigrationWritesBackOnceAndCanonicalReadDoesNotRewrite() throws {
        let canonical = ["title": "Meeting Summary", "content": "Decision"]
        defaults.set(["Legacy content", canonical], forKey: SavedNotesStore.storageKey)
        defaults.savedNotesWriteCount = 0

        _ = SavedNotesStore.load(defaults: defaults)

        XCTAssertEqual(defaults.savedNotesWriteCount, 1)
        let migrated = try XCTUnwrap(defaults.array(forKey: SavedNotesStore.storageKey))
        XCTAssertTrue(migrated.allSatisfy { $0 is [String: String] })

        defaults.savedNotesWriteCount = 0
        let beforeSecondLoad = try XCTUnwrap(migrated as? [[String: String]])
        _ = SavedNotesStore.load(defaults: defaults)

        XCTAssertEqual(defaults.savedNotesWriteCount, 0)
        XCTAssertEqual(
            defaults.array(forKey: SavedNotesStore.storageKey) as? [[String: String]],
            beforeSecondLoad
        )
    }

    func testUnparseableLegacyStringIsPreservedAsContent() {
        let legacy = "[not a date] A legacy note that must survive"
        defaults.set([legacy], forKey: SavedNotesStore.storageKey)

        let notes = SavedNotesStore.load(defaults: defaults)

        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0]["content"], "A legacy note that must survive")
        XCTAssertEqual(notes[0]["title"], "A legacy note that must survive")
        XCTAssertNil(notes[0]["date"])
    }

    func testSaveCapsAtNewestFiftyEntries() {
        let notes = (0..<55).map { index in
            ["title": "Note \(index)", "content": "Content \(index)"]
        }

        SavedNotesStore.save(notes, defaults: defaults)
        let loaded = SavedNotesStore.load(defaults: defaults)

        XCTAssertEqual(loaded.count, 50)
        XCTAssertEqual(loaded.first?["title"], "Note 5")
        XCTAssertEqual(loaded.last?["title"], "Note 54")
    }

    /// The regression that motivated the store: the workout writer used to store a plain string
    /// array, so its next write after a meeting summary clobbered the dictionary-schema notes.
    func testAppendingWorkoutAfterMeetingPreservesMeetingSummary() {
        let meetingTitle = "Meeting Summary — 26/07/2026, 10:00"
        SavedNotesStore.append(
            title: meetingTitle,
            content: "Ship the data-loss fix",
            date: "2026-07-26T09:00:00Z",
            defaults: defaults
        )
        SavedNotesStore.append(
            title: "Workout Note — 26 Jul 2026",
            content: "ran 5k",
            date: "2026-07-26T10:00:00Z",
            defaults: defaults
        )

        let notes = SavedNotesStore.load(defaults: defaults)
        let meetings = SiriContentAdapters.meetingSummaries(rawSavedNotes: notes)

        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0]["title"], meetingTitle)
        XCTAssertTrue(notes[0]["title"]?.hasPrefix(SiriContentAdapters.meetingSummaryTitlePrefix) == true)
        XCTAssertEqual(meetings.count, 1)
        XCTAssertEqual(meetings[0].text, "Ship the data-loss fix")
    }
}
