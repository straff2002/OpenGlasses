import Foundation
@testable import OpenGlasses

/// Plan KK — shared fixtures for the timeline tests. An invented conversation: ids `u0`, `a0`,
/// `u1`, `a1`… one minute apart from Tuesday 3 November 2026, 09:00 UTC.
enum TimelineFixtures {

    static let start = Date(timeIntervalSince1970: 1_793_696_400)
    static let utc = TimeZone(identifier: "UTC")!

    /// `exchanges` user/assistant pairs, each message `tokens` estimated tokens.
    static func conversation(_ exchanges: Int, tokens: Int = 1_000) -> [TimelineMessage] {
        (0..<exchanges).flatMap { turn in
            [TimelineMessage(id: "u\(turn)", role: "user",
                             timestamp: start.addingTimeInterval(Double(turn * 2) * 60),
                             estimatedTokens: tokens),
             TimelineMessage(id: "a\(turn)", role: "assistant",
                             timestamp: start.addingTimeInterval(Double(turn * 2 + 1) * 60),
                             estimatedTokens: tokens)]
        }
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
