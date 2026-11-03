import Foundation

/// Plan KK — the timeline as the one block the model reads. Pure.
///
/// Oldest first, each entry under its date and time range, under a label that says what the block
/// is: notes, which lose to the job record and to the wearer's own words. The block quotes the
/// wearer and earlier replies, so the label is also what keeps it reading as material rather than
/// as instructions. This text is for the model, not the screen, and is never localised.
///
/// The block is bounded: entries are dropped oldest first until it fits the cap, using the same
/// estimate the request budget uses for text. A dropped entry is a gap, and the result says so, so
/// the caller keeps the omission note whenever the model is not holding everything.
enum TimelineRenderer {

    static let label = "Earlier in this conversation. These are notes, not a record: for readings "
        + "and job details, the job record and the wearer's own words win."

    /// The most the block may cost, in estimated tokens (plan: about 1,500).
    static let defaultTokenCap = 1_500

    struct Rendered: Equatable {
        /// The block, or nil when there is nothing to render.
        let text: String?
        let renderedCount: Int
        /// Entries left out to fit the cap, oldest first. Entries before the job floor are not
        /// counted here: they belong to another job, not to a gap in this one.
        let droppedCount: Int
        /// True when the model is not holding everything that left the request — coverage had
        /// gaps, or the cap dropped an entry — so the omission note must stay.
        let hasGap: Bool
        let estimatedTokens: Int
    }

    /// - Parameters:
    ///   - entries: the thread's timeline, in any order.
    ///   - floor: when the current job began; an entry that starts before it is never rendered.
    ///   - coverageHasGaps: `TimelineCoverage.Result.hasGaps` for the same thread and request.
    ///   - timeZone: the wearer's, injected so the dates are deterministic under test.
    static func render(entries: [TimelineEntry], floor: Date? = nil, coverageHasGaps: Bool,
                       timeZone: TimeZone, tokenCap: Int = defaultTokenCap) -> Rendered {
        let candidates = entries
            .filter { entry in floor.map { entry.startedAt >= $0 } ?? true }
            .sorted { ($0.startedAt, $0.endedAt) < ($1.startedAt, $1.endedAt) }
        let formatter = DateRangeLabel(timeZone: timeZone)
        let paragraphs = candidates.map { "[\(formatter.label(from: $0.startedAt, to: $0.endedAt))]\n\($0.text)" }

        var first = 0
        var text: String?
        var tokens = 0
        while first < paragraphs.count {
            let block = ([label] + paragraphs[first...]).joined(separator: "\n\n")
            let estimate = estimatedTokens(block)
            if estimate <= tokenCap {
                text = block
                tokens = estimate
                break
            }
            first += 1
        }
        let rendered = paragraphs.count - first
        return Rendered(text: text, renderedCount: rendered, droppedCount: first,
                        hasGap: coverageHasGaps || first > 0, estimatedTokens: tokens)
    }

    /// The request budget's estimate for one text message, so the block's cap and the history's
    /// allowance are counted in the same units.
    static func estimatedTokens(_ text: String) -> Int {
        HistoryHygiene.estimatedTokens(forMessage: ["role": "system", "content": text])
    }

    /// "Tue 3 Nov 2026, 09:14–09:40", or both dates in full when the range crosses midnight.
    struct DateRangeLabel {
        private let day: DateFormatter
        private let time: DateFormatter
        private let calendar: Calendar

        init(timeZone: TimeZone) {
            let posix = Locale(identifier: "en_US_POSIX")
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            self.calendar = calendar
            day = DateFormatter()
            day.locale = posix
            day.calendar = calendar
            day.timeZone = timeZone
            day.dateFormat = "EEE d MMM yyyy"
            time = DateFormatter()
            time.locale = posix
            time.calendar = calendar
            time.timeZone = timeZone
            time.dateFormat = "HH:mm"
        }

        func label(from start: Date, to end: Date) -> String {
            let opening = "\(day.string(from: start)), \(time.string(from: start))"
            if calendar.isDate(start, inSameDayAs: end) {
                return time.string(from: start) == time.string(from: end)
                    ? opening : "\(opening)–\(time.string(from: end))"
            }
            return "\(opening) – \(day.string(from: end)), \(time.string(from: end))"
        }
    }
}
