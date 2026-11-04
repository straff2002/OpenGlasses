import Foundation

/// What a sentence became once synthesised.
enum StreamedSpeechAudio: Equatable {
    /// Encoded audio, ready for the player (the cloud voice and Kokoro).
    case audio(Data)
    /// Nothing to prepare: the system voice speaks the text live when its turn comes.
    case live
}

/// A synthesis failure that carries a line for the next engine to say with the sentence — the
/// one-off "your cloud voice is out of credit" notice (`CloudVoiceFallbackAnnouncer`).
struct StreamedSynthesisFailure: Error {
    var lineToAppend: String?
}

/// How a streamed reply ended (Plan HZ P1). Held in memory only, for the interruption record and a
/// replay; nothing here is logged but its counts.
struct StreamedReplyRecord: Equatable {
    /// Sentences the reply was split into (including any that never played).
    var sentenceCount: Int
    /// Sentences played to their end.
    var heardCount: Int
    /// What cut the reply short, if anything did.
    var interruption: SpeechDeliveryOutcome.Interruption?
    /// Every sentence from the first unheard one on — where a replay starts.
    var unheardSentences: [String]

    var unheardText: String { unheardSentences.joined(separator: " ") }
}

/// The engine side of a streamed reply. `TextToSpeechService` is the one real implementation; a
/// test hands the queue a fake and drives synthesis and playback by hand.
@MainActor
protocol StreamedSpeechBackend: AnyObject {
    /// The engine chain for one sentence, best first — the same chain `speak` walks.
    func streamedSpeechChain() -> [TTSEngine]
    /// Prepare one sentence on one engine. Throws to fall through to the next engine.
    func synthesizeStreamedSentence(_ text: String, engine: TTSEngine) async throws -> StreamedSpeechAudio
    /// The first sentence is about to play: take the floor (wait out an utterance already
    /// playing, stop the thinking sound, hold other audio).
    func beginStreamedPlayback() async
    /// Play one prepared sentence to its end, or until it is stopped, and say how it ended.
    /// `source` is the reply's own (Plan KL P4), for the `speaking` log line.
    func playStreamedSentence(_ text: String, audio: StreamedSpeechAudio, engine: TTSEngine,
                              source: SpeechSource) async -> SpeechDeliveryOutcome
    /// The reply is over, however it ended.
    func streamedReplyDidEnd(_ queue: StreamedReplyQueue, record: StreamedReplyRecord,
                             playbackBegan: Bool) async
}

/// Drives a `StreamedReplySchedule` against a `StreamedSpeechBackend` (Plan HZ P1): sentences go
/// in as the model writes them, synthesis runs ahead of playback, and playback is strictly in
/// order. One queue is one reply.
///
/// `isCurrent` is checked before every sentence plays — the conversation-reset generation the
/// reply belongs to — so a reset mid-reply plays nothing further. `cancel(_:)` is the barge-in and
/// stop path: in-flight synthesis is cancelled, the queue is dropped, and the record says how many
/// sentences were heard and where the unheard part begins.
@MainActor
final class StreamedReplyQueue {

    private weak var backend: (any StreamedSpeechBackend)?
    /// What kind of line every sentence of this reply is (Plan KL P4), logged as each one plays.
    let source: SpeechSource
    private var schedule: StreamedReplySchedule
    private let isCurrent: @MainActor () -> Bool
    private var audio: [Int: StreamedSpeechAudio] = [:]
    private var synthesisTasks: [Int: Task<Void, Never>] = [:]
    private var playbackTask: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var playbackBegan = false
    /// `settle()` has begun ending the reply / has finished ending it.
    private var ending = false
    private var hasEnded = false

    /// What cut the reply short, if anything did.
    private(set) var interruption: SpeechDeliveryOutcome.Interruption?
    /// Called once, when the first sentence is about to play.
    var onPlaybackBegan: (() -> Void)?

    init(backend: any StreamedSpeechBackend, source: SpeechSource,
         prefetchDepth: Int = StreamedReplySchedule.defaultPrefetchDepth,
         isCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.backend = backend
        self.source = source
        self.schedule = StreamedReplySchedule(prefetchDepth: prefetchDepth)
        self.isCurrent = isCurrent
    }

    // MARK: - Reading

    /// The sentences enqueued so far, in order.
    var sentences: [String] { schedule.items.map(\.text) }
    var sentenceCount: Int { schedule.items.count }
    var heardCount: Int { schedule.heardCount }
    var isCancelled: Bool { schedule.isCancelled }
    /// No more sentences will be added.
    var isClosed: Bool { schedule.isClosed }
    var isComplete: Bool { schedule.isComplete }
    /// A cloud voice was demoted for the rest of this reply.
    var cloudDemoted: Bool { schedule.cloudDemoted }

    /// Sentences from `start` on that were played to their end.
    func heardSentences(from start: Int) -> [String] {
        schedule.items.dropFirst(start).filter { $0.state == .heard }.map(\.text)
    }

    var record: StreamedReplyRecord {
        StreamedReplyRecord(sentenceCount: schedule.items.count, heardCount: schedule.heardCount,
                            interruption: interruption, unheardSentences: schedule.unheardTexts)
    }

    // MARK: - Driving

    /// Add the next sentence. Ignored once the reply is closed or cancelled.
    func enqueue(_ sentence: String) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !schedule.isClosed, !schedule.isCancelled, let backend else { return }
        perform(schedule.enqueue(text, chain: backend.streamedSpeechChain()))
    }

    /// No more sentences: wait until every enqueued one has played, or the reply was cancelled.
    @discardableResult
    func finish() async -> StreamedReplyRecord {
        perform(schedule.close())
        await settle()
        if !hasEnded {
            await withCheckedContinuation { waiters.append($0) }
        }
        return record
    }

    /// Stop the reply: cancel synthesis in flight, drop everything not yet played.
    func cancel(_ interruption: SpeechDeliveryOutcome.Interruption) {
        guard !schedule.isCancelled, !schedule.isComplete else { return }
        self.interruption = interruption
        _ = schedule.cancel()
        for task in synthesisTasks.values { task.cancel() }
        synthesisTasks.removeAll()
        audio.removeAll()
        playbackTask?.cancel()
        PrivacyLog.tts(.streamedReplyInterrupted, count: schedule.heardCount,
                       total: schedule.items.count, detail: PrivacyToken(interruption.rawValue))
        Task { await self.settle() }
    }

    private func perform(_ actions: [StreamedReplySchedule.Action]) {
        for action in actions {
            switch action {
            case .synthesize(let index, let engine):
                startSynthesis(index: index, engine: engine)
            case .play(let index, let engine):
                startPlayback(index: index, engine: engine)
            }
        }
    }

    private func startSynthesis(index: Int, engine: TTSEngine) {
        guard let backend else { return }
        let text = schedule.items[index].text
        synthesisTasks[index] = Task { [weak self] in
            do {
                let prepared = try await backend.synthesizeStreamedSentence(text, engine: engine)
                self?.synthesized(index: index, engine: engine, result: .success(prepared))
            } catch {
                self?.synthesized(index: index, engine: engine, result: .failure(error))
            }
        }
    }

    private func synthesized(index: Int, engine: TTSEngine, result: Result<StreamedSpeechAudio, Error>) {
        synthesisTasks[index] = nil
        guard !schedule.isCancelled else { return }
        switch result {
        case .success(let prepared):
            audio[index] = prepared
            perform(schedule.synthesisSucceeded(index: index, engine: engine))
        case .failure(let error):
            if error is CancellationError { return }
            let line = (error as? StreamedSynthesisFailure)?.lineToAppend
            PrivacyLog.tts(.engineFallback, engine: PrivacyToken(engine.rawValue),
                           error: error is StreamedSynthesisFailure ? nil : SafeErrorSummary(error))
            let wasDemoted = schedule.demotedEngines.contains(engine)
            perform(schedule.synthesisFailed(index: index, engine: engine, appendingText: line))
            if schedule.demotedEngines.contains(engine), !wasDemoted {
                PrivacyLog.tts(.streamedCloudDemoted, engine: PrivacyToken(engine.rawValue),
                               count: StreamedReplySchedule.cloudFailuresBeforeDemotion)
            }
        }
        Task { await settle() }
    }

    private func startPlayback(index: Int, engine: TTSEngine) {
        playbackTask = Task { [weak self] in
            await self?.play(index: index, engine: engine)
        }
    }

    private func play(index: Int, engine: TTSEngine) async {
        guard let backend else { return }
        if !playbackBegan {
            playbackBegan = true
            PrivacyLog.tts(.streamedReplyStarted, engine: PrivacyToken(engine.rawValue))
            await backend.beginStreamedPlayback()
            onPlaybackBegan?()
        }
        guard !schedule.isCancelled else { return }
        // The conversation was reset while this reply was being written: nothing more of it plays.
        guard isCurrent() else {
            cancel(.stop)
            return
        }
        guard let prepared = audio.removeValue(forKey: index) else {
            perform(schedule.playbackEnded(index: index, completed: false))
            await settle()
            return
        }
        let text = schedule.items[index].text
        let outcome = await backend.playStreamedSentence(text, audio: prepared, engine: engine,
                                                     source: source)
        guard !schedule.isCancelled else { return }
        switch outcome {
        case .interrupted(let by):
            // Torn down by something other than this queue — another utterance took the floor.
            cancel(by)
            return
        case .completed:
            perform(schedule.playbackEnded(index: index, completed: true))
        case .suppressed, .failed:
            perform(schedule.playbackEnded(index: index, completed: false))
        }
        await settle()
    }

    /// When the reply is complete, end it once and release whoever is waiting on `finish()`.
    private func settle() async {
        guard schedule.isComplete, !ending else { return }
        ending = true
        let record = self.record
        if interruption == nil {
            PrivacyLog.tts(.streamedReplyFinished, count: record.heardCount, total: record.sentenceCount)
        }
        await backend?.streamedReplyDidEnd(self, record: record, playbackBegan: playbackBegan)
        hasEnded = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
