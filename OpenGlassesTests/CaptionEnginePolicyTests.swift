import AVFoundation
import Speech
import XCTest
@testable import OpenGlasses

/// Plain captions run on iOS 26's long-form `SpeechAnalyzer` when they can, `SFSpeechRecognizer`
/// otherwise. The live engine needs a device; what decides and maps is tested here.
final class CaptionEnginePolicyTests: XCTestCase {

    typealias P = CaptionEnginePolicy

    // MARK: - Which engine

    func testTheAnalyzerIsTriedOnlyWhenOnAndNotFallenBack() {
        XCTAssertTrue(P.shouldTry(enabled: true, fellBackThisSession: false))
        XCTAssertFalse(P.shouldTry(enabled: false, fellBackThisSession: false), "the kill switch")
        XCTAssertFalse(P.shouldTry(enabled: true, fellBackThisSession: true), "a failure holds for the session")
    }

    func testAnInstalledLocaleRunsTheAnalyzer() {
        XCTAssertEqual(P.decide(enabled: true, fellBackThisSession: false, availability: .installed), .speechAnalyzer)
    }

    func testASupportedLocaleWithoutItsModelRunsTheRecogniserAndAsksForTheModel() {
        XCTAssertEqual(P.decide(enabled: true, fellBackThisSession: false, availability: .supportedNotInstalled),
                       .sfSpeech(installAssets: true))
    }

    func testAnUnsupportedLocaleRunsTheRecogniserAndAsksForNothing() {
        XCTAssertEqual(P.decide(enabled: true, fellBackThisSession: false, availability: .unsupported),
                       .sfSpeech(installAssets: false))
    }

    func testOffOrFallenBackNeverAsksForTheModel() {
        for availability in [P.Availability.installed, .supportedNotInstalled, .unsupported] {
            XCTAssertEqual(P.decide(enabled: false, fellBackThisSession: false, availability: availability),
                           .sfSpeech(installAssets: false))
            XCTAssertEqual(P.decide(enabled: true, fellBackThisSession: true, availability: availability),
                           .sfSpeech(installAssets: false))
        }
    }

    func testTheAssetStatusReadsAsAvailability() {
        XCTAssertEqual(P.availability(supported: true, status: .installed), .installed)
        XCTAssertEqual(P.availability(supported: true, status: .supported), .supportedNotInstalled)
        XCTAssertEqual(P.availability(supported: true, status: .downloading), .supportedNotInstalled,
                       "a model still downloading is not used yet")
        XCTAssertEqual(P.availability(supported: true, status: .unsupported), .unsupported)
        XCTAssertEqual(P.availability(supported: false, status: .installed), .unsupported)
        XCTAssertEqual(P.availability(supported: true, status: nil), .unsupported)
    }

    func testTheSwitchIsOnByDefault() {
        let saved = UserDefaults.standard.object(forKey: "captionSpeechAnalyzerEnabled")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "captionSpeechAnalyzerEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "captionSpeechAnalyzerEnabled") }
        }
        UserDefaults.standard.removeObject(forKey: "captionSpeechAnalyzerEnabled")
        XCTAssertTrue(Config.captionSpeechAnalyzerEnabled)
        Config.setCaptionSpeechAnalyzerEnabled(false)
        XCTAssertFalse(Config.captionSpeechAnalyzerEnabled)
    }

    // MARK: - Results

    func testAVolatileResultIsTheLiveLineAndAFinalIsCommitted() {
        XCTAssertEqual(P.event(text: " the agenda has ", isFinal: false), .volatile("the agenda has"))
        XCTAssertEqual(P.event(text: "The agenda has three items. ", isFinal: true), .final("The agenda has three items."))
        XCTAssertNil(P.event(text: "   ", isFinal: true), "an empty final commits nothing")
        XCTAssertEqual(P.event(text: "", isFinal: false), .volatile(""), "an empty volatile clears the line")
    }

    // MARK: - Audio

    func testTheConversionHasHeadroom() {
        XCTAssertEqual(P.outputCapacity(frames: 4_800, from: 48_000, to: 16_000), 1_600 + 64)
        XCTAssertEqual(P.outputCapacity(frames: 1_000, from: 0, to: 16_000), 1_064)
    }

    private func buffer(rate: Double, frames: AVAudioFrameCount, value: Float = 0.25) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = value }
        return buffer
    }

    private func drain(_ stream: AsyncStream<AnalyzerInput>) async -> [AVAudioPCMBuffer] {
        var out: [AVAudioPCMBuffer] = []
        for await input in stream { out.append(input.buffer) }
        return out
    }

    func testAudioBeforeTheAnalyzerIsReadyWaitsAndGoesFirst() async {
        let feed = CaptionAnalyzerAudioFeed()
        let early = buffer(rate: 16_000, frames: 1_600, value: 0.1)
        feed.append(early)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        feed.ready(format: early.format, continuation: continuation)
        let late = buffer(rate: 16_000, frames: 1_600, value: 0.2)
        feed.append(late)
        feed.finish()
        feed.append(buffer(rate: 16_000, frames: 1_600, value: 0.3))
        let fed = await drain(stream)
        XCTAssertEqual(fed.count, 2, "after finish, nothing more")
        XCTAssertEqual(fed[0].floatChannelData?[0][0] ?? 0, 0.1, accuracy: 0.0001, "the waiting one first")
        XCTAssertEqual(fed[1].floatChannelData?[0][0] ?? 0, 0.2, accuracy: 0.0001)
        XCTAssertEqual(fed[0].frameLength, 1_600, "same format: passed through unconverted")
    }

    func testOnlyAFewSecondsWaitForTheAnalyzer() async {
        let feed = CaptionAnalyzerAudioFeed()
        for _ in 0..<20 { feed.append(buffer(rate: 16_000, frames: 16_000)) }   // 20 s
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        feed.ready(format: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!, continuation: continuation)
        feed.finish()
        let fed = await drain(stream)
        XCTAssertEqual(fed.count, Int(P.queuedSecondsLimit), "the newest seconds are kept")
    }

    func testMicAudioIsConvertedToTheAnalyzersFormat() async throws {
        let feed = CaptionAnalyzerAudioFeed()
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1,
                                                 interleaved: true))
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        feed.ready(format: target, continuation: continuation)
        for _ in 0..<10 { feed.append(buffer(rate: 48_000, frames: 4_800)) }   // 1 s at 48 kHz
        feed.finish()
        let fed = await drain(stream)
        XCTAssertEqual(fed.count, 10)
        XCTAssertTrue(fed.allSatisfy { $0.format == target })
        // The resampler holds back a few hundred frames of filter latency at the start; one block
        // later the stream runs at the ratio, a third of the input.
        let total = fed.reduce(0) { $0 + Int($1.frameLength) }
        XCTAssertEqual(Double(total), 16_000, accuracy: 600)
    }

    // MARK: - Wiring, read from the source

    private func captionSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("OpenGlasses/Sources/Services/AmbientCaptionService.swift"),
                          encoding: .utf8)
    }

    private func body(of function: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: "private func \(function)() {"))
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// Translation and diarization keep their precedence; the analyzer is the plain path only, and
    /// `SFSpeechRecognizer` is what it falls back to.
    func testThePlainPathIsTheOnlyOneThatTakesTheAnalyzer() throws {
        let text = try captionSource()
        let start = try body(of: "startRecognitionSession", in: text)
        let translation = try XCTUnwrap(start.range(of: "startTranslationSession()")).lowerBound
        let diarized = try XCTUnwrap(start.range(of: "startDiarizedSession()")).lowerBound
        let analyzer = try XCTUnwrap(start.range(of: "startAnalyzerSession()")).lowerBound
        let recogniser = try XCTUnwrap(start.range(of: "startSpeechRecognizerSession()")).lowerBound
        XCTAssertTrue(translation < diarized && diarized < analyzer && analyzer < recogniser)
    }

    /// The recogniser restarts after each final; the analyzer must not.
    func testAnAnalyzerFinalDoesNotRestartRecognition() throws {
        let analyzer = try body(of: "startAnalyzerSession", in: try captionSource())
        XCTAssertFalse(analyzer.contains("startRecognitionSession()"))
        XCTAssertFalse(analyzer.contains("restartAfterDelay()"))
        XCTAssertTrue(analyzer.contains("addCaptionAudioConsumer {"), "through the assistant-voice gate")
    }

    /// The analyzer's live line is committed when its session is torn down (stop, presence, mode).
    func testTeardownCommitsTheAnalyzersLiveLine() throws {
        let teardown = try body(of: "stopRecognitionSession", in: try captionSource())
        XCTAssertTrue(teardown.contains("engine.volatileText"))
        XCTAssertTrue(teardown.contains("finalizeCaption(pending)"))
    }
}
