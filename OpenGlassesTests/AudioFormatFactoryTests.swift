import AVFoundation
import XCTest
@testable import OpenGlasses

/// Tests the pure, throwing `AVAudioFormat` constructor that replaces the force-unwrapped
/// `AVAudioFormat(...)!` calls in the realtime audio managers. Valid params yield a matching
/// format; degenerate params throw a typed `AudioSessionError.invalidFormat(context:)` instead
/// of trapping (the crash these glasses hit on unexpected Bluetooth/LE-Audio input formats).
final class AudioFormatFactoryTests: XCTestCase {

    func testValidInt16InterleavedFormat() throws {
        let format = try AudioFormatFactory.pcm(
            .pcmFormatInt16,
            sampleRate: 24000,
            channels: 1,
            interleaved: true,
            context: "playback"
        )
        XCTAssertEqual(format.sampleRate, 24000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatInt16)
        XCTAssertTrue(format.isInterleaved)
    }

    func testValidFloat32NonInterleavedFormat() throws {
        let format = try AudioFormatFactory.pcm(
            .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false,
            context: "capture resampling"
        )
        XCTAssertEqual(format.sampleRate, 16000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(format.isInterleaved)
    }

    func testZeroSampleRateThrowsInvalidFormatWithContext() {
        XCTAssertThrowsError(
            try AudioFormatFactory.pcm(
                .pcmFormatFloat32,
                sampleRate: 0,
                channels: 1,
                interleaved: false,
                context: "playback"
            )
        ) { error in
            XCTAssertEqual(error as? AudioSessionError, .invalidFormat(context: "playback"))
        }
    }

    func testZeroChannelsThrowsInvalidFormatWithContext() {
        XCTAssertThrowsError(
            try AudioFormatFactory.pcm(
                .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 0,
                interleaved: false,
                context: "capture resampling"
            )
        ) { error in
            XCTAssertEqual(error as? AudioSessionError, .invalidFormat(context: "capture resampling"))
        }
    }

    func testContextIsPreservedInThrownError() {
        XCTAssertThrowsError(
            try AudioFormatFactory.pcm(
                .pcmFormatInt16,
                sampleRate: -1,
                channels: 2,
                interleaved: true,
                context: "diagnostic-marker"
            )
        ) { error in
            guard case .invalidFormat(let context)? = error as? AudioSessionError else {
                return XCTFail("Expected AudioSessionError.invalidFormat, got \(error)")
            }
            XCTAssertEqual(context, "diagnostic-marker")
        }
    }
}

/// The guard in front of `installTap`: a 0 Hz / 0-channel input format — what the input node
/// reports while the microphone is unavailable — raises an uncatchable Objective-C exception
/// if a tap is installed on it (TestFlight build 463, "in background with Meta AI open").
final class TapFormatGuardTests: XCTestCase {

    func testAnEmptyFormatIsNotUsableForATap() {
        // `AVAudioFormat()` is the empty format: 0 Hz, 0 channels — the same shape an inactive
        // input reports.
        let empty = AVAudioFormat()
        XCTAssertEqual(empty.sampleRate, 0)
        XCTAssertEqual(empty.channelCount, 0)
        XCTAssertFalse(AudioFormatFactory.isUsableTapFormat(empty))
    }

    func testARealInputFormatIsUsable() throws {
        let format = try AudioFormatFactory.pcm(.pcmFormatFloat32, sampleRate: 48000, channels: 1,
                                                interleaved: false, context: "capture")
        XCTAssertTrue(AudioFormatFactory.isUsableTapFormat(format))
    }

    func testEitherZeroDimensionIsRefused() {
        XCTAssertFalse(AudioFormatFactory.isUsableTapFormat(sampleRate: 0, channelCount: 1))
        XCTAssertFalse(AudioFormatFactory.isUsableTapFormat(sampleRate: 16000, channelCount: 0))
        XCTAssertTrue(AudioFormatFactory.isUsableTapFormat(sampleRate: 16000, channelCount: 1))
    }
}
