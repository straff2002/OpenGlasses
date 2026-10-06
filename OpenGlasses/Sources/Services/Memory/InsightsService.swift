import Foundation
import Combine

/// Memory & Recall Phase 4 — builds an on-device usage recap from conversation history via the
/// pure `InsightsAggregator`. Read-only and on-demand (no background work, no network): top
/// topics + activity over a window, surfaced in Settings and as a spoken recap (`brain insights`).
///
/// `buildEvents(from:)` is pure (plain `ConversationThread` in → `InsightEvent` out) so the
/// mapping is unit-testable without `ConversationStore`'s file/encryption side effects.
@MainActor
final class InsightsService: ObservableObject {
    static let shared = InsightsService()

    private weak var conversationStore: ConversationStore?

    init() {}

    func configure(conversationStore: ConversationStore) {
        self.conversationStore = conversationStore
    }

    /// Aggregate the last `days` of conversation history into a report.
    func report(days: Int = 7, now: Date = Date()) -> InsightsReport {
        let since = Calendar.current.date(byAdding: .day, value: -max(1, days), to: now) ?? now
        let events = Self.buildEvents(from: conversationStore?.threads ?? [])
        return InsightsAggregator.aggregate(events, since: since, now: now)
    }

    /// A friendly spoken/return recap of a report.
    func recapText(_ report: InsightsReport, days: Int) -> String {
        guard report.totalTurns > 0 else {
            return "Nothing to report from the last \(days) day\(days == 1 ? "" : "s") — we haven't talked much."
        }
        var line = "In the last \(days) day\(days == 1 ? "" : "s") we've had \(report.userTurns) exchange\(report.userTurns == 1 ? "" : "s")"
        if !report.topTopics.isEmpty {
            line += ", mostly about " + report.topTopics.prefix(3).map(\.name).joined(separator: ", ")
        }
        if let tool = report.topTools.first {
            line += ". Your most-used tool was \(tool.name)"
        }
        return line + "."
    }

    /// Map conversation threads' messages to insight events (pure).
    static func buildEvents(from threads: [ConversationThread]) -> [InsightEvent] {
        threads.flatMap { thread in
            thread.messages.map { msg in
                InsightEvent(timestamp: msg.timestamp, role: msg.role,
                             toolNames: msg.toolNames ?? [], text: msg.content)
            }
        }
    }
}
