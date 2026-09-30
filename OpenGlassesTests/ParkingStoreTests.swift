import CoreLocation
import XCTest
@testable import OpenGlasses

/// Plan GH P1 — one active spot, optional capped history, photos deleted with their spot, and the
/// at-rest posture the data-store registry claims.
@MainActor
final class ParkingStoreTests: XCTestCase {

    private var directory: URL!
    private var history = false
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParkingStoreTests_\(UUID().uuidString)", isDirectory: true)
        history = false
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore() -> ParkingStore {
        ParkingStore(directory: directory, keepHistory: { [unowned self] in self.history })
    }

    private func spot(_ level: String, ago: TimeInterval = 0) -> ParkingSpot {
        ParkingSpot(coordinate: .init(latitude: 1, longitude: 2), locationAt: now, level: level,
                    savedAt: now.addingTimeInterval(-ago), capture: .voice)
    }

    private let photo = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

    func testSavedSpotIsActiveAndSurvivesARelaunch() {
        let store = makeStore()
        store.save(spot("2"))
        XCTAssertEqual(store.active?.level, "2")
        XCTAssertEqual(makeStore().active?.level, "2")
    }

    func testWithHistoryOffAReplacedSpotAndItsPhotoAreDeleted() throws {
        let store = makeStore()
        let first = store.save(spot("1"), photo: photo)
        let firstPhoto = try XCTUnwrap(store.photoURL(for: first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPhoto.path))

        store.save(spot("2"))
        XCTAssertEqual(store.active?.level, "2")
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPhoto.path))
    }

    func testWithHistoryOnTheLastTenAreKeptAndOlderPhotosGo() throws {
        history = true
        let store = makeStore()
        let oldest = store.save(spot("0"), photo: photo)
        let oldestPhoto = try XCTUnwrap(store.photoURL(for: oldest))
        for level in 1...11 { store.save(spot("\(level)")) }

        XCTAssertEqual(store.active?.level, "11")
        XCTAssertEqual(store.history.count, ParkingStore.historyCap)
        XCTAssertEqual(store.history.first?.level, "10", "most recent first")
        XCTAssertFalse(store.history.contains { $0.level == "0" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldestPhoto.path))
    }

    func testClearForgetsTheSpotAndItsPhoto() throws {
        let store = makeStore()
        let saved = store.save(spot("3"), photo: photo)
        let url = try XCTUnwrap(store.photoURL(for: saved))
        store.clear()
        XCTAssertNil(store.active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(makeStore().active)
    }

    func testClearAllRemovesEverythingOnDisk() {
        history = true
        let store = makeStore()
        store.save(spot("1"), photo: photo)
        store.save(spot("2"), photo: photo)
        store.clearAll()
        XCTAssertNil(store.active)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(ParkingStore.fileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(ParkingStore.photoFolderName).path))
    }

    func testAttachingAPhotoReplacesTheOldOneAndMergesTheReading() throws {
        let store = makeStore()
        let saved = store.save(spot("2"), photo: photo)
        let oldURL = try XCTUnwrap(store.photoURL(for: saved))
        let updated = try XCTUnwrap(store.attachPhoto(photo, fields: ParkingFields(space: "41")))
        XCTAssertEqual(updated.level, "2")
        XCTAssertEqual(updated.space, "41")
        XCTAssertNotEqual(updated.photoFile, saved.photoFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
    }

    func testAnAutomaticSaveKeepsARecentManualSpot() {
        let store = makeStore()
        store.save(spot("2", ago: 60))
        let automatic = ParkingSpot(coordinate: .init(latitude: 9, longitude: 9), savedAt: now, capture: .motion)
        XCTAssertNil(store.saveAutomatic(automatic, now: now))
        XCTAssertEqual(store.active?.level, "2")
    }

    func testFilesAreExcludedFromBackupAndFirstUnlockProtected() throws {
        let store = makeStore()
        let saved = store.save(spot("2"), photo: photo)
        let urls = [directory.appendingPathComponent(ParkingStore.fileName), try XCTUnwrap(store.photoURL(for: saved))]
        for url in urls {
            let excluded = try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            XCTAssertEqual(excluded, true, "\(url.lastPathComponent) must be excluded from backup")
            // The simulator does not always report protection; assert it only where it answers.
            if let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
                as? FileProtectionType {
                XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
            }
        }
        let record = SensitiveStore.parkingSpots.record
        XCTAssertTrue(record.backupExcluded)
        XCTAssertEqual(record.protection, .completeUntilFirstUserAuthentication)
    }
}
