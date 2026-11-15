import Foundation

/// The "where was I?" card for the in-lens display (docs/plans/BT-reading-companion.md P3).
/// Pure content builder; `GlassesDisplayService.showNotification` owns rendering, capability
/// gating and restore-after-flash — a transient notification flashes over whatever card is held
/// (Now/Next, launcher) and restores it, so reading never has to manage the display's state.
enum ReadingHUDCard {

    /// Notification content for session start / "where was I?". `nil` when there's nothing read
    /// yet — no card beats an empty card on the lens.
    static func notification(stats: ReadingStats, progress: Double? = nil, streak: Int = 0)
        -> (title: String, body: String)? {
        guard stats.pageCount > 0 else { return nil }

        var parts = [String(localized: "\(stats.pageCount) page\(stats.pageCount == 1 ? "" : "s") read")]
        if let progress, progress > 0 {
            let percent = min(100, max(1, Int((progress * 100).rounded())))
            parts.append(String(localized: "about \(percent)% through"))
        }
        if stats.sessionCount > 1 {
            parts.append(String(localized: "\(stats.sessionCount) sittings"))
        }
        if streak > 1 {
            parts.append(String(localized: "\(streak)-day streak"))
        }
        return (title: stats.bookTitle, body: parts.joined(separator: " · "))
    }
}
