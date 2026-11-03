import Foundation

/// Plan KK P2 — the summary pass: after a reply is accepted, write up what has left the request
/// and is not yet covered, and merge old notes when enough have piled up.
///
/// It never stands in a turn's way. The caller starts it in its own task and does not wait; one
/// pass runs per thread at a time; it refuses when the store is locked, and every write is checked
/// again at save time, because the thread may have been edited, erased or deleted while the model
/// was answering. A failure leaves the range uncovered (the omission note still owns up to it) and
/// the thread backs off before trying again.
///
/// **The open run is covered at once.** P0 found the timeline only helps with complete coverage: a
/// note saying "7 pm" with the move to 7:45 still in an uncovered run gave the only outdated
/// answers of the whole run. So coverage is computed with no minimum, and whatever has left the
/// request is summarised after every reply, a chunk of at most `TimelineCoverage.maximumChunkTokens`
/// at a time, `maximumChunksPerPass` per pass so a long thread from before this feature catches up
/// over several replies rather than all at once.
///
/// Nothing here logs text: counts, sizes, durations and named reasons only.
@MainActor
final class TimelineSummaryPass {

    /// The most chunks one pass summarises. The rest wait for the next reply.
    static let maximumChunksPerPass = 3
    /// The most merges one pass writes.
    static let maximumMergesPerPass = 1

    /// The turn the pass follows.
    struct Turn: Equatable, Sendable {
        let threadID: String
        /// The saved user message the reply answered, when it was saved.
        let answeringMessageID: String?
        /// What the turn's last cloud request carried; nil when it built none.
        let reading: TimelineRequestReading?
    }

    /// The settings and spend readings the pass is decided on, read by the caller at the time of
    /// the turn, so this type never reads `Config` and the tests set every case.
    struct Settings: Equatable, Sendable {
        var enabled: Bool
        var hipaaMode: Bool
        var provider: LLMProvider?
        var atSpendCap: Bool
    }

    /// What a pass did. For tests and the log; never carries text.
    enum Report: Equatable {
        case skipped(TimelinePassPolicy.SkipReason)
        case ran(summarised: Int, merged: Int, stopped: Stop?)
    }

    /// Why a pass stopped before it ran out of work.
    enum Stop: Equatable, Error {
        /// The model call failed or its answer was refused; the thread backs off.
        case summaryFailed(String)
        /// The store refused the write; nothing is wrong with the model, so no backoff.
        case saveRefused(ConversationStore.TimelineSaveOutcome)
    }

    typealias Summarise = @MainActor (TimelineSummaryPrompt.Request) async throws -> TimelineSummaryCompletion

    private weak var store: ConversationStore?
    private let summarise: Summarise
    private let timeZone: () -> TimeZone
    private let clock: () -> Date

    private var running: Set<String> = []
    private var backoff: [String: TimelinePassBackoff] = [:]

    init(store: ConversationStore, summarise: @escaping Summarise,
         timeZone: @escaping () -> TimeZone = { .current }, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.summarise = summarise
        self.timeZone = timeZone
        self.clock = clock
    }

    /// Whether a pass for `threadID` is in flight. For tests.
    func isRunning(_ threadID: String) -> Bool { running.contains(threadID) }

    // MARK: - The pass

    @discardableResult
    func run(_ turn: Turn, settings: Settings) async -> Report {
        let thread = PrivateIdentifier(turn.threadID)
        let decision = TimelinePassPolicy.decide(.init(
            enabled: settings.enabled, hipaaMode: settings.hipaaMode, provider: settings.provider,
            hasRequestReading: turn.reading != nil,
            storeWritable: store?.isTimelineWritable ?? false,
            threadIsActive: store?.activeThreadId == turn.threadID,
            passRunning: running.contains(turn.threadID),
            backingOff: (backoff[turn.threadID]?.passesToSkip ?? 0) > 0,
            atSpendCap: settings.atSpendCap))
        if let reason = decision.skipReason {
            if reason == .backingOff { _ = backoff[turn.threadID]?.shouldSkip() }
            return skipped(reason, thread: thread)
        }
        guard let reading = turn.reading else { return skipped(.noRequestReading, thread: thread) }

        running.insert(turn.threadID)
        defer { running.remove(turn.threadID) }

        var summarised = 0
        var merged = 0
        var stop: Stop?
        chunks: while summarised < Self.maximumChunksPerPass {
            switch await summariseNextChunk(turn, reading: reading, thread: thread) {
            case .nothing: break chunks
            case .saved: summarised += 1
            case .stopped(let reason): stop = reason; break chunks
            }
        }
        if stop == nil {
            merges: while merged < Self.maximumMergesPerPass {
                switch await writeNextMerge(turn, reading: reading, thread: thread) {
                case .nothing: break merges
                case .saved: merged += 1
                case .stopped(let reason): stop = reason; break merges
                }
            }
        }

        if case .summaryFailed = stop {
            backoff[turn.threadID, default: TimelinePassBackoff()].recordFailure()
        } else if summarised + merged > 0 {
            backoff[turn.threadID] = nil
        }
        if summarised + merged == 0, stop == nil { return skipped(.nothingEligible, thread: thread) }
        return .ran(summarised: summarised, merged: merged, stopped: stop)
    }

    private enum Step {
        case nothing
        case saved
        case stopped(Stop)
    }

    /// Summarise and save the earliest uncovered chunk, if there is one.
    private func summariseNextChunk(_ turn: Turn, reading: TimelineRequestReading,
                                    thread: PrivateIdentifier) async -> Step {
        guard let store, store.isTimelineWritable,
              let saved = store.threads.first(where: { $0.id == turn.threadID }) else {
            return .stopped(.saveRefused(.storeUnavailable))
        }
        let messages = TimelineMessage.reduce(saved.messages)
        let coverage = TimelineCoverage.compute(
            messages: messages, keptUserTurns: reading.keptUserTurns,
            historyUserTurns: reading.historyUserTurns, answeringMessageID: turn.answeringMessageID,
            floor: Self.effectiveFloor(reading.floorDate, in: messages),
            entries: saved.timeline ?? [], minimumTokens: 0)
        guard let chunk = coverage.nextChunk else { return .nothing }

        let spoken = saved.messages.filter(Self.isConversational)
        let slice = Array(spoken[chunk.range])
        let request = TimelineSummaryPrompt.chunk(slice.map(TimelineSummaryPrompt.Line.init),
                                                  timeZone: timeZone())
        let started = clock()
        let text: String
        switch await summary(for: request, thread: thread) {
        case .failure(let stop): return .stopped(stop)
        case .success(let accepted): text = accepted
        }
        let checked = TimelineDetailCheck.check(summary: text,
                                                messages: slice.map(TimelineDetailCheck.Message.init),
                                                timeZone: timeZone())
        let entry = TimelineEntry(id: UUID().uuidString, firstMessageID: chunk.firstMessageID,
                                  lastMessageID: chunk.lastMessageID, startedAt: chunk.startedAt,
                                  endedAt: chunk.endedAt, tier: .chunk, text: checked.text)
        let outcome = store.saveTimelineChunk(entry, in: turn.threadID)
        guard outcome == .saved else { return refused(outcome, thread: thread) }
        PrivacyLog.conversation(.conversations, .timelineSummarised, thread: thread,
                                count: chunk.messageIDs.count, characters: checked.text.count,
                                tokens: chunk.estimatedTokens,
                                milliseconds: Self.milliseconds(from: started, to: clock()),
                                detail: PrivacyToken("restored\(checked.restoredLines.count)"))
        return .saved
    }

    /// Merge the oldest run of entries the planner says is due, if any.
    private func writeNextMerge(_ turn: Turn, reading: TimelineRequestReading,
                                thread: PrivateIdentifier) async -> Step {
        guard let store, store.isTimelineWritable,
              let saved = store.threads.first(where: { $0.id == turn.threadID }) else {
            return .stopped(.saveRefused(.storeUnavailable))
        }
        let messages = TimelineMessage.reduce(saved.messages)
        let floor = Self.effectiveFloor(reading.floorDate, in: messages)
        // Notes from before the job are never shown, so they are never worth a merge.
        let entries = (saved.timeline ?? []).filter { entry in floor.map { entry.startedAt >= $0 } ?? true }
        guard let plan = TimelineMergePlanner.nextMerge(entries: entries, messageIDs: messages.map(\.id)) else {
            return .nothing
        }
        let sources = plan.sourceIDs.compactMap { id in entries.first { $0.id == id } }
        let request = TimelineSummaryPrompt.merge(sources, timeZone: timeZone())
        let started = clock()
        let text: String
        switch await summary(for: request, thread: thread) {
        case .failure(let stop): return .stopped(stop)
        case .success(let accepted): text = accepted
        }
        // The figures the wearer said anywhere in the merged span must survive the second
        // paraphrase as they survived the first.
        let positions = TimelineEntry.positions(of: messages.map(\.id))
        let spoken = saved.messages.filter(Self.isConversational)
        let spanMessages: [ConversationMessage]
        if let first = positions[plan.firstMessageID], let last = positions[plan.lastMessageID], first <= last {
            spanMessages = Array(spoken[first...last])
        } else {
            spanMessages = []
        }
        let checked = TimelineDetailCheck.check(summary: text,
                                                messages: spanMessages.map(TimelineDetailCheck.Message.init),
                                                timeZone: timeZone())
        let mergedEntry = plan.entry(id: UUID().uuidString, text: checked.text)
        let outcome = store.applyTimelineMerge(plan, merged: mergedEntry, in: turn.threadID, sources: sources)
        guard outcome == .saved else { return refused(outcome, thread: thread) }
        PrivacyLog.conversation(.conversations, .timelineMerged, thread: thread,
                                count: sources.count, characters: checked.text.count,
                                milliseconds: Self.milliseconds(from: started, to: clock()),
                                detail: PrivacyToken(plan.sourceTier.rawValue))
        return .saved
    }

    /// One call through the seam, kept only if the acceptance policy keeps it.
    private func summary(for request: TimelineSummaryPrompt.Request,
                         thread: PrivateIdentifier) async -> Result<String, Stop> {
        let completion: TimelineSummaryCompletion
        do {
            completion = try await summarise(request)
        } catch {
            let reason = (error as? TimelineSummaryError)?.rawValue ?? "error"
            PrivacyLog.conversation(.conversations, .timelineSummaryFailed, thread: thread,
                                    detail: PrivacyToken(reason), error: SafeErrorSummary(error))
            return .failure(.summaryFailed(reason))
        }
        switch TimelineSummaryAcceptance.evaluate(completion.text, tier: request.tier,
                                                  finishedNormally: completion.finishedNormally) {
        case .accepted(let text):
            return .success(text)
        case .rejected(let rejection):
            PrivacyLog.conversation(.conversations, .timelineSummaryFailed, thread: thread,
                                    characters: completion.text.count,
                                    detail: PrivacyToken(rejection.rawValue))
            return .failure(.summaryFailed(rejection.rawValue))
        }
    }

    private func refused(_ outcome: ConversationStore.TimelineSaveOutcome, thread: PrivateIdentifier) -> Step {
        PrivacyLog.conversation(.conversations, .timelineSaveRefused, thread: thread,
                                detail: PrivacyToken(outcome.rawValue))
        return .stopped(.saveRefused(outcome))
    }

    private func skipped(_ reason: TimelinePassPolicy.SkipReason, thread: PrivateIdentifier) -> Report {
        if reason.isWorthLogging {
            PrivacyLog.conversation(.conversations, .timelinePassSkipped, thread: thread,
                                    detail: PrivacyToken(reason.rawValue))
        }
        return .skipped(reason)
    }

    // MARK: - Pure helpers

    /// The job floor as the saved thread sees it. The floor's date is when the turn that set it
    /// started, which is a moment *after* that turn's question was saved; read as it is, it would
    /// leave the job's first question before the floor, never summarised once it left the request.
    /// So the floor moves back to the last user message at or before that date: the question that
    /// opened the job. With no user message before it, the date stands.
    nonisolated static func effectiveFloor(_ date: Date?, in messages: [TimelineMessage]) -> Date? {
        guard let date else { return nil }
        let opening = messages.last { $0.role == "user" && $0.timestamp <= date }
        return opening?.timestamp ?? date
    }

    /// The messages `TimelineMessage.reduce` keeps, as full messages, so positions agree.
    nonisolated static func isConversational(_ message: ConversationMessage) -> Bool {
        message.role == "user" || message.role == "assistant"
    }

    nonisolated static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1_000).rounded()))
    }
}
