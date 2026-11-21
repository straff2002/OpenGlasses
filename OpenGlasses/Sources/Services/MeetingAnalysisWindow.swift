import Foundation

/// What one meeting-assistant round sends (`MeetingAnalysisSink.prompt(for:)`).
struct MeetingAnalysisRound: Equatable, Sendable {
    /// The previous round's running summary, nil before the first reply.
    let previousSummary: String?
    /// The last few hundred words said before `recent`, for context. Empty on the first round.
    let earlier: String
    /// The lines said since the last round, oldest first, one a line.
    let recent: String
    /// Lines said since the last round that did not fit in `recent` (the oldest of them).
    let omittedLines: Int
    /// The last line this round covers, so `complete` retires exactly these.
    let throughLine: UInt64
}

/// The meeting assistant's memory between rounds (pure, headless-tested): the lines since the
/// last round, a short tail of what came before them, and the last reply's summary. Everything
/// is bounded, so a round's prompt is the same size in minute five and in hour three, and fits a
/// small on-device model.
///
/// In memory only, like the caption history it is fed from.
struct MeetingAnalysisWindow: Equatable, Sendable {

    /// At most this much of the lines since the last round goes in a round, the newest kept
    /// (about 1,500 tokens). A round normally runs every 60 s or 100 words, far below it; it bites
    /// only when the model has been failing or slow.
    static let recentCharacters = 6_000
    /// How much of what came before the new lines goes with them: what a lecture's key point
    /// reads for context (`LectureKeyPointSink.earlierCharacters`).
    static let earlierCharacters = 1_200
    /// How much of the previous reply carries forward as the running summary.
    static let summaryCharacters = 1_500

    private struct Pending: Equatable, Sendable {
        let id: UInt64
        let text: String
        let words: Int
    }

    private var pending: [Pending] = []
    private var nextID: UInt64 = 0
    /// What was said before the pending lines, bounded to `earlierCharacters`.
    private(set) var earlier = ""
    /// The last reply's running summary, bounded to `summaryCharacters`.
    private(set) var summary: String?

    /// Words said since the last completed round: the early trigger's count.
    var pendingWordCount: Int { pending.reduce(0) { $0 + $1.words } }
    var hasPending: Bool { !pending.isEmpty }

    mutating func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        nextID += 1
        pending.append(Pending(id: nextID, text: trimmed,
                               words: trimmed.split(whereSeparator: \.isWhitespace).count))
        // Lines far beyond what a round can send are not worth holding: keep a round's worth and
        // a margin, so a model that never answers cannot grow this without bound.
        var characters = pending.reduce(0) { $0 + $1.text.count + 1 }
        while characters > Self.recentCharacters * 2, pending.count > 1 {
            let gone = pending.removeFirst()
            characters -= gone.text.count + 1
            retire(gone.text)
        }
    }

    /// The round to send now, or nil when nothing was said since the last one.
    func nextRound() -> MeetingAnalysisRound? {
        guard let last = pending.last else { return nil }
        var kept: [String] = []
        var size = 0
        for line in pending.reversed() {
            let cost = line.text.count + 1
            guard size + cost <= Self.recentCharacters || kept.isEmpty else { break }
            kept.append(line.text)
            size += cost
        }
        var recent = kept.reversed().joined(separator: "\n")
        if recent.count > Self.recentCharacters { recent = String(recent.suffix(Self.recentCharacters)) }
        return MeetingAnalysisRound(previousSummary: summary, earlier: earlier, recent: recent,
                                    omittedLines: pending.count - kept.count, throughLine: last.id)
    }

    /// A round answered: its lines become the past, and its reply the running summary. Lines said
    /// while the model was answering stay for the next round. A round that failed is never
    /// completed, so its lines go again next time.
    mutating func complete(_ round: MeetingAnalysisRound, reply: String) {
        while let first = pending.first, first.id <= round.throughLine {
            pending.removeFirst()
            retire(first.text)
        }
        let part = Self.summaryPart(of: reply)
        summary = part.isEmpty ? summary : String(part.prefix(Self.summaryCharacters))
    }

    /// The summary part of a reply in the notification's format (`SUMMARY: … QUESTIONS: …`), or
    /// the whole reply when it is not in that format (a lecture's key point).
    static func summaryPart(of reply: String) -> String {
        var text = reply
        if let start = text.range(of: "SUMMARY:", options: .caseInsensitive) {
            text = String(text[start.upperBound...])
        }
        if let end = text.range(of: "QUESTIONS:", options: .caseInsensitive) {
            text = String(text[..<end.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private mutating func retire(_ line: String) {
        earlier = earlier.isEmpty ? line : earlier + "\n" + line
        if earlier.count > Self.earlierCharacters {
            earlier = String(earlier.suffix(Self.earlierCharacters))
        }
    }
}
