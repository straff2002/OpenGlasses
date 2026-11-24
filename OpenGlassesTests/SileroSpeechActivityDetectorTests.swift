import XCTest
import AVFoundation
@testable import OpenGlasses

/// Returns scripted probabilities in order; counts calls and resets.
private final class ScriptedScorer: SpeechChunkScoring, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Float]
    private var calls = 0
    private(set) var resets = 0
    var failAt: Int?

    init(_ script: [Float]) { self.script = script }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

    func makeSession() -> SpeechChunkScoringSession { Session(owner: self) }

    fileprivate func next() throws -> Float {
        lock.lock(); defer { lock.unlock() }
        defer { calls += 1 }
        if let failAt, calls == failAt { throw NSError(domain: "scripted", code: 1) }
        return calls < script.count ? script[calls] : 0
    }

    final class Session: SpeechChunkScoringSession {
        let owner: ScriptedScorer
        init(owner: ScriptedScorer) { self.owner = owner }
        func score(_ samples: [Float]) throws -> Float {
            precondition(samples.count == SpeechHopChunker.chunkSamples)
            return try owner.next()
        }
        func resetState() { owner.resets += 1 }
    }
}

/// Plan CU P2 PR2 — the detector's pipeline with a scripted scorer (drop-oldest, ordered scoring,
/// transitions only, soft-fail), the switch that installs it, and the guards that keep it local.
@MainActor
final class SileroSpeechActivityDetectorTests: XCTestCase {

    // MARK: - Fixtures

    /// A 16 kHz mono buffer of `frames` samples of a quiet tone.
    private nonisolated static func buffer(frames: Int = SpeechHopChunker.hopSamples) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = buffer.floatChannelData![0]
        for i in 0..<frames { data[i] = Float(0.05 * sin(Double(i) * 0.17)) }
        return buffer
    }

    private struct LoadFailure: Error {}

    /// Wait (bounded) until `condition` holds, yielding to the consumer and the main actor.
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Drop-oldest

    func testAStalledConsumerKeepsOnlyTheNewestChunks() async {
        let limit = SileroSpeechActivityDetector.backlogLimit
        let intake = SpeechChunkIntake(limit: limit)
        let stream = intake.open()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // Ten chunks' worth, and nobody reading.
        for n in 0..<10 {
            intake.feed(Self.buffer(), route: .phone, arrival: start.addingTimeInterval(Double(n + 1) * 0.256))
        }
        let summary = intake.close()
        var survivors: [Int] = []
        for await chunk in stream { survivors.append(chunk.startSample) }

        XCTAssertLessThanOrEqual(survivors.count, limit, "the backlog never exceeds the limit")
        XCTAssertEqual(survivors, (10 - limit..<10).map { $0 * 4_096 },
                       "the newest survive, in order; stale audio is worthless for a liveness decision")
        XCTAssertEqual(summary.dropped, 10 - limit)
    }

    func testFeedingBetweenUtterancesIsANoOp() async {
        let intake = SpeechChunkIntake(limit: 4)
        intake.feed(Self.buffer(), route: .phone, arrival: Date())
        let stream = intake.open()
        intake.close()
        var count = 0
        for await _ in stream { count += 1 }
        XCTAssertEqual(count, 0)
    }

    // MARK: - Pipeline

    func testTransitionsOnlyReachTheMainActorStampedOnTheAudioClock() async {
        // Chunks: quiet, speech ×3, quiet ×4.
        let scorer = ScriptedScorer([0.1, 0.9, 0.9, 0.9, 0.1, 0.1, 0.1, 0.1])
        let detector = SileroSpeechActivityDetector(loader: { scorer })
        let loaded = await detector.waitUntilLoaded()
        XCTAssertTrue(loaded)
        var events: [SpeechActivityGate.Event] = []
        detector.onEvent = { events.append($0) }

        detector.begin()
        XCTAssertTrue(detector.isAvailable)
        for n in 0..<8 {
            detector.feed(Self.buffer(), route: .phone)
            await waitFor { scorer.callCount == n + 1 }
        }
        await waitFor { events.count == 2 }
        detector.end()

        XCTAssertEqual(scorer.callCount, 8, "every chunk scored, none dropped when the consumer keeps up")
        guard events.count == 2, case .speechStarted(let started) = events[0],
              case .speechEnded(let ended) = events[1] else {
            return XCTFail("expected start then end, got \(events)")
        }
        XCTAssertEqual(ended.timeIntervalSince(started), 3 * SpeechHopChunker.hopDuration, accuracy: 1e-6,
                       "chunk 1 to chunk 4 on the audio clock, whatever the model's own timing")
    }

    func testNothingFromTheLastUtteranceLeaksIntoTheNext() async {
        let scorer = ScriptedScorer([0.9, 0.9, 0.9])
        let detector = SileroSpeechActivityDetector(loader: { scorer })
        _ = await detector.waitUntilLoaded()
        var events: [SpeechActivityGate.Event] = []
        detector.onEvent = { events.append($0) }

        detector.begin()
        detector.feed(Self.buffer(), route: .phone)
        await waitFor { scorer.callCount == 1 }
        detector.end()
        detector.feed(Self.buffer(), route: .phone)           // after end: ignored
        detector.begin()
        detector.feed(Self.buffer(), route: .phone)
        await waitFor { scorer.callCount == 2 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        detector.end()

        XCTAssertEqual(scorer.callCount, 2)
        XCTAssertTrue(events.isEmpty,
                      "one loud chunk in each utterance is two isolated chunks, never a confirmed onset")
    }

    // MARK: - Soft-fail

    func testAModelThatWillNotLoadIsUnavailableAndSilent() async {
        let detector = SileroSpeechActivityDetector(loader: { throw LoadFailure() })
        let loaded = await detector.waitUntilLoaded()
        XCTAssertFalse(loaded)
        XCTAssertEqual(detector.loadState, .failed)
        XCTAssertFalse(detector.isAvailable)
        var events = 0
        detector.onEvent = { _ in events += 1 }
        detector.begin()
        XCTAssertFalse(detector.isAvailable, "the timer keeps the turn")
        for _ in 0..<6 { detector.feed(Self.buffer(), route: .phone) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        detector.end()
        XCTAssertEqual(events, 0)
    }

    func testAPredictionFailureFallsBackToTheTimerForGood() async {
        let scorer = ScriptedScorer([0.9, 0.9, 0.9])
        scorer.failAt = 1
        let detector = SileroSpeechActivityDetector(loader: { scorer })
        _ = await detector.waitUntilLoaded()
        detector.begin()
        detector.feed(Self.buffer(), route: .phone)
        detector.feed(Self.buffer(), route: .phone)
        await waitFor { !detector.isAvailable }
        XCTAssertFalse(detector.isAvailable)
        detector.end()
        detector.begin()
        XCTAssertFalse(detector.isAvailable, "a model that threw once is not trusted again this run")
        detector.end()
    }

    func testAModelThatLoadsMidUtteranceWaitsForTheNextOne() async {
        let scorer = ScriptedScorer([])
        let detector = SileroSpeechActivityDetector(loader: {
            Thread.sleep(forTimeInterval: 0.3)
            return scorer
        })
        detector.begin()
        XCTAssertFalse(detector.isAvailable)
        _ = await detector.waitUntilLoaded()
        XCTAssertFalse(detector.isAvailable,
                       "the rule this turn runs under never flips towards the detector halfway through")
        detector.end()
        XCTAssertTrue(detector.isAvailable)
        detector.begin()
        XCTAssertTrue(detector.isAvailable)
        detector.end()
    }

    // MARK: - The switch

    func testTheSwitchDefaultsOff() {
        let key = "acousticEndOfTurnEnabled"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(Config.acousticEndOfTurnEnabled)
    }

    func testWithTheSwitchOffNoDetectorIsInstalled() {
        let service = TranscriptionService()
        var made = 0
        service.acousticDetectorFactory = { made += 1; return NoSpeechActivityDetector() }
        XCTAssertFalse(service.acousticEndOfTurnEnabledProvider(), "the service's own default is off too")
        service.adoptAcousticDetectorForThisUtterance()
        XCTAssertNil(service.speechActivityDetector,
                     "off is EndOfTurnPolicy rule 1, the timer alone — see EndOfTurnPolicyTests")
        XCTAssertEqual(made, 0)
    }

    func testTheSwitchInstallsAndRemovesAtTheBoundary() {
        let service = TranscriptionService()
        var enabled = true
        service.acousticEndOfTurnEnabledProvider = { enabled }
        service.acousticDetectorFactory = { NoSpeechActivityDetector() }

        service.adoptAcousticDetectorForThisUtterance()
        let installed = service.speechActivityDetector
        XCTAssertNotNil(installed)
        service.adoptAcousticDetectorForThisUtterance()
        XCTAssertTrue(service.speechActivityDetector === installed, "kept across utterances, not remade")

        enabled = false
        service.adoptAcousticDetectorForThisUtterance()
        XCTAssertNil(service.speechActivityDetector)
    }

    func testTheSwitchNeverRemovesADetectorItDidNotInstall() {
        let service = TranscriptionService()
        let direct = NoSpeechActivityDetector()
        service.speechActivityDetector = direct
        service.acousticEndOfTurnEnabledProvider = { false }
        service.adoptAcousticDetectorForThisUtterance()
        XCTAssertTrue(service.speechActivityDetector === direct)
    }

    // MARK: - Guards

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    static let detectorSources = [
        "OpenGlasses/Sources/Services/Audio/SileroSpeechActivityDetector.swift",
        "OpenGlasses/Sources/Services/Audio/SileroVADModel.swift",
        "OpenGlasses/Sources/Services/Audio/SpeechHopChunker.swift",
    ]

    func testTheDetectorNeverReachesTheNetwork() throws {
        for path in Self.detectorSources {
            let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
                .lowercased()
            for banned in ["urlsession", "http", "download"] {
                XCTAssertFalse(text.contains(banned),
                               "\(path) mentions \(banned): the model is bundled and loaded from the bundle only")
            }
        }
    }

    func testTheModelIsInTheBundleWithItsWeights() throws {
        let url = try XCTUnwrap(SileroVADModel.bundledURL(in: .main),
                                "the .mlmodelc is missing from the app: the switch would silently do nothing")
        XCTAssertEqual(url.lastPathComponent, "silero-vad-unified-256ms-v6.2.1.mlmodelc")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "a compiled model is a directory, structure intact")
        for file in ["weights/weight.bin", "model.mil", "coremldata.bin", "metadata.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent(file).path),
                          "\(file) missing from the bundled model")
        }
    }
}
