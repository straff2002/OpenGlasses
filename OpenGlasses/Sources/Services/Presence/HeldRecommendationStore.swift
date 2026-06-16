import Foundation
import Combine

/// One action the agent declined to take autonomously because presence had lowered the autonomy
/// ceiling (Plan W) — recorded to be surfaced when the user re-engages.
struct HeldRecommendation: Identifiable, Equatable {
    let id: UUID
    let date: Date
    /// Human-readable description of what was held, e.g. "send a message to Mom".
    let summary: String

    init(id: UUID = UUID(), date: Date, summary: String) {
        self.id = id
        self.date = date
        self.summary = summary
    }
}

/// Collects high-impact actions the [[SafetySupervisor]] held while the user was disengaged, and
/// produces a single spoken/HUD summary when they re-engage (Plan W). Capped so a long idle stretch
/// can't grow it without bound. The recording and the drain are deterministic and unit-tested; the
/// live wiring (router records on a ceiling block; `PresenceMonitor`'s idle→active transition
/// drains to TTS + HUD) lives in AppState.
@MainActor
final class HeldRecommendationStore: ObservableObject {
    @Published private(set) var held: [HeldRecommendation] = []

    /// Most recent N kept; older ones are dropped (with the oldest summarised as "…and N earlier").
    let cap: Int

    init(cap: Int = 10) {
        self.cap = max(1, cap)
    }

    var isEmpty: Bool { held.isEmpty }
    var count: Int { held.count }

    /// Record a held action. Trims to `cap`, keeping the most recent.
    func record(summary: String, at date: Date) {
        held.append(HeldRecommendation(date: date, summary: summary))
        if held.count > cap {
            held.removeFirst(held.count - cap)
        }
    }

    /// Remove and return everything held as one spoken line, or `nil` when nothing was held. Use on
    /// re-engagement: "While you were away, I held 2 suggestions: …".
    func drainSummary() -> String? {
        guard !held.isEmpty else { return nil }
        let items = held
        held.removeAll()
        if items.count == 1 {
            return "While you were away, I held one suggestion: \(items[0].summary)."
        }
        let list = items.map(\.summary).joined(separator: "; ")
        return "While you were away, I held \(items.count) suggestions: \(list)."
    }

    /// Discard everything without surfacing (e.g. user explicitly dismissed).
    func clear() { held.removeAll() }
}
