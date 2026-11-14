import Foundation

/// The approval row of §2, as a pure mapping from the activity trail: a `.held` entry the wearer
/// has not answered, from today or yesterday. P1's reader over `ActivityStore` hands its entries
/// here; the rule lives in one place so a held entry approved later can never be listed (§3).
enum OpenLoopApprovals {

    static func loops(from entries: [ActivityEntry], now: Date, calendar: Calendar) -> [OpenLoop] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        return entries
            .filter { $0.kind == .held && $0.isAwaitingWearer && $0.at >= yesterday && $0.at <= now }
            .map { entry in
                OpenLoop(id: id(for: entry), source: .approval, title: entry.title, since: entry.at,
                         action: .approve(entryID: entry.id))
            }
    }

    static func id(for entry: ActivityEntry) -> String {
        "held:\(entry.id.uuidString.lowercased())"
    }
}
