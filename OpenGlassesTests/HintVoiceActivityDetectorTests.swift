import AVFoundation
import XCTest
@testable import OpenGlasses

/// Plan MO §6: speech activity from the ungated mic level, and which outputs are the phone speaker.
final class HintVoiceActivityDetectorTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testSpeechStartsOnTheFirstLoudBuffer() {
        var detector = HintVoiceActivityDetector()
        XCTAssertNil(detector.feed(levelDB: -60, at: at(0)))
        XCTAssertEqual(detector.feed(levelDB: -30, at: at(0.05)), true)
        XCTAssertNil(detector.feed(levelDB: -25, at: at(0.1)), "only changes are reported")
    }

    func testGapsBetweenWordsAreNotQuiet() {
        var detector = HintVoiceActivityDetector()
        _ = detector.feed(levelDB: -30, at: at(0))
        XCTAssertNil(detector.feed(levelDB: -60, at: at(0.1)))
        XCTAssertNil(detector.feed(levelDB: -60, at: at(0.3)))
        XCTAssertNil(detector.feed(levelDB: -30, at: at(0.34)), "speech again inside the hangover")
        XCTAssertTrue(detector.isSpeaking)
    }

    func testQuietAfterTheHangover() {
        var detector = HintVoiceActivityDetector()
        _ = detector.feed(levelDB: -30, at: at(0))
        XCTAssertNil(detector.feed(levelDB: -60, at: at(1)))
        XCTAssertNil(detector.feed(levelDB: -60, at: at(1.2)))
        XCTAssertEqual(detector.feed(levelDB: -60, at: at(1.25)), false)
    }

    func testTheBandBetweenTheThresholdsHoldsTheState() {
        var detector = HintVoiceActivityDetector()
        XCTAssertNil(detector.feed(levelDB: -42, at: at(0)), "not loud enough to start")
        _ = detector.feed(levelDB: -30, at: at(0.1))
        XCTAssertNil(detector.feed(levelDB: -42, at: at(1)), "not quiet enough to stop")
        XCTAssertNil(detector.feed(levelDB: -42, at: at(5)))
        XCTAssertTrue(detector.isSpeaking)
    }

    func testTheLevelOfSamples() {
        let silence = [Float](repeating: 0, count: 256)
        silence.withUnsafeBufferPointer { XCTAssertEqual(HintVoiceActivityDetector.levelDB($0), -120) }
        let full = [Float](repeating: 1, count: 256)
        full.withUnsafeBufferPointer { XCTAssertEqual(HintVoiceActivityDetector.levelDB($0), 0, accuracy: 0.001) }
        let tenth = [Float](repeating: 0.1, count: 256)
        tenth.withUnsafeBufferPointer { XCTAssertEqual(HintVoiceActivityDetector.levelDB($0), -20, accuracy: 0.001) }
    }

    // MARK: - The phone speaker

    func testThePhoneSpeakerIsOnlyTheBuiltInOutputs() {
        XCTAssertTrue(HintOutputRoute.isPhoneSpeaker(outputs: [.builtInSpeaker]))
        XCTAssertTrue(HintOutputRoute.isPhoneSpeaker(outputs: [.builtInReceiver]))
        XCTAssertTrue(HintOutputRoute.isPhoneSpeaker(outputs: []), "no route is nowhere private")
        XCTAssertFalse(HintOutputRoute.isPhoneSpeaker(outputs: [.bluetoothA2DP]))
        XCTAssertFalse(HintOutputRoute.isPhoneSpeaker(outputs: [.bluetoothLE]))
        XCTAssertFalse(HintOutputRoute.isPhoneSpeaker(outputs: [.headphones]))
        XCTAssertFalse(HintOutputRoute.isPhoneSpeaker(outputs: [.builtInSpeaker, .bluetoothA2DP]))
    }
}
