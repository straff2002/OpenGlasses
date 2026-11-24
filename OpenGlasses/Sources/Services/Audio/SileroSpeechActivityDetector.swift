import Foundation
import AVFoundation
import os

/// Plan CU P2 PR2 — the render-thread side of the detector: buffers in, chunks out to one
/// consumer, under a lock that is only ever held for a conversion.
///
/// The hand-off is an `AsyncStream` buffering the **newest** `limit` chunks: when the consumer
/// falls behind, the oldest chunk is dropped rather than queued. Stale audio is worthless for a
/// liveness decision, and a backlog would report speech-end later and later — a slow leak into
/// exactly the latency this plan removes. Drops are counted and logged at the end of the
/// utterance.
final class SpeechChunkIntake: @unchecked Sendable {

    private struct State {
        var chunker = SpeechHopChunker()
        var continuation: AsyncStream<SpeechHopChunker.Chunk>.Continuation?
        var dropped = 0
        var formatChanges = 0
    }

    struct Summary: Equatable {
        var dropped: Int
        var formatChanges: Int
    }

    let limit: Int
    private let lock = OSAllocatedUnfairLock(uncheckedState: State())

    init(limit: Int) {
        precondition(limit > 0, "a backlog of at least one chunk")
        self.limit = limit
    }

    /// Start an utterance: a fresh chunker and a fresh stream for its one consumer.
    func open() -> AsyncStream<SpeechHopChunker.Chunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: SpeechHopChunker.Chunk.self,
                                                             bufferingPolicy: .bufferingNewest(limit))
        lock.withLockUnchecked { state in
            state.continuation?.finish()
            state.chunker.reset()
            state.continuation = continuation
            state.dropped = 0
            state.formatChanges = 0
        }
        return stream
    }

    /// End the utterance. Chunks already buffered are still delivered; nothing new is accepted.
    @discardableResult
    func close() -> Summary {
        lock.withLockUnchecked { state in
            state.continuation?.finish()
            state.continuation = nil
            state.chunker.reset()
            return Summary(dropped: state.dropped, formatChanges: state.formatChanges)
        }
    }

    /// One captured buffer, on the render thread. A no-op between utterances.
    func feed(_ buffer: AVAudioPCMBuffer, route: MicRoute, arrival: Date) {
        lock.withLockUnchecked { state in
            guard let continuation = state.continuation else { return }
            let output = state.chunker.append(buffer, route: route, arrival: arrival)
            if output.formatChanged { state.formatChanges += 1 }
            for chunk in output.chunks {
                if case .dropped = continuation.yield(chunk) { state.dropped += 1 }
            }
        }
    }
}

/// Plan CU P2 PR2 — acoustic end-of-turn: on-device Silero VAD through Core ML, behind
/// `SpeechActivityDetecting`. Installed only while `Config.acousticEndOfTurnEnabled` is on.
///
/// The pipeline, in the order a buffer meets it:
///
/// 1. `feed` (render thread, ~45×/s): convert to 16 kHz mono, normalise per route, cut into
///    256 ms chunks — all inside `SpeechChunkIntake`'s lock, no main-actor hop, no waiting.
/// 2. One consumer task per utterance takes the chunks **strictly in order**, threads the model's
///    LSTM state from each into the next, and feeds the probability to a `SpeechActivityGate`
///    (`.silero`), stamped with the chunk's audio-clock time.
/// 3. Only the gate's transitions — a few per turn — reach the main actor, through `onEvent`.
///
/// A format change mid-utterance (a route flip) arrives as a new chunk epoch: the consumer zeroes
/// the LSTM state, because state learned at another sample rate is garbage, and restarts the
/// gate's runs, keeping only whether the wearer is talking (`SpeechActivityGate.restart`).
///
/// **Soft-fail is the contract.** The model loads off the main thread once, when the detector is
/// made. Until it has loaded, if it never does, or if a prediction ever throws, `isAvailable` is
/// false for the utterance, nothing is emitted, and `EndOfTurnPolicy` rule 1 hands the turn to the
/// silence timer exactly as before. Availability is fixed at `begin()`: a model that finishes
/// loading mid-utterance waits for the next one, so the rule the turn runs under never flips
/// towards the detector halfway through.
@MainActor
final class SileroSpeechActivityDetector: SpeechActivityDetecting {

    /// Chunks the consumer may fall behind by before the oldest is dropped: one second of audio.
    nonisolated static let backlogLimit = 4

    enum LoadState: Equatable { case loading, ready, failed }

    var onEvent: ((SpeechActivityGate.Event) -> Void)?

    private(set) var loadState: LoadState = .loading
    let gateConfiguration: SpeechActivityGate.Configuration

    var isAvailable: Bool {
        guard scorer != nil, !scoringFailed else { return false }
        return availableThisUtterance ?? true
    }

    nonisolated private let intake = SpeechChunkIntake(limit: SileroSpeechActivityDetector.backlogLimit)
    private var scorer: SpeechChunkScoring?
    private var loadTask: Task<Void, Never>?
    /// Fixed at `begin()`, cleared at `end()` — see the type comment.
    private var availableThisUtterance: Bool?
    private var scoringFailed = false
    private var consumer: Task<Void, Never>?
    /// Which utterance a consumer belongs to, so a late event from the last one is never delivered
    /// into the next.
    private var generation = 0

    /// - Parameter loader: blocking, run once off the main thread. The default is the bundled
    ///   model and nothing else; tests pass a scripted scorer.
    init(gateConfiguration: SpeechActivityGate.Configuration = .silero,
         loader: @escaping @Sendable () throws -> SpeechChunkScoring = { try SileroVADModel.loadBundled() }) {
        self.gateConfiguration = gateConfiguration
        loadTask = Task { [weak self] in
            let started = Date()
            let result = await Task.detached(priority: .utility) { () -> Result<SpeechChunkScoring, Error> in
                Result { try loader() }
            }.value
            self?.finishLoading(result, seconds: Date().timeIntervalSince(started))
        }
    }

    /// Wait for the load to settle. True when the scorer is ready.
    func waitUntilLoaded() async -> Bool {
        await loadTask?.value
        return loadState == .ready
    }

    func begin() {
        stopScoring()
        generation += 1
        let available = scorer != nil && !scoringFailed
        availableThisUtterance = available
        guard available, let scorer else { return }
        let stream = intake.open()
        startConsumer(stream: stream, session: scorer.makeSession(), generation: generation)
    }

    func end() {
        stopScoring()
        availableThisUtterance = nil
    }

    nonisolated func feed(_ buffer: AVAudioPCMBuffer, route: MicRoute) {
        intake.feed(buffer, route: route, arrival: Date())
    }

    // MARK: - Private

    private func finishLoading(_ result: Result<SpeechChunkScoring, Error>, seconds: TimeInterval) {
        switch result {
        case .success(let loaded):
            scorer = loaded
            loadState = .ready
            PrivacyLog.speech(.dictation, .acousticDetectorReady, seconds: seconds)
        case .failure(let error):
            loadState = .failed
            PrivacyLog.speech(.dictation, .acousticDetectorUnavailable, detail: PrivacyToken("load"),
                              error: SafeErrorSummary(error))
        }
    }

    private func stopScoring() {
        let summary = intake.close()
        consumer?.cancel()
        consumer = nil
        if summary.dropped > 0 || summary.formatChanges > 0 {
            PrivacyLog.speech(.dictation, .acousticChunksDropped, count: summary.dropped,
                              detail: PrivacyToken("formatChanges.\(summary.formatChanges)"))
        }
    }

    private func startConsumer(stream: AsyncStream<SpeechHopChunker.Chunk>,
                               session: SpeechChunkScoringSession,
                               generation: Int) {
        let configuration = gateConfiguration
        consumer = Task.detached(priority: .userInitiated) { [weak self] in
            var gate = SpeechActivityGate(configuration: configuration)
            var epoch: Int?
            for await chunk in stream {
                if Task.isCancelled { return }
                if let epoch, epoch != chunk.epoch {
                    // A format change: the LSTM state was learned at another sample rate.
                    session.resetState()
                    gate.restart(speaking: gate.isSpeaking)
                }
                epoch = chunk.epoch
                let probability: Float
                do {
                    probability = try session.score(chunk.samples)
                } catch {
                    await self?.scoringDidFail(error, generation: generation)
                    return
                }
                if let event = gate.observe(score: probability, at: chunk.startTime) {
                    await self?.deliver(event, generation: generation)
                }
            }
        }
    }

    private func deliver(_ event: SpeechActivityGate.Event, generation: Int) {
        guard generation == self.generation, availableThisUtterance == true else { return }
        onEvent?(event)
    }

    /// A prediction threw: stop scoring for good. `isAvailable` goes false, so this utterance and
    /// every later one fall back to the timer — the safe direction.
    private func scoringDidFail(_ error: Error, generation: Int) {
        guard !scoringFailed else { return }
        scoringFailed = true
        PrivacyLog.speech(.dictation, .acousticDetectorUnavailable, detail: PrivacyToken("predict"),
                          error: SafeErrorSummary(error))
        if generation == self.generation { stopScoring() }
    }
}
