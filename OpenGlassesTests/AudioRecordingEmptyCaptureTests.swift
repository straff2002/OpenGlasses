import XCTest
@testable import OpenGlasses

/// A recording that holds no audio is not filed. The recorder writes the M4A container header as
/// soon as it starts, so a stop that follows at once, or a start whose input never delivered a
/// buffer, leaves a few-KB file behind that used to be protected, filed and offered to share.
@MainActor
final class AudioRecordingEmptyCaptureTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(bytes: Int) throws -> URL {
        let url = dir.appendingPathComponent("OG_Audio_\(bytes).m4a")
        try Data(count: bytes).write(to: url)
        return url
    }

    func testHeaderOnlyCaptureIsDiscardedAndDeleted() throws {
        let url = try file(bytes: AudioRecordingService.emptyCaptureByteCeiling)
        XCTAssertNil(AudioRecordingService.discardingEmptyCapture(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the empty file is removed")
    }

    func testRealCaptureIsKept() throws {
        let url = try file(bytes: AudioRecordingService.emptyCaptureByteCeiling + 1)
        XCTAssertEqual(AudioRecordingService.discardingEmptyCapture(url), url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testMissingFileIsNothingToFile() {
        XCTAssertNil(AudioRecordingService.discardingEmptyCapture(nil))
        XCTAssertNil(AudioRecordingService.discardingEmptyCapture(dir.appendingPathComponent("never-written.m4a")))
    }
}
