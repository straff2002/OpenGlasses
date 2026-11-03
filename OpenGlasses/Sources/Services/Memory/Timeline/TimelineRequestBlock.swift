import Foundation

/// Plan KK P3 — the conversation timeline in a cloud request: whether it goes in, what it shows,
/// and whether it replaces the omission note. Pure and table-tested; `LLMService` only glues it to
/// each route's request copy.
///
/// # Where coverage says it belongs
///
/// The block is decided per request copy, from what that copy left out. Coverage is
/// `TimelineCoverage.compute` with this request's own counts (real user turns kept and in the
/// history), the question being answered and the floor, so it agrees with the pass that wrote the
/// notes. Only entries that cover a message this request left out are shown: a note about
/// messages still in the request would show the same span twice.
///
/// - **Complete** (every message that left is covered, the cap dropped nothing, and the thread
///   holds at least as many left-out turns as the history says left): the block **replaces** the
///   omission note.
/// - **A gap**: the note stays, says that some of those messages are not in the notes
///   (`APIHistoryBudget.partialNotesSentence`), and the block follows it. P0 found a note whose
///   later correction sat in an uncovered run was read as current; a block is never shown over a
///   gap without that sentence.
///
/// The last condition is the guard on the count. The saved thread and the history share no ids,
/// so "left the request" is read from counts, and a turn the history holds but the thread never
/// saved (or a stale question id) would make a message that left look live, and hide a gap. The
/// history's own omitted part says how many real turns left; if the thread's eligible run holds
/// fewer, something that left is not in the notes, and the note stays.
///
/// # Cost
///
/// The block sits in the volatile tail, uncached, and is paid on every tool round. Its size is
/// taken off the history allowance before the budget runs (`historyAllowance`), so a request with
/// a block costs no more than one without; the ChatGPT budget counts it inside its own estimate.
enum TimelineRequestBlock {

    /// The active thread as the request builder sees it. Supplied by the app through a narrow
    /// source (`LLMService.timelineThreadSource`), never by handing the service the store.
    struct Thread: Equatable, Sendable {
        let messages: [TimelineMessage]
        let entries: [TimelineEntry]
        /// The saved question of the turn being answered, when the app knows it. Nil reads from
        /// the counts alone, which is safe: see the count guard above.
        let answeringMessageID: String?

        init(messages: [TimelineMessage], entries: [TimelineEntry], answeringMessageID: String? = nil) {
            self.messages = messages
            self.entries = entries
            self.answeringMessageID = answeringMessageID
        }
    }

    /// Why a request carries no block. A closed set, safe to log.
    enum Skip: String, Equatable, Sendable {
        case settingOff
        case hipaaMode
        case onDeviceModel
        /// Groq and the small-context setting: their request copies are cut without the budget,
        /// and the block would undo what the cut is for.
        case routeCarriesNoBlock
        case noThread
        /// No entry the block could ever show (none, all cleared by an erasure, all before the floor).
        case noEntries
        case nothingOmitted
        /// Something left, but no shown entry covers any of it.
        case nothingCovered
        /// The protected turn left no room for the block beside it, so the plain note went instead.
        case noRoom
    }

    /// Whether the active thread's timeline may go into this request at all, before any counting.
    /// The order gives each refusal its own reason, as `TimelinePassPolicy` does.
    static func gate(enabled: Bool, hipaaMode: Bool, provider: LLMProvider,
                     thread: Thread?) -> Skip? {
        guard enabled else { return .settingOff }
        // Owner decision 3: off in HIPAA mode, and the omission note stays.
        guard !hipaaMode else { return .hipaaMode }
        guard !RelationEnrichmentPolicy.isOnDevice(provider) else { return .onDeviceModel }
        guard let thread else { return .noThread }
        guard thread.entries.contains(where: { !$0.isRedacted }) else { return .noEntries }
        return nil
    }

    /// One request copy, as the decision reads it.
    struct Request: Equatable, Sendable {
        var thread: Thread
        /// This copy's counts: real user turns kept and in the history, the floors, and the real
        /// user turns left out after the floor.
        var reading: TimelineRequestReading
        /// Messages the copy left out, including any before the job floor. Zero means no block
        /// and no note.
        var omittedMessages: Int
        /// The most the block may cost: the size reserved for it, never more than the renderer's cap.
        var tokenCap: Int
    }

    struct Decision: Equatable, Sendable {
        /// The block, or nil.
        let text: String?
        /// True when the block replaces the omission note; false keeps the note.
        let replacesNote: Bool
        let renderedCount: Int
        let estimatedTokens: Int
        /// Why there is no block; nil when there is one.
        let skip: Skip?

        /// The note stays, and says the notes after it are not the whole of what left.
        var notesArePartial: Bool { text != nil && !replacesNote }

        static func skipped(_ reason: Skip) -> Decision {
            Decision(text: nil, replacesNote: false, renderedCount: 0, estimatedTokens: 0, skip: reason)
        }

        /// A log word: what the block did to the note, or why there was none.
        var logToken: String {
            if let skip { return skip.rawValue }
            return replacesNote ? "replacedNote" : "withNote"
        }
    }

    // MARK: - Reserving room

    /// The entries the block could show in this thread: not cleared by an erasure, not before the
    /// floor. Which of them this request needs is decided later, by what it left out.
    static func candidates(_ thread: Thread, floor: Date?) -> [TimelineEntry] {
        thread.entries.filter { entry in
            !entry.isRedacted && (floor.map { entry.startedAt >= $0 } ?? true)
        }
    }

    /// What to set aside for the block before the history budget runs: the whole candidate block
    /// at its largest (with the recall clause), but never more than `cap`. The block rendered later
    /// shows a subset of these entries under a label no longer than this one, so it is never larger
    /// than what was reserved; smaller is fine.
    static func reserve(_ thread: Thread, floor: Date?, timeZone: TimeZone,
                        cap: Int = TimelineRenderer.defaultTokenCap) -> Int {
        let entries = candidates(thread, floor: floor)
        guard !entries.isEmpty, cap > 0 else { return 0 }
        let whole = TimelineRenderer.render(entries: entries, floor: floor, coverageHasGaps: false,
                                            timeZone: timeZone, tokenCap: .max, recallOffered: true)
        return min(cap, whole.estimatedTokens)
    }

    /// The history allowance once the block's reserve is taken off, and the cap the block is then
    /// rendered to. An allowance of 0 turns trimming off, so nothing is reserved; the history never
    /// gets less than half the allowance, and the block gets only what was actually taken.
    static func historyAllowance(_ allowance: Int, reserve: Int) -> (history: Int, blockCap: Int) {
        guard allowance > 0, reserve > 0 else { return (allowance, 0) }
        let history = max(allowance / 2, allowance - reserve)
        return (history, allowance - history)
    }

    // MARK: - The decision

    /// The block for `request`, and whether it replaces the note.
    static func decide(_ request: Request, recallOffered: Bool, timeZone: TimeZone) -> Decision {
        guard request.omittedMessages > 0 else { return .skipped(.nothingOmitted) }
        let messages = request.thread.messages.filter(\.isConversational)
        let reading = request.reading
        let floor = reading.timelineFloor(in: messages)
        let coverage = TimelineCoverage.compute(
            messages: messages, keptUserTurns: reading.keptUserTurns,
            historyUserTurns: reading.historyUserTurns,
            answeringMessageID: request.thread.answeringMessageID, floor: floor,
            entries: request.thread.entries, minimumTokens: 0)

        // Only entries that cover something this request left out.
        let positions = TimelineEntry.positions(of: messages.map(\.id))
        let eligible = coverage.eligible
        guard !eligible.isEmpty else { return .skipped(.nothingCovered) }
        let shown = candidates(request.thread, floor: floor).filter { entry in
            guard let span = entry.span(in: positions) else { return false }
            return span.lowerBound < eligible.upperBound && span.upperBound >= eligible.lowerBound
        }
        guard !shown.isEmpty else { return .skipped(.nothingCovered) }

        let eligibleUserTurns = eligible.filter { messages[$0].role == "user" }.count
        let countsAgree = eligibleUserTurns >= reading.omittedUserTurns
        let rendered = TimelineRenderer.render(
            entries: shown, floor: floor, coverageHasGaps: coverage.hasGaps || !countsAgree,
            timeZone: timeZone, tokenCap: request.tokenCap, recallOffered: recallOffered)
        guard let text = rendered.text else { return .skipped(.nothingCovered) }
        return Decision(text: text, replacesNote: !rendered.hasGap, renderedCount: rendered.renderedCount,
                        estimatedTokens: rendered.estimatedTokens, skip: nil)
    }

    /// What follows the instructions for this request: the note, the block, or both, in that order.
    /// `note` builds the route's own omission note; its argument says whether the notes after it
    /// are partial. Nil when neither applies.
    static func workingContext(decision: Decision?, note: (_ partialNotes: Bool) -> String?) -> String? {
        guard let decision, let block = decision.text else { return note(false) }
        if decision.replacesNote { return block }
        return [note(true), block].compactMap { $0 }.joined(separator: "\n\n")
    }
}
