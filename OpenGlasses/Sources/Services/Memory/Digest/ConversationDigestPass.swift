import Foundation

/// Plan LQ §2 — the note pass: when a conversation is left, write its note; when the app comes to
/// the foreground, write the notes that were missed.
///
/// It hangs on `ConversationStore.onThreadLeft`, beside the brain's distillation, because every
/// way of leaving a thread goes through it: an end, the idle gap, start fresh, and a replace. It
/// never stands in a turn's way: a thread left while a turn is running waits in `pending` until the
/// turn's reply is accepted (`drain`). One call per thread at a time; a failure backs the thread
/// off (`TimelinePassBackoff`); and every write is checked again at save time, the organisation's
/// pin included, because anything may have changed while the model was answering.
///
/// Each call is decided afresh from `settings()`, so a pin, a switch or HIPAA mode that arrives
/// while the backlog runs stops it before the next thread.
///
/// Nothing here logs text: counts, sizes, durations and named reasons only.
@MainActor
final class ConversationDigestPass {

    /// The settings a call is decided on, read by the caller each time it is asked, so this type
    /// never reads `Config` and the tests set every case.
    struct Settings: Equatable, Sendable {
        var orgPinnedOff: Bool
        var enabled: Bool
        var hipaaMode: Bool
        var provider: LLMProvider?
        var inForeground: Bool
        var atSpendCap: Bool
        /// Every thread a Field Assist session, open or ended, or the debrief names.
        var jobThreadIDs: Set<String>

        /// What a caller that has gone away reads: nothing is written.
        static let refused = Settings(orgPinnedOff: false, enabled: false, hipaaMode: false, provider: nil,
                                      inForeground: false, atSpendCap: false, jobThreadIDs: [])
    }

    /// What one call did. For tests and the log; never carries text.
    enum Report: Equatable {
        case skipped(ConversationDigestPolicy.SkipReason)
        /// An on-device model while backgrounded: left to the backlog.
        case deferred
        case ineligible(ConversationDigestEligibility.Reason)
        /// Nothing new from the wearer to describe.
        case nothingToSend
        case written(points: Int, dropped: Int)
        case failed(String)
        case saveRefused(ConversationStore.DigestSaveOutcome)
    }

    typealias Summarise = @MainActor (ConversationDigestInput.Request) async throws -> ConversationDigestCompletion

    private weak var store: ConversationStore?
    private let summarise: Summarise
    private let isUntrustedTool: @MainActor (String) -> Bool
    private let timeZone: () -> TimeZone
    private let clock: () -> Date

    private var running: Set<String> = []
    private var backoff: [String: TimelinePassBackoff] = [:]
    /// Threads left while a turn was running, oldest first.
    private(set) var pending: [String] = []

    init(store: ConversationStore, summarise: @escaping Summarise,
         isUntrustedTool: @escaping @MainActor (String) -> Bool = { ConversationDigestInput.isUntrustedByName($0) },
         timeZone: @escaping () -> TimeZone = { .current }, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.summarise = summarise
        self.isUntrustedTool = isUntrustedTool
        self.timeZone = timeZone
        self.clock = clock
    }

    func isRunning(_ threadID: String) -> Bool { running.contains(threadID) }

    // MARK: - Queue

    /// Hold a left thread until the turn that left it has been answered.
    func enqueue(_ threadID: String) {
        guard !pending.contains(threadID) else { return }
        pending.append(threadID)
    }

    /// Write every held thread's note, one at a time.
    @discardableResult
    func drain(settings: @MainActor () -> Settings) async -> [Report] {
        var reports: [Report] = []
        while !pending.isEmpty {
            let threadID = pending.removeFirst()
            reports.append(await run(threadID: threadID, settings: settings))
        }
        return reports
    }

    // MARK: - Backlog

    /// The notes that qualified and were not written, newest first, at most what is left of
    /// today's allowance, one thread at a time. A thread that is deferred, refused or fails stays
    /// for a later foreground; only a written note counts against the day.
    @discardableResult
    func runBacklog(settings: @MainActor () -> Settings,
                    ledger: ConversationDigestBacklogLedger) async -> [Report] {
        guard let store, store.isTimelineWritable else { return [] }
        let now = clock()
        let first = settings()
        // A pin or the switch stops the backlog before anything is chosen.
        switch ConversationDigestPolicy.decide(conditions(first, thread: nil)) {
        case .deferred: return []
        case .skip(let reason) where Self.stopsTheBacklog(reason): return []
        case .skip, .run: break
        }
        let chosen = ConversationDigestBacklog.select(
            threads: store.threads, activeThreadID: store.activeThreadId,
            jobThreadIDs: first.jobThreadIDs, since: ledger.since(now: now), now: now,
            remaining: ledger.remaining(now: now))
        guard !chosen.isEmpty else { return [] }
        PrivacyLog.conversation(.conversations, .digestBacklog, count: chosen.count)
        var reports: [Report] = []
        for threadID in chosen {
            let report = await run(threadID: threadID, settings: settings)
            reports.append(report)
            if case .written = report { ledger.recordWrite(now: clock()) }
            // A refusal that holds for every thread ends the run rather than repeating itself.
            if case .skipped(let reason) = report, Self.stopsTheBacklog(reason) { break }
            if report == .deferred { break }
        }
        return reports
    }

    nonisolated static func stopsTheBacklog(_ reason: ConversationDigestPolicy.SkipReason) -> Bool {
        switch reason {
        case .orgPinnedOff, .settingOff, .hipaaMode, .noModel, .storeUnavailable, .spendCap: return true
        case .providerChanged, .threadGone, .passRunning, .backingOff: return false
        }
    }

    // MARK: - One thread

    @discardableResult
    func run(threadID: String, settings: @MainActor () -> Settings) async -> Report {
        let thread = PrivateIdentifier(threadID)
        let current = settings()
        let saved = store?.threads.first { $0.id == threadID }
        switch ConversationDigestPolicy.decide(conditions(current, thread: saved, threadID: threadID)) {
        case .deferred:
            return .deferred
        case .skip(let reason):
            if reason == .backingOff { _ = backoff[threadID]?.shouldSkip() }
            return skipped(reason, thread: thread)
        case .run:
            break
        }
        guard let store, let saved else { return skipped(.threadGone, thread: thread) }
        let verdict = ConversationDigestEligibility.check(saved, jobThreadIDs: current.jobThreadIDs)
        if let reason = verdict.reason { return .ineligible(reason) }
        // The registry answers on the main actor; the pure builder gets the answer for this thread.
        let untrusted = Set(saved.messages.flatMap { $0.toolNames ?? [] }.filter { isUntrustedTool($0) })
        guard let request = ConversationDigestInput.build(thread: saved, isUntrustedTool: { untrusted.contains($0) },
                                                          timeZone: timeZone()) else {
            return .nothingToSend
        }

        running.insert(threadID)
        defer { running.remove(threadID) }
        let started = clock()
        let completion: ConversationDigestCompletion
        do {
            completion = try await summarise(request)
        } catch {
            let reason = (error as? ConversationDigestError)?.rawValue ?? "error"
            return failed(reason, threadID: threadID, error: SafeErrorSummary(error))
        }

        let messages = (store.threads.first { $0.id == threadID } ?? saved).messages
            .filter(TimelineSummaryPass.isConversational).map(\.content)
        let headline: String
        let points: [ConversationDigest.Point]
        let dropped: [ConversationDigestAcceptance.DropReason]
        switch ConversationDigestAcceptance.evaluate(completion, messages: messages) {
        case .rejected(let rejection):
            return failed(rejection.rawValue, threadID: threadID, error: nil)
        case .accepted(let keptHeadline, let keptPoints, let droppedPoints):
            headline = keptHeadline
            points = keptPoints
            dropped = droppedPoints
        }
        for (reason, count) in Dictionary(grouping: dropped, by: \.token).mapValues(\.count) {
            PrivacyLog.conversation(.conversations, .digestPointsDropped, thread: thread, count: count,
                                    detail: PrivacyToken(reason))
        }

        // Decided again before anything is kept: a pin, the switch or HIPAA mode may have arrived
        // while the model was answering. A call already in flight finishes; its note is dropped.
        let now = settings()
        if let reason = ConversationDigestPolicy.decide(
            conditions(now, thread: store.threads.first { $0.id == threadID }, threadID: threadID, ignoringRun: true)
        ).skipReason {
            return refused(Self.saveOutcome(for: reason), thread: thread)
        }
        let digest = ConversationDigest(
            headline: headline, points: points, coversThroughMessageID: request.coversThroughMessageID,
            writtenAt: clock(),
            tier: current.provider.map(RelationEnrichmentPolicy.isOnDevice) == true ? .onDevice : .cloud)
        let outcome = store.saveDigest(digest, for: threadID)
        guard outcome == .saved else { return refused(outcome, thread: thread) }
        backoff[threadID] = nil
        PrivacyLog.conversation(.conversations, .digestWritten, thread: thread, count: points.count,
                                characters: digest.searchableText.count,
                                milliseconds: TimelineSummaryPass.milliseconds(from: started, to: clock()),
                                detail: PrivacyToken(digest.tier.rawValue))
        return .written(points: points.count, dropped: dropped.count)
    }

    // MARK: - Helpers

    private func conditions(_ settings: Settings, thread: ConversationThread?, threadID: String? = nil,
                            ignoringRun: Bool = false) -> ConversationDigestPolicy.Conditions {
        let id = threadID ?? thread?.id ?? ""
        return ConversationDigestPolicy.Conditions(
            orgPinnedOff: settings.orgPinnedOff, enabled: settings.enabled, hipaaMode: settings.hipaaMode,
            provider: settings.provider, threadProvider: thread?.lastAnswerProvider,
            inForeground: settings.inForeground,
            storeWritable: store?.isTimelineWritable ?? false,
            // The backlog's first look names no thread; it only asks whether notes may be written.
            threadExists: threadID == nil ? false : thread != nil,
            passRunning: !ignoringRun && running.contains(id),
            backingOff: !ignoringRun && (backoff[id]?.passesToSkip ?? 0) > 0,
            atSpendCap: settings.atSpendCap)
    }

    /// The save outcome a refusal at save time is logged as.
    nonisolated static func saveOutcome(for reason: ConversationDigestPolicy.SkipReason)
        -> ConversationStore.DigestSaveOutcome {
        switch reason {
        case .orgPinnedOff: return .orgPinnedOff
        case .threadGone: return .threadGone
        default: return .storeUnavailable
        }
    }

    private func failed(_ reason: String, threadID: String, error: SafeErrorSummary?) -> Report {
        backoff[threadID, default: TimelinePassBackoff()].recordFailure()
        PrivacyLog.conversation(.conversations, .digestFailed, thread: PrivateIdentifier(threadID),
                                detail: PrivacyToken(reason), error: error)
        return .failed(reason)
    }

    private func refused(_ outcome: ConversationStore.DigestSaveOutcome, thread: PrivateIdentifier) -> Report {
        PrivacyLog.conversation(.conversations, .digestSaveRefused, thread: thread,
                                detail: PrivacyToken(outcome.rawValue))
        return .saveRefused(outcome)
    }

    private func skipped(_ reason: ConversationDigestPolicy.SkipReason, thread: PrivateIdentifier) -> Report {
        if reason.isWorthLogging {
            PrivacyLog.conversation(.conversations, .digestSkipped, thread: thread,
                                    detail: PrivacyToken(reason.rawValue))
        }
        return .skipped(reason)
    }
}
