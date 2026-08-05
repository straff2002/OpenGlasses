import UIKit
import XCTest
@testable import OpenGlasses

/// End-to-end session tests for the live fingerspelling surface (Plan CK activation):
/// fresh service instances driven through the injectable dependency seam with synthetic
/// frames — no MediaPipe, no Core ML, no CameraService, no `Wearables`.
@MainActor
final class FingerspellingSessionServiceTests: XCTestCase {

    // MARK: - Stubs

    /// Maps every incoming image to the next scripted holistic frame (cycling), recording
    /// timestamps. Called on the pipeline actor — guarded by a lock.
    private final class StubLandmarks: HolisticLandmarkProviding, @unchecked Sendable {
        private let lock = NSLock()
        private let script: [HolisticFrame]
        private var index = 0
        private(set) var timestamps: [Int] = []

        init(script: [HolisticFrame]) {
            precondition(!script.isEmpty)
            self.script = script
        }

        func holisticFrame(for image: UIImage,
                           timestampMilliseconds: Int) throws -> HolisticFrame {
            lock.lock()
            defer { lock.unlock() }
            timestamps.append(timestampMilliseconds)
            let frame = script[min(index, script.count - 1)]
            index += 1
            return frame
        }

        var recordedTimestamps: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return timestamps
        }
    }

    private final class Recorder {
        var spoken: [String] = []
        var captions: [String] = []
        var cleared = 0
    }

    // MARK: - Helpers

    private func presentFrame(_ value: Float = 0.5) -> HolisticFrame {
        HolisticFrame(timestamp: 0,
                      points: Array(repeating: SIMD3(value, value, 0),
                                    count: HolisticLayout.landmarkCount))
    }

    private var allNaNFrame: HolisticFrame {
        HolisticFrame(timestamp: 0,
                      points: Array(repeating: SIMD3(x: .nan, y: .nan, z: .nan),
                                    count: HolisticLayout.landmarkCount))
    }

    private func logitRow(_ letter: Character?) -> [Float] {
        var row = [Float](repeating: 0, count: 62)
        if let letter, let index = FingerspellingCTCDecoder.charset.firstIndex(of: letter) {
            row[index + 1] = 12
        } else {
            row[FingerspellingCTCDecoder.blankClass] = 12
        }
        return row
    }

    /// Inference stub emitting the scripted per-row letters, blanks beyond.
    private func inference(_ letters: [Character?]) -> FingerspellingLiveDecoder.Inference {
        { input in
            let validRows = (input.frameCount + 1) / 2
            return (0..<max(validRows, letters.count)).map { row in
                self.logitRow(row < letters.count ? letters[row] : nil)
            }
        }
    }

    private func dependencies(landmarks: StubLandmarks,
                              letters: [Character?],
                              recorder: Recorder) -> FingerspellingSessionService.Dependencies {
        FingerspellingSessionService.Dependencies(
            landmarks: landmarks,
            inference: inference(letters),
            speak: { recorder.spoken.append($0) },
            showCaption: { recorder.captions.append($0) },
            clearCaption: { recorder.cleared += 1 })
    }

    private func waitUntil(timeout: TimeInterval = 3,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Tests

    func testFramesProduceProvisionalWordAndCaption() async {
        let service = FingerspellingSessionService()
        let landmarks = StubLandmarks(script: [presentFrame()])
        let recorder = Recorder()
        service.start(dependencies: dependencies(landmarks: landmarks,
                                                 letters: ["h", nil, "i"],
                                                 recorder: recorder),
                      decodeEveryFrames: 6, frameBufferLimit: nil)

        for _ in 0..<6 { service.ingest(image: UIImage()) }
        await waitUntil { service.provisionalWord == "hi" }
        XCTAssertEqual(recorder.captions, ["h", "hi"])
        XCTAssertTrue(recorder.spoken.isEmpty)
        service.stop()
    }

    func testGapCommitsAndSpeaksWord() async {
        let service = FingerspellingSessionService()
        // 4 present frames (2 decode rows spelling "ok"), then all-NaN frames whose blank
        // observations accrue the word gap.
        let landmarks = StubLandmarks(
            script: Array(repeating: presentFrame(), count: 4)
                + Array(repeating: allNaNFrame, count: 12))
        let recorder = Recorder()
        service.start(dependencies: dependencies(landmarks: landmarks,
                                                 letters: ["o", "k"],
                                                 recorder: recorder),
                      decodeEveryFrames: 4, frameBufferLimit: nil)

        for _ in 0..<16 { service.ingest(image: UIImage()) }
        await waitUntil { recorder.spoken == ["ok"] }
        XCTAssertEqual(service.lastCommittedWord, "ok")
        XCTAssertEqual(service.provisionalWord, "")
        service.stop()
    }

    func testStopFlushesPendingWordAndClearsCaption() async {
        let service = FingerspellingSessionService()
        let landmarks = StubLandmarks(script: [presentFrame()])
        let recorder = Recorder()
        service.start(dependencies: dependencies(landmarks: landmarks,
                                                 letters: ["h", "i"],
                                                 recorder: recorder),
                      decodeEveryFrames: 4, frameBufferLimit: nil)

        for _ in 0..<4 { service.ingest(image: UIImage()) }
        await waitUntil { service.provisionalWord == "hi" }

        service.stop()
        await waitUntil { recorder.spoken == ["hi"] && recorder.cleared == 1 }
        XCTAssertFalse(service.isActive)
        XCTAssertEqual(service.provisionalWord, "")
    }

    func testTimestampsAreStrictlyIncreasing() async {
        let service = FingerspellingSessionService()
        let landmarks = StubLandmarks(script: [presentFrame()])
        let recorder = Recorder()
        service.start(dependencies: dependencies(landmarks: landmarks,
                                                 letters: [],
                                                 recorder: recorder),
                      decodeEveryFrames: 100, frameBufferLimit: nil)

        for _ in 0..<8 { service.ingest(image: UIImage()) }
        await waitUntil { landmarks.recordedTimestamps.count == 8 }
        let timestamps = landmarks.recordedTimestamps
        XCTAssertEqual(timestamps, timestamps.sorted())
        XCTAssertEqual(Set(timestamps).count, timestamps.count, "must be strictly increasing")
        service.stop()
    }

    func testIngestIsIgnoredWhenInactive() {
        let service = FingerspellingSessionService()
        service.ingest(image: UIImage()) // must be a no-op, not a crash
        XCTAssertFalse(service.isActive)
        XCTAssertEqual(service.provisionalWord, "")
    }

    func testExtractionFailureSurfacesStatusDetail() async {
        final class FailingLandmarks: HolisticLandmarkProviding, @unchecked Sendable {
            struct Failure: LocalizedError {
                var errorDescription: String? { "graph not loaded" }
            }
            func holisticFrame(for image: UIImage,
                               timestampMilliseconds: Int) throws -> HolisticFrame {
                throw Failure()
            }
        }
        let service = FingerspellingSessionService()
        let recorder = Recorder()
        service.start(dependencies: FingerspellingSessionService.Dependencies(
            landmarks: FailingLandmarks(),
            inference: inference([]),
            speak: { recorder.spoken.append($0) },
            showCaption: { recorder.captions.append($0) },
            clearCaption: { recorder.cleared += 1 }),
                      frameBufferLimit: nil)

        service.ingest(image: UIImage())
        await waitUntil { service.statusDetail?.contains("graph not loaded") == true }
        service.stop()
    }
}
