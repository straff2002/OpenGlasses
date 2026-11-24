import XCTest
import CoreML
@testable import OpenGlasses

/// Plan CU P2 PR2 — the bundled Silero model through our own Core ML runner. Hosted tests run
/// inside the app, so this is the real `.mlmodelc` from `Bundle.main`.
///
/// If Core ML cannot load the model on this destination, the test asserts the contract instead of
/// skipping: the detector soft-fails (`isAvailable == false`, load state `.failed`) and the timer
/// keeps the turn. `testTheModelIsInTheBundleWithItsWeights` separately makes a missing model fail
/// the suite, so soft-fail can never hide one.
final class SileroVADModelTests: XCTestCase {

    private func loadOrAssertSoftFail() async throws -> SileroVADModel? {
        do {
            return try SileroVADModel.loadBundled(from: .main)
        } catch {
            XCTAssertNotEqual(error as? SileroVADModel.LoadError, .notBundled,
                              "the model must be bundled; soft-fail is for Core ML refusing it")
            let detector = await SileroSpeechActivityDetector()
            let loaded = await detector.waitUntilLoaded()
            XCTAssertFalse(loaded)
            let available = await detector.isAvailable
            XCTAssertFalse(available, "a model that will not load must leave the detector unavailable")
            let state = await detector.loadState
            XCTAssertEqual(state, .failed)
            XCTContext.runActivity(named: "Core ML refused the bundled model here: soft-fail asserted") { _ in }
            return nil
        }
    }

    func testTheInterfaceIsTheOneTheRunnerWasWrittenAgainst() async throws {
        guard let model = try await loadOrAssertSoftFail() else { return }
        XCTAssertEqual(model.names, SileroVADModel.FeatureNames(
            audio: "audio_input", hidden: "hidden_state", cell: "cell_state",
            probability: "vad_output", newHidden: "new_hidden_state", newCell: "new_cell_state"))
        let audio = try XCTUnwrap(model.model.modelDescription.inputDescriptionsByName["audio_input"]?
            .multiArrayConstraint)
        XCTAssertEqual(audio.shape, [1, NSNumber(value: SpeechHopChunker.chunkSamples)])
    }

    func testSilenceScoresLowAndTheStateIs128Wide() async throws {
        guard let model = try await loadOrAssertSoftFail() else { return }
        let zeros = [Float](repeating: 0, count: SileroVADModel.stateSize)
        let silence = [Float](repeating: 0, count: SpeechHopChunker.chunkSamples)
        let result = try model.predict(audio: silence, hidden: zeros, cell: zeros)
        XCTAssertGreaterThanOrEqual(result.probability, 0)
        XCTAssertLessThanOrEqual(result.probability, 1)
        XCTAssertLessThan(result.probability, 0.5, "digital silence is not speech")
        XCTAssertEqual(result.hidden.count, 128)
        XCTAssertEqual(result.cell.count, 128)
        XCTAssertTrue(result.hidden.allSatisfy(\.isFinite))
    }

    func testTheStateCarriesFromOneChunkToTheNext() async throws {
        guard let model = try await loadOrAssertSoftFail() else { return }
        // A tone with some noise, so the LSTM has something to remember.
        var seed: UInt32 = 12_345
        let chunk: [Float] = (0..<SpeechHopChunker.chunkSamples).map { i in
            seed = seed &* 1_103_515_245 &+ 12_345
            let noise = Float(Int(seed >> 16) % 2_000 - 1_000) / 20_000
            return Float(0.3 * sin(Double(i) * 2 * .pi * 220 / 16_000)) + noise
        }
        let session = SileroVADSession(model: model)
        let first = try session.score(chunk)
        let afterOne = session.hidden
        XCTAssertNotEqual(afterOne, [Float](repeating: 0, count: 128), "one chunk moves the state")
        let second = try session.score(chunk)
        XCTAssertNotEqual(session.hidden, afterOne, "and the next chunk starts from it")
        XCTAssertTrue((0...1).contains(first) && (0...1).contains(second))

        // The same chunk from fresh state reads the same as the first call did: the difference
        // above came from the carried state, not from the model being non-deterministic.
        session.resetState()
        XCTAssertEqual(session.hidden, [Float](repeating: 0, count: 128))
        let fresh = try session.score(chunk)
        XCTAssertEqual(fresh, first, accuracy: 1e-3)
    }
}
