import XCTest
@testable import OpenGlasses

/// A finished recording used to sit in `tmp/` until someone opted into saving it — the AI-tool
/// path did, the UI path didn't, so dismissing the share sheet threw an hour of footage away.
/// These cover the filer that made persistence unconditional: the naming, the collision rule that
/// stops one recording overwriting another, the ordering that keeps the app-folder copy safe from
/// a failing Photos save, and the plain-words reporting of what did and didn't land.
final class RecordingFilerTests: XCTestCase {

    private var root: URL!
    private var recordings: URL!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingFilerTests-\(UUID().uuidString)")
        recordings = root.appendingPathComponent("Recordings")
        temporaryDirectory = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private let utc = TimeZone(identifier: "UTC")!

    /// "yyyy-MM-dd HH:mm:ss" in UTC, so the expected file names below are exact.
    private func date(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: iso)!
    }

    @discardableResult
    private func makeSourceFile(named name: String = "OpenGlasses_1.mp4",
                                contents: String = "video") throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Ops that fail exactly where a test asks them to; everything else goes to the real thing.
    private final class FailingOps: RecordingFileOperating {
        var failMove = false
        var failCopy = false
        var failCreateDirectory: Set<String> = []
        private let real = RecordingFileManagerOperations()

        struct Failure: Error {}

        func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }

        func createDirectory(at url: URL) throws {
            if failCreateDirectory.contains(url.lastPathComponent) { throw Failure() }
            try real.createDirectory(at: url)
        }

        func moveItem(at source: URL, to destination: URL) throws {
            if failMove { throw Failure() }
            try real.moveItem(at: source, to: destination)
        }

        func copyItem(at source: URL, to destination: URL) throws {
            if failCopy { throw Failure() }
            try real.copyItem(at: source, to: destination)
        }
    }

    // MARK: - Naming

    func testFileNameIsTimestampedAndKeepsTheExtension() {
        let name = RecordingFiler.fileName(for: date("2026-08-24 14:30:12"),
                                           fileExtension: "mp4", timeZone: utc)
        XCTAssertEqual(name, "Recording_2026-08-24_143012.mp4")
    }

    func testFileNameSortsChronologicallyAsText() {
        let earlier = RecordingFiler.fileName(for: date("2026-08-24 09:05:00"),
                                              fileExtension: "mp4", timeZone: utc)
        let later = RecordingFiler.fileName(for: date("2026-08-24 14:30:12"),
                                            fileExtension: "mp4", timeZone: utc)
        XCTAssertLessThan(earlier, later)
    }

    func testFileNameToleratesAnExtensionlessSource() {
        let name = RecordingFiler.fileName(for: date("2026-08-24 14:30:12"),
                                           fileExtension: "", timeZone: utc)
        XCTAssertEqual(name, "Recording_2026-08-24_143012")
    }

    // MARK: - Collisions

    func testUniqueURLReturnsTheBaseWhenNothingIsThere() {
        let base = recordings.appendingPathComponent("Recording_2026-08-24_143012.mp4")
        XCTAssertEqual(RecordingFiler.uniqueURL(base: base, exists: { _ in false }), base)
    }

    func testUniqueURLStepsPastAnExistingFile() {
        let base = recordings.appendingPathComponent("Recording_2026-08-24_143012.mp4")
        let taken: Set<String> = [base.path]
        let unique = RecordingFiler.uniqueURL(base: base, exists: { taken.contains($0.path) })
        XCTAssertEqual(unique.lastPathComponent, "Recording_2026-08-24_143012-2.mp4")
    }

    func testUniqueURLKeepsStepping() {
        let base = recordings.appendingPathComponent("Recording_2026-08-24_143012.mp4")
        let taken: Set<String> = [
            base.path,
            recordings.appendingPathComponent("Recording_2026-08-24_143012-2.mp4").path,
            recordings.appendingPathComponent("Recording_2026-08-24_143012-3.mp4").path
        ]
        let unique = RecordingFiler.uniqueURL(base: base, exists: { taken.contains($0.path) })
        XCTAssertEqual(unique.lastPathComponent, "Recording_2026-08-24_143012-4.mp4")
    }

    func testTwoRecordingsFinishingInTheSameSecondBothSurvive() throws {
        let filer = RecordingFiler(recordingsDirectory: recordings)
        let when = date("2026-08-24 14:30:12")

        let first = try makeSourceFile(named: "first.mp4", contents: "first")
        let firstOutcome = filer.file(first, date: when, saveToPhotos: false)

        let second = try makeSourceFile(named: "second.mp4", contents: "second")
        let secondOutcome = filer.file(second, date: when, saveToPhotos: false)

        XCTAssertNotEqual(firstOutcome.primaryURL, secondOutcome.primaryURL)
        XCTAssertEqual(try String(contentsOf: firstOutcome.primaryURL, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: secondOutcome.primaryURL, encoding: .utf8), "second")
    }

    // MARK: - Filing

    func testFilingMovesTheRecordingOutOfTemporaryStorage() throws {
        let source = try makeSourceFile()
        let filer = RecordingFiler(recordingsDirectory: recordings)

        let outcome = filer.file(source, date: date("2026-08-24 14:30:12"), saveToPhotos: false)

        XCTAssertTrue(outcome.savedToLibrary)
        XCTAssertTrue(outcome.isPersisted)
        XCTAssertEqual(outcome.primaryURL.deletingLastPathComponent().path, recordings.path)
        XCTAssertTrue(exists(outcome.primaryURL))
        // The whole point: nothing is left behind in the directory iOS is free to empty.
        XCTAssertFalse(exists(source))
    }

    func testFilingCreatesTheRecordingsDirectory() throws {
        XCTAssertFalse(exists(recordings))
        let source = try makeSourceFile()
        let filer = RecordingFiler(recordingsDirectory: recordings)

        _ = filer.file(source, date: date("2026-08-24 14:30:12"), saveToPhotos: false)

        XCTAssertTrue(exists(recordings))
    }

    func testChosenFolderGetsACopyAndTheAppFolderKeepsTheOriginal() throws {
        let folder = root.appendingPathComponent("Chosen")
        let source = try makeSourceFile(contents: "footage")
        let filer = RecordingFiler(recordingsDirectory: recordings, folderURL: folder)

        let outcome = filer.file(source, date: date("2026-08-24 14:30:12"), saveToPhotos: false)

        let copyURL = try XCTUnwrap(outcome.folderCopyURL)
        XCTAssertEqual(copyURL.deletingLastPathComponent().path, folder.path)
        XCTAssertEqual(try String(contentsOf: copyURL, encoding: .utf8), "footage")
        // A copy, not a move — the app folder stays the location we can always find again.
        XCTAssertTrue(outcome.savedToLibrary)
        XCTAssertTrue(exists(outcome.primaryURL))
        XCTAssertEqual(outcome.primaryURL.deletingLastPathComponent().path, recordings.path)
    }

    func testNoFolderConfiguredMeansNoCopyAndNothingReported() throws {
        let source = try makeSourceFile()
        let filer = RecordingFiler(recordingsDirectory: recordings)

        let outcome = filer.file(source, date: date("2026-08-24 14:30:12"), saveToPhotos: false)

        XCTAssertFalse(outcome.folderRequested)
        XCTAssertNil(outcome.folderCopyURL)
        XCTAssertNil(outcome.message)
    }

    // MARK: - Failure is never data loss

    func testAFailedMoveLeavesTheRecordingWhereItIs() throws {
        let source = try makeSourceFile()
        let ops = FailingOps()
        ops.failMove = true
        let filer = RecordingFiler(recordingsDirectory: recordings, ops: ops)

        let outcome = filer.file(source, date: date("2026-08-24 14:30:12"), saveToPhotos: false)

        XCTAssertFalse(outcome.savedToLibrary)
        XCTAssertFalse(outcome.isPersisted)
        // Never deleted, whatever else went wrong.
        XCTAssertEqual(outcome.primaryURL, source)
        XCTAssertTrue(exists(source))
        XCTAssertEqual(outcome.message,
                       "The recording could not be saved anywhere — it is still in temporary "
                       + "storage and may not survive. Free up some space and try again.")
    }

    func testAFailedMoveStillCopiesToTheChosenFolder() throws {
        let folder = root.appendingPathComponent("Chosen")
        let source = try makeSourceFile(contents: "footage")
        let ops = FailingOps()
        ops.failMove = true
        let filer = RecordingFiler(recordingsDirectory: recordings, folderURL: folder, ops: ops)

        let outcome = filer.file(source, date: date("2026-08-24 14:30:12"), saveToPhotos: false)

        XCTAssertFalse(outcome.savedToLibrary)
        XCTAssertTrue(outcome.isPersisted)
        // With the app folder unavailable, the surviving copy becomes the one we hand back.
        XCTAssertEqual(outcome.primaryURL, outcome.folderCopyURL)
        XCTAssertEqual(try String(contentsOf: outcome.primaryURL, encoding: .utf8), "footage")
        XCTAssertNil(outcome.message)
    }

    func testAFailedFolderCopyStillLeavesTheAppFolderCopy() throws {
        let folder = root.appendingPathComponent("Chosen")
        let source = try makeSourceFile()
        let ops = FailingOps()
        ops.failCopy = true
        let filer = RecordingFiler(recordingsDirectory: recordings, folderURL: folder, ops: ops)

        let outcome = filer.file(source, date: date("2026-08-24 14:30:12"), saveToPhotos: false)

        XCTAssertTrue(outcome.savedToLibrary)
        XCTAssertNil(outcome.folderCopyURL)
        XCTAssertTrue(outcome.isPersisted)
        XCTAssertEqual(outcome.message,
                       "Couldn't copy the recording to your chosen folder. The recording is safe "
                       + "in the app's Recordings folder — nothing was lost.")
    }

    /// With the app-folder move failed too, the note must name the copy that actually exists —
    /// calling the user's own folder "the app's" would send them looking in the wrong place.
    func testAFailedMoveAndFailedPhotosNameTheChosenFolder() throws {
        let folder = root.appendingPathComponent("Chosen")
        let source = try makeSourceFile()
        let ops = FailingOps()
        ops.failMove = true
        let filer = RecordingFiler(recordingsDirectory: recordings, folderURL: folder, ops: ops)

        var outcome = filer.file(source, date: date("2026-08-24 14:30:12"), saveToPhotos: true)
        outcome.savedToPhotos = false

        XCTAssertEqual(outcome.message,
                       "Couldn't save the recording to Photos. The recording is safe in "
                       + "your chosen folder — nothing was lost.")
    }

    func testAnUnreachableChosenFolderIsNotFatal() throws {
        let folder = root.appendingPathComponent("Chosen")
        let source = try makeSourceFile()
        let ops = FailingOps()
        ops.failCreateDirectory = ["Chosen"]
        let filer = RecordingFiler(recordingsDirectory: recordings, folderURL: folder, ops: ops)

        let outcome = filer.file(source, date: date("2026-08-24 14:30:12"), saveToPhotos: false)

        XCTAssertTrue(outcome.savedToLibrary)
        XCTAssertNil(outcome.folderCopyURL)
        XCTAssertTrue(outcome.isPersisted)
    }

    // MARK: - Photos is the caller's step, and an optional one

    func testPhotosIsNotAttemptedByTheFilerItself() throws {
        let source = try makeSourceFile()
        let filer = RecordingFiler(recordingsDirectory: recordings)

        let outcome = filer.file(source, date: date("2026-08-24 14:30:12"), saveToPhotos: true)

        // The filer only records that it was asked for — the save itself happens at the edge,
        // after the file is already safe on disk.
        XCTAssertTrue(outcome.photosRequested)
        XCTAssertFalse(outcome.savedToPhotos)
        XCTAssertTrue(outcome.savedToLibrary)
    }

    func testADeclinedPhotosSaveNamesTheSafetyNet() throws {
        let source = try makeSourceFile()
        let filer = RecordingFiler(recordingsDirectory: recordings)

        var outcome = filer.file(source, date: date("2026-08-24 14:30:12"), saveToPhotos: true)
        outcome.savedToPhotos = false   // permission denied, or the change request failed

        XCTAssertEqual(outcome.message,
                       "Couldn't save the recording to Photos. The recording is safe in "
                       + "the app's Recordings folder — nothing was lost.")
    }

    func testEverythingLandingSaysNothing() throws {
        let folder = root.appendingPathComponent("Chosen")
        let source = try makeSourceFile()
        let filer = RecordingFiler(recordingsDirectory: recordings, folderURL: folder)

        var outcome = filer.file(source, date: date("2026-08-24 14:30:12"), saveToPhotos: true)
        outcome.savedToPhotos = true

        XCTAssertNil(outcome.message)
    }

    // MARK: - Summary wording

    private func outcome(library: Bool, photos: Bool, folder: Bool) -> RecordingFiler.Outcome {
        RecordingFiler.Outcome(
            primaryURL: recordings.appendingPathComponent("Recording_2026-08-24_143012.mp4"),
            savedToLibrary: library,
            photosRequested: photos,
            savedToPhotos: photos,
            folderRequested: folder,
            folderCopyURL: folder ? root.appendingPathComponent("Chosen/x.mp4") : nil)
    }

    func testSummaryNamesOneDestination() {
        XCTAssertEqual(outcome(library: true, photos: false, folder: false).summary,
                       "Saved to the app's Recordings folder.")
    }

    func testSummaryNamesTwoDestinations() {
        XCTAssertEqual(outcome(library: true, photos: true, folder: false).summary,
                       "Saved to the app's Recordings folder and the Glasses album in Photos.")
    }

    func testSummaryNamesThreeDestinations() {
        XCTAssertEqual(outcome(library: true, photos: true, folder: true).summary,
                       "Saved to the app's Recordings folder, the Glasses album in Photos "
                       + "and your chosen folder.")
    }

    func testSummaryIsHonestWhenNothingLanded() {
        XCTAssertEqual(outcome(library: false, photos: false, folder: false).summary,
                       "The recording is still in temporary storage — it was not saved.")
    }
}
