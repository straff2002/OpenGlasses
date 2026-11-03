import Foundation
@testable import OpenGlasses

/// Plan KK — shared fixtures for the timeline tests. An invented conversation: ids `u0`, `a0`,
/// `u1`, `a1`… one minute apart from Tuesday 3 November 2026, 09:00 UTC.
enum TimelineFixtures {

    static let start = Date(timeIntervalSince1970: 1_793_696_400)
    static let utc = TimeZone(identifier: "UTC")!

    /// `exchanges` user/assistant pairs, each message `tokens` estimated tokens.
    /// Built in typed steps: as one `flatMap` literal it timed out CI's type-checker.
    static func conversation(_ exchanges: Int, tokens: Int = 1_000) -> [TimelineMessage] {
        var messages: [TimelineMessage] = []
        for turn in 0..<exchanges {
            let asked: Date = minutes(Double(turn * 2))
            let answered: Date = minutes(Double(turn * 2 + 1))
            messages.append(TimelineMessage(id: "u\(turn)", role: "user", timestamp: asked, estimatedTokens: tokens))
            messages.append(TimelineMessage(id: "a\(turn)", role: "assistant", timestamp: answered,
                                            estimatedTokens: tokens))
        }
        return messages
    }

    /// An entry covering `messages[span]`.
    static func entry(_ id: String, _ messages: [TimelineMessage], _ span: ClosedRange<Int>,
                      tier: TimelineEntry.Tier = .chunk, text: String = "notes") -> TimelineEntry {
        TimelineEntry(id: id, firstMessageID: messages[span.lowerBound].id,
                      lastMessageID: messages[span.upperBound].id,
                      startedAt: messages[span.lowerBound].timestamp,
                      endedAt: messages[span.upperBound].timestamp, tier: tier, text: text)
    }

    static func minutes(_ count: Double) -> Date { start.addingTimeInterval(count * 60) }
}
