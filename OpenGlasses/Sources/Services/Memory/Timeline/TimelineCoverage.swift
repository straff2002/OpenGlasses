import Foundation

/// Plan KK — which of a thread's saved messages have left the request, which of those the timeline
/// already covers, and what to summarise next. Pure and table-tested.
///
/// # Counting from the tail
///
/// The saved thread and the model's in-memory history share no ids, so "left the request" is
/// counted: a request that kept K user turns carries the thread's last K user messages, and
/// everything before the K-th from last is eligible. The count can be wrong in three known ways —
/// a replayed thread whose history leads with an injected summary, a legacy compaction that
/// shortened the history's head, and a turn that never reached the saved thread — and the rule for
/// all three is the plan's: **a gap is the defect, an overlap only wastes tokens.** So wherever two
/// readings disagree, the one that covers more wins.
///
/// # Chunks
///
/// The next chunk is the earliest uncovered run, cut on a message boundary at about
/// `maximumChunkTokens`. An open run (one that reaches the request's edge and is still growing)
/// waits until it holds `minimumChunkTokens`; a closed run (an uncovered hole with covered
/// messages after it, left by an erasure or a refused summary) can never grow, so it is returned
/// whatever its size rather than blocking every later chunk behind it.
enum TimelineCoverage {

    /// A pass starts when about this much has left the request uncovered (plan: about 5k).
    static let minimumChunkTokens = 5_000
    /// The most one chunk carries, so a summary has a bounded amount to keep.
    static let maximumChunkTokens = 8_000

    struct Chunk: Equatable {
        /// Positions in the conversational messages (`TimelineMessage.reduce`).
        let range: Range<Int>
        let messageIDs: [String]
        let startedAt: Date
        let endedAt: Date
        let estimatedTokens: Int

        var firstMessageID: String { messageIDs[0] }
        var lastMessageID: String { messageIDs[messageIDs.count - 1] }
    }

    struct Result: Equatable {
        /// Messages the request no longer carries, after the job floor. Positions in the
        /// conversational messages.
        let eligible: Range<Int>
        /// Maximal runs of eligible messages a usable entry covers.
        let covered: [Range<Int>]
        /// Maximal runs of eligible messages nothing covers, oldest first.
        let gaps: [Range<Int>]
        let uncoveredTokens: Int
        let nextChunk: Chunk?

        /// Whether the model would be missing something the omission note must still own up to.
        var hasGaps: Bool { !gaps.isEmpty }
    }

    /// - Parameters:
    ///   - messages: the thread's saved messages in order, as `TimelineMessage.reduce` gives them.
    ///     Anything that is not a user or assistant message is ignored.
    ///   - keptUserTurns: how many user turns the request still carries, counted from its tail.
    ///   - historyUserTurns: how many real user turns the in-memory history holds, when known (not
    ///     tool results, which ride as user messages on some providers). With it, a history whose
    ///     tail holds turns the thread never saved is read from the head as well, and the reading
    ///     that covers more wins. Nil reads from the tail alone.
    ///   - floor: when the current job began. Nothing before it is eligible, no chunk crosses it,
    ///     and an entry that starts before it covers nothing, because the renderer will never
    ///     show it.
    ///   - answeringMessageID: the saved message of the turn being answered, when it was saved.
    ///     It and everything after it are never eligible.
    ///   - entries: the thread's timeline as saved.
    static func compute(messages: [TimelineMessage], keptUserTurns: Int,
                        historyUserTurns: Int? = nil, answeringMessageID: String? = nil,
                        floor: Date? = nil,
                        entries: [TimelineEntry],
                        minimumTokens: Int = TimelineCoverage.minimumChunkTokens,
                        maximumTokens: Int = TimelineCoverage.maximumChunkTokens) -> Result {
        let messages = messages.filter(\.isConversational)
        let users = messages.indices.filter { messages[$0].role == "user" }
        let kept = max(0, keptUserTurns)

        // From the tail: the request kept more user turns than the thread holds, so the tail
        // reading finds nothing gone; the head reading below may still find some.
        var boundary = kept == 0 ? messages.count : (kept <= users.count ? users[users.count - kept] : 0)
        if let historyUserTurns, historyUserTurns > kept {
            let dropped = historyUserTurns - kept
            let fromHead = dropped < users.count ? users[dropped] : messages.count
            boundary = max(boundary, fromHead)
        }
        // The turn being answered is in the request whatever the count says, when the caller
        // knows it was saved. The last saved user message is not assumed to be it: turns that
        // never reached the thread are exactly when it is not.
        if let answeringMessageID, let live = messages.firstIndex(where: { $0.id == answeringMessageID }) {
            boundary = min(boundary, live)
        }

        var start = 0
        if let floor {
            start = messages.firstIndex { $0.timestamp >= floor } ?? messages.count
        }
        let eligible = start..<max(start, boundary)
        guard !eligible.isEmpty else { return .nothing(at: start) }

        var isCovered = Array(repeating: false, count: eligible.count)
        let positions = TimelineEntry.positions(of: messages.map(\.id))
        for entry in entries {
            if let floor, entry.startedAt < floor { continue }
            guard let span = entry.span(in: positions) else { continue }
            let lower = max(span.lowerBound, eligible.lowerBound)
            let upper = min(span.upperBound + 1, eligible.upperBound)
            guard lower < upper else { continue }
            for index in lower..<upper { isCovered[index - eligible.lowerBound] = true }
        }

        let covered = runs(in: eligible, where: { isCovered[$0 - eligible.lowerBound] })
        let gaps = runs(in: eligible, where: { !isCovered[$0 - eligible.lowerBound] })
        let uncoveredTokens = gaps.joined().reduce(0) { $0 + messages[$1].estimatedTokens }

        return Result(eligible: eligible, covered: covered, gaps: gaps,
                      uncoveredTokens: uncoveredTokens,
                      nextChunk: gaps.first.flatMap {
                          chunk(in: $0, of: messages, isClosed: $0.upperBound < eligible.upperBound,
                                minimum: minimumTokens, maximum: maximumTokens)
                      })
    }

    /// The front of `gap`, cut on a message boundary at `maximum`. Always at least one message,
    /// so a single long message is summarised on its own rather than never.
    private static func chunk(in gap: Range<Int>, of messages: [TimelineMessage], isClosed: Bool,
                              minimum: Int, maximum: Int) -> Chunk? {
        var end = gap.lowerBound
        var tokens = 0
        while end < gap.upperBound,
              end == gap.lowerBound || tokens + messages[end].estimatedTokens <= maximum {
            tokens += messages[end].estimatedTokens
            end += 1
        }
        // Cut short by the maximum means there is more behind it: waiting would never help.
        let cutByMaximum = end < gap.upperBound
        guard isClosed || cutByMaximum || tokens >= minimum else { return nil }
        let slice = messages[gap.lowerBound..<end]
        return Chunk(range: gap.lowerBound..<end, messageIDs: slice.map(\.id),
                     startedAt: slice.first!.timestamp, endedAt: slice.last!.timestamp,
                     estimatedTokens: tokens)
    }

    private static func runs(in range: Range<Int>, where test: (Int) -> Bool) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var runStart: Int?
        for index in range {
            if test(index) {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                runs.append(start..<index)
                runStart = nil
            }
        }
        if let start = runStart { runs.append(start..<range.upperBound) }
        return runs
    }
}

private extension TimelineCoverage.Result {
    static func nothing(at position: Int) -> TimelineCoverage.Result {
        .init(eligible: position..<position, covered: [], gaps: [], uncoveredTokens: 0, nextChunk: nil)
    }
}
