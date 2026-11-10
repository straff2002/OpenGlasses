import AVFoundation
import XCTest
@testable import OpenGlasses

/// Instant Replay — one small real encode: two tiny segments written by the real segment writer,
/// joined by the real passthrough composer, and the result opened as video. Small frames and a
/// second of video, so it stays fast and deterministic on the simulator.
@MainActor
final class ReplayRealEncodeTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplayRealEncodeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func frame(_ shade: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { context in
            UIColor(white: shade, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    private func writeSegment(_ name: String, frames: Int) async throws -> URL {
        let url = root.appendingPathComponent(name)
        let writer = try AVReplaySegmentWriter(url: url, size: CGSize(width: 64, height: 64), frameRate: 15)
        for i in 0..<frames {
            writer.append(frame(CGFloat(i % 10) / 10), at: Double(i) / 15)
        }
        let finished = await writer.finish()
        XCTAssertTrue(finished, "\(name) did not finish")
        return url
    }

    func testTwoSegmentsJoinPassthroughIntoOnePlayableClip() async throws {
        let first = try await writeSegment("segment-000001.mp4", frames: 8)
        let second = try await writeSegment("segment-000002.mp4", frames: 8)
        let output = root.appendingPathComponent("clip.mp4")
        let duration = try await AVReplayClipComposer().compose([first, second], to: output)
        XCTAssertGreaterThan(duration, 0.6)
        XCTAssertLessThan(duration, 1.5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let audio = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty, "a replay is silent")
        // Both segments survive the composition: they are read, never moved.
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
}
