import AVFoundation
import Combine
import UIKit
import XCTest
@testable import OpenGlasses

/// Pure-decision coverage for the recording guards: the storage verdict (refuse / warn-with-
/// estimate / ok) and the stream-death watchdog (auto-stop only after frames have flowed and
/// then stalled). The I/O edges (disk query, AVAssetWriter, timers) stay untested by design.
@MainActor
final class VideoRecordingGuardTests: XCTestCase {

    // MARK: - Storage verdict

    func testInsufficientBelowHardFloor() {
        XCTAssertEqual(
            VideoRecordingService.storageVerdict(freeBytes: 150_000_000, videoBitrate: 1_500_000),
            .insufficient)
    }

    func testLowStorageCarriesMinutesEstimate() {
        // 1 GB free at 1.5 Mbps video + 64 kbps audio ≈ 195.5 KB/s → ~85 minutes.
        let verdict = VideoRecordingService.storageVerdict(freeBytes: 1_000_000_000, videoBitrate: 1_500_000)
        guard case .low(let minutes) = verdict else {
            return XCTFail("1 GB free should be low, got \(verdict)")
        }
        XCTAssertEqual(minutes, 85)
    }

    func testPlentyOfStorageIsOK() {
        XCTAssertEqual(
            VideoRecordingService.storageVerdict(freeBytes: 50_000_000_000, videoBitrate: 1_500_000),
            .ok)
    }

    func testHigherBitrateShrinksTheEstimate() {
        guard case .low(let slow) = VideoRecordingService.storageVerdict(freeBytes: 1_000_000_000, videoBitrate: 1_500_000),
              case .low(let fast) = VideoRecordingService.storageVerdict(freeBytes: 1_000_000_000, videoBitrate: 6_000_000) else {
            return XCTFail("both should be low")
        }
        XCTAssertGreaterThan(slow, fast, "a higher bitrate must estimate fewer minutes")
    }

    // MARK: - Stream-death watchdog

    func testNoAutoStopBeforeFirstFrame() {
        // Waiting for the stream to warm up is not a stall — never stop a frameless recording.
        XCTAssertFalse(VideoRecordingService.shouldAutoStop(
            isRecording: true, lastFrameAt: nil, now: Date()))
    }

    func testNoAutoStopWhileFramesFlow() {
        let now = Date()
        XCTAssertFalse(VideoRecordingService.shouldAutoStop(
            isRecording: true, lastFrameAt: now.addingTimeInterval(-2), now: now))
    }

    func testAutoStopAfterStall() {
        let now = Date()
        XCTAssertTrue(VideoRecordingService.shouldAutoStop(
            isRecording: true,
            lastFrameAt: now.addingTimeInterval(-VideoRecordingService.frameStallSeconds - 1),
            now: now))
    }

    func testNoAutoStopWhenNotRecording() {
        let now = Date()
        XCTAssertFalse(VideoRecordingService.shouldAutoStop(
            isRecording: false, lastFrameAt: now.addingTimeInterval(-600), now: now))
    }

    // MARK: - Where a recording goes, and where its frames come from (Plan HE)

    /// Every existing caller passes neither, and gets what it always got.
    func testALibraryRecordingIsFiledAsItAlwaysWas() {
        typealias Service = VideoRecordingService
        XCTAssertEqual(Service.filingPlan(for: .library, photosSetting: true, hasChosenFolder: true),
                       .init(filesIntoRecordingsFolder: true, copiesToChosenFolder: true, savesToPhotos: true,
                             writesTranscriptFiles: true))
        XCTAssertEqual(Service.filingPlan(for: .library, photosSetting: false, hasChosenFolder: false),
                       .init(filesIntoRecordingsFolder: true, copiesToChosenFolder: false, savesToPhotos: false,
                             writesTranscriptFiles: true))
    }

    /// A recorded job's part stays in the file it was written to — whatever the wearer's
    /// recording settings say. **Never Photos.**
    func testANamedFileIsNeverFiledCopiedOrSavedToPhotos() {
        let part = VideoRecordingService.Destination.file(URL(fileURLWithPath: "/job/recording/capture/part-1.mp4"))
        for photos in [true, false] {
            for folder in [true, false] {
                XCTAssertEqual(VideoRecordingService.filingPlan(for: part, photosSetting: photos, hasChosenFolder: folder),
                               .init(filesIntoRecordingsFolder: false, copiesToChosenFolder: false,
                                     savesToPhotos: false, writesTranscriptFiles: false),
                               "photos \(photos), chosen folder \(folder)")
            }
        }
    }

    func testRawFramesAreRefusedForTheLibrary() {
        typealias Service = VideoRecordingService
        let part = Service.Destination.file(URL(fileURLWithPath: "/job/recording/capture/part-1.mp4"))
        XCTAssertNoThrow(try Service.checkPairing(source: .outboundRelay, destination: .library))
        XCTAssertNoThrow(try Service.checkPairing(source: .outboundRelay, destination: part))
        XCTAssertNoThrow(try Service.checkPairing(source: .rawForOfficeRecording, destination: part))
        XCTAssertThrowsError(try Service.checkPairing(source: .rawForOfficeRecording, destination: .library))
    }

    /// The refusal comes before a writer, a file or a subscription exists.
    func testStartingALibraryRecordingFromRawFramesThrowsAndStartsNothing() {
        let recorder = VideoRecordingService()
        XCTAssertThrowsError(try recorder.startRecording(from: PassthroughSubject<UIImage, Never>(),
                                                         source: .rawForOfficeRecording)) { error in
            XCTAssertTrue(error is VideoRecordingService.FramePairingError)
        }
        XCTAssertFalse(recorder.isRecording)
    }

    // MARK: - The timebase

    func testEachTrackReportsItsOwnFirstSampleAndLength() {
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000) }
        let timebase = VideoRecordingService.timebase(videoStart: time(5_000.4), lastVideoPresentation: time(59.9),
                                                      frameRate: 10, audioStart: time(5_000.65), audioEnd: time(59.5))
        XCTAssertEqual(timebase.video?.firstSample ?? 0, 5_000.4, accuracy: 0.001)
        XCTAssertEqual(timebase.video?.duration ?? 0, 60, accuracy: 0.001, "to the end of the last frame's interval")
        XCTAssertEqual(timebase.audio?.firstSample ?? 0, 5_000.65, accuracy: 0.001)
        XCTAssertEqual(timebase.audio?.duration ?? 0, 59.5, accuracy: 0.001)
    }

    func testATrackThatNeverReceivedASampleHasNoEntry() {
        let start = CMTime(seconds: 10, preferredTimescale: 1_000)
        XCTAssertTrue(VideoRecordingService.timebase(videoStart: nil, lastVideoPresentation: nil, frameRate: 24,
                                                     audioStart: nil, audioEnd: nil).isEmpty)
        let soundOnly = VideoRecordingService.timebase(videoStart: nil, lastVideoPresentation: nil, frameRate: 24,
                                                       audioStart: start, audioEnd: start)
        XCTAssertNil(soundOnly.video)
        XCTAssertNotNil(soundOnly.audio)
    }
}
