import Foundation

/// The part of a meeting's transcript `meeting_summary` hands the model: the whole meeting when it
/// fits the budget, otherwise lines picked from across all of it, so an hour-long meeting is not
/// read as its last few minutes. Pure and deterministic, so it is tested headlessly.
///
/// When the meeting does not fit, the lines the local extraction marked as action items or
/// decisions go in first (up to half the budget), then the meeting is cut into `sliceCount` equal
/// stretches of time and each stretch gets an equal share of what is left, taken as a run from the
/// start of the stretch; what one stretch leaves unused passes to the next. The header says how
/// many lines are shown of how many, and the time the meeting covers.
struct MeetingTranscriptExcerpt: Equatable, Sendable {

    /// One transcript line as the model reads it: `text` already carries a speaker label where the
    /// caption was diarized.
    struct Line: Equatable, Sendable {
        let text: String
        let timestamp: Date
    }

    /// The selected lines, rendered `[HH:mm:ss] text`, oldest first.
    let lines: [String]
    let shownCount: Int
    let totalCount: Int
    /// The first and last line of the whole meeting (not of the excerpt).
    let startedAt: Date?
    let endedAt: Date?
    /// Whether every pinned (action item / decision) line made it in.
    let allPinnedShown: Bool
    let timeZone: TimeZone

    var isComplete: Bool { shownCount == totalCount }
    var text: String { lines.joined(separator: "\n") }

    // MARK: - Budget

    /// How many stretches of time a cut-down excerpt is spread across.
    static let sliceCount = 12
    /// The budget when the model's window is unknown, or for a 4k-token on-device model: about
    /// 750 tokens, which leaves a 4k window room for the system prompt, the tool's other text and
    /// the reply.
    static let conservativeCharacters = 3_000
    static let minimumCharacters = 2_000
    /// Even a very large window gets at most this much (about 12k tokens): the excerpt is evidence
    /// beside a summary that is already worked out, not the whole record.
    static let maximumCharacters = 48_000

    /// A quarter of the model's window, at a conservative three characters a token, between the
    /// floor and the ceiling. Nil (an unknown window) takes the conservative budget.
    static func characterBudget(contextTokens: Int?) -> Int {
        guard let contextTokens, contextTokens > 0 else { return conservativeCharacters }
        let quarter = contextTokens / 4 * 3
        return min(maximumCharacters, max(minimumCharacters, quarter))
    }

    // MARK: - Selection

    /// The indices of the lines an action item or decision was read from.
    static func pinnedIndices(texts: [String], actionItems: [String], decisions: [String]) -> Set<Int> {
        let needles = (actionItems + decisions).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !needles.isEmpty else { return [] }
        var pinned = Set<Int>()
        for (index, text) in texts.enumerated() where needles.contains(where: { text.contains($0) }) {
            pinned.insert(index)
        }
        return pinned
    }

    static func make(lines: [Line], pinned: Set<Int> = [], budget: Int,
                     timeZone: TimeZone = .current) -> MeetingTranscriptExcerpt {
        let stamp = formatter("HH:mm:ss", timeZone: timeZone)
        let rendered = lines.map { "[\(stamp.string(from: $0.timestamp))] \($0.text)" }
        let costs = rendered.map { $0.count + 1 }
        let first = lines.map(\.timestamp).min()
        let last = lines.map(\.timestamp).max()

        func result(_ chosen: [Int]) -> MeetingTranscriptExcerpt {
            let set = Set(chosen)
            return MeetingTranscriptExcerpt(
                lines: chosen.sorted().map { rendered[$0] }, shownCount: chosen.count, totalCount: lines.count,
                startedAt: first, endedAt: last,
                allPinnedShown: pinned.filter { $0 < lines.count }.allSatisfy(set.contains),
                timeZone: timeZone)
        }

        if costs.reduce(0, +) <= budget { return result(Array(lines.indices)) }

        var chosen = Set<Int>()
        var spent = 0
        // Action items and decisions first, oldest first, within half the budget.
        for index in pinned.sorted() where index < lines.count {
            guard spent + costs[index] <= budget / 2 else { continue }
            chosen.insert(index)
            spent += costs[index]
        }

        // Then an equal share of what is left for each stretch of the meeting.
        let slices = Self.slices(lines.map(\.timestamp), count: sliceCount)
        var remaining = budget - spent
        for (position, slice) in slices.enumerated() {
            let allowance = remaining / (slices.count - position)
            var used = 0
            for index in slice where !chosen.contains(index) {
                guard used + costs[index] <= allowance else { break }
                chosen.insert(index)
                used += costs[index]
            }
            remaining -= used
        }
        return result(Array(chosen))
    }

    /// The line indices in each of `count` equal stretches of time, oldest stretch first. A
    /// meeting whose lines all share one time is cut by position instead.
    static func slices(_ timestamps: [Date], count: Int) -> [[Int]] {
        guard !timestamps.isEmpty, count > 0 else { return [] }
        guard let first = timestamps.min(), let last = timestamps.max() else { return [] }
        var buckets = Array(repeating: [Int](), count: count)
        let span = last.timeIntervalSince(first)
        for (index, timestamp) in timestamps.enumerated() {
            let bucket: Int
            if span > 0 {
                bucket = min(count - 1, Int(timestamp.timeIntervalSince(first) / span * Double(count)))
            } else {
                bucket = min(count - 1, index * count / timestamps.count)
            }
            buckets[bucket].append(index)
        }
        return buckets
    }

    // MARK: - Words

    /// `TRANSCRIPT (all 42 lines, 14:02–14:31):`, or, cut down,
    /// `TRANSCRIPT (412 of 1,980 lines shown, 14:02–15:10; …):`.
    var header: String {
        let range = startedAt.flatMap { start in endedAt.map { end in
            "\(Self.clock(start, timeZone: timeZone))–\(Self.clock(end, timeZone: timeZone))"
        } } ?? ""
        let span = range.isEmpty ? "" : ", \(range)"
        if isComplete {
            return "TRANSCRIPT (all \(Self.grouped(totalCount)) lines\(span)):"
        }
        let omitted = totalCount - shownCount
        let pinnedNote = allPinnedShown
            ? "every action-item and decision line is included"
            : "action-item and decision lines first"
        return "TRANSCRIPT (\(Self.grouped(shownCount)) of \(Self.grouped(totalCount)) lines shown\(span); "
            + "\(Self.grouped(omitted)) lines left out to fit, the rest taken from across the whole meeting, "
            + "\(pinnedNote)):"
    }

    static func time(_ date: Date, timeZone: TimeZone) -> String {
        formatter("HH:mm:ss", timeZone: timeZone).string(from: date)
    }

    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        formatter("HH:mm", timeZone: timeZone).string(from: date)
    }

    /// `1980` → `1,980`: the tool's text is model-facing English.
    static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return value < 0 ? "-" + out : out
    }

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
