import Foundation
import UserNotifications

/// A spoken forget or correction that matched more than one fact, handed to the phone so the
/// wearer chooses (Plan GG P3). Carries only the phrase they used, to filter the Memory screen.
struct MemoryHandOff: Identifiable, Equatable {
    let id = UUID()
    let query: String
}

/// Tells the wearer, on the phone, that a choice is waiting. Content-free: the facts themselves
/// stay inside the app, behind the lock, and appear when it opens.
enum MemoryHandOffNotifier {
    static let identifier = "memory.handoff"

    static func post(center: UNUserNotificationCenter = .current()) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Choose which memory you meant",
                               comment: "Notification title when a spoken forget or correction matched more than one remembered fact.")
        content.body = String(localized: "Open Avenkin to pick the one to change.",
                              comment: "Notification body when a spoken forget or correction matched more than one remembered fact.")
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
