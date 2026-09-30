import XCTest
@testable import OpenGlasses

/// Plan GJ P0: media commands → one / two / three taps through the calibration table, with
/// coalescing of the two-command bursts some Bluetooth stacks send for one tap.
final class TempleGestureDecoderTests: XCTestCase {

    func testDefaultTableMapsTheConventionalCommands() {
        let calibration = TempleCalibration.assumedDefault
        XCTAssertEqual(calibration.gesture(for: .togglePlayPause), .one)
        XCTAssertEqual(calibration.gesture(for: .nextTrack), .two)
        XCTAssertEqual(calibration.gesture(for: .previousTrack), .three)
    }

    func testPlayAndPauseCountAsOneTap() {
        let calibration = TempleCalibration.assumedDefault
        XCTAssertEqual(calibration.gesture(for: .play), .one)
        XCTAssertEqual(calibration.gesture(for: .pause), .one)
    }

    func testEveryCommandIsInTheDefaultTable() {
        for command in MediaRemoteCommand.allCases {
            XCTAssertNotNil(TempleCalibration.assumedDefault.gesture(for: command), "\(command)")
        }
    }

    func testDefaultIsHonestlyUnconfirmed() {
        // Nothing has been observed on glasses yet; the flags must say so until a device run.
        XCTAssertFalse(TempleCalibration.current.deviceConfirmed)
        XCTAssertFalse(TempleCalibration.current.sessionControlConfirmed)
    }

    func testCommandsFarApartAreSeparateTaps() {
        var decoder = TempleGestureDecoder(calibration: .assumedDefault)
        XCTAssertEqual(decoder.decode(.togglePlayPause, at: 0), .one)
        XCTAssertEqual(decoder.decode(.nextTrack, at: 1), .two)
        XCTAssertEqual(decoder.decode(.previousTrack, at: 2), .three)
    }

    func testPauseThenPlayWithinWindowIsOneGesture() {
        var decoder = TempleGestureDecoder(calibration: .assumedDefault)
        XCTAssertEqual(decoder.decode(.pause, at: 10.0), .one)
        XCTAssertNil(decoder.decode(.play, at: 10.08))
    }

    func testWindowBoundaryIsExclusive() {
        var decoder = TempleGestureDecoder(calibration: .assumedDefault, coalescingWindow: 0.15)
        XCTAssertEqual(decoder.decode(.pause, at: 0), .one)
        XCTAssertEqual(decoder.decode(.play, at: 0.15), .one)
    }

    func testBurstCoalescesFromTheMostRecentCommand() {
        var decoder = TempleGestureDecoder(calibration: .assumedDefault)
        XCTAssertEqual(decoder.decode(.pause, at: 0), .one)
        XCTAssertNil(decoder.decode(.play, at: 0.1))
        XCTAssertNil(decoder.decode(.pause, at: 0.2))    // 0.1 after the previous one
        XCTAssertEqual(decoder.decode(.nextTrack, at: 0.5), .two)
    }

    func testReplacedCalibrationWins() {
        // A device run that finds double tap arrives as previous-track just edits the table.
        var calibration = TempleCalibration.assumedDefault
        calibration.table[.previousTrack] = .two
        calibration.table[.nextTrack] = .three
        var decoder = TempleGestureDecoder(calibration: calibration)
        XCTAssertEqual(decoder.decode(.previousTrack, at: 0), .two)
        XCTAssertEqual(decoder.decode(.nextTrack, at: 1), .three)
    }

    func testUnknownCommandDecodesToNothing() {
        var calibration = TempleCalibration.assumedDefault
        calibration.table[.previousTrack] = nil
        var decoder = TempleGestureDecoder(calibration: calibration)
        XCTAssertNil(decoder.decode(.previousTrack, at: 0))
    }

    func testResetForgetsTheLastCommand() {
        var decoder = TempleGestureDecoder(calibration: .assumedDefault)
        _ = decoder.decode(.pause, at: 0)
        decoder.reset()
        XCTAssertEqual(decoder.decode(.play, at: 0.05), .one)
    }
}
