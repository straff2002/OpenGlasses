import Foundation

/// The approval row of §2, as a pure mapping from the activity trail: a `.held` entry the wearer
/// has not answered, from today or yesterday. P1's reader over `ActivityStore` hands its entries
/// here; the rule lives in one place so a held entry approved later can never be listed (§3).
enum OpenLoopApprovals {

    static func loops(from entries: [ActivityEntry], now: Date, calendar: Calendar) -> [OpenLoop] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        // P1: past its hold's lifetime an entry reads as expired, not waiting; and the same call
        // held more than once (a scheduled task retrying) is one question — its newest hold.
        let waiting = entries
            .filter { $0.kind == .held && $0.isAwaitingWearer(at: now) && $0.at >= yesterday && $0.at <= now }
            .sorted { $0.at > $1.at }
        var keys = Set<String>()
        return waiting
            .filter { entry in entry.holdKey.map { keys.insert($0).inserted } ?? true }
            .sorted { $0.at < $1.at }
            .map { entry in
                OpenLoop(id: id(for: entry), source: .approval, title: entry.title, since: entry.at,
                         action: .approve(entryID: entry.id))
            }
    }

    static func id(for entry: ActivityEntry) -> String {
        "held:\(entry.id.uuidString.lowercased())"
    }
}
