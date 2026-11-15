import Foundation
import UserNotifications

/// The notification for an update from the office on a job this phone holds
/// (Contracts/job-updates.md; Plan HN §3).
///
/// **It is only a notification.** It says which job and what kind of update — "Job 1007: parts
/// update" — and never the update's own text: that is the office's words about a customer's job,
/// and a lock screen is not where they are read. Nothing starts, pauses or opens because of it,
/// and a tap goes to the Job tab, where the job's row carries the same mark.
///
/// One notification a job, replacing itself, so three updates on one job are one line. It is
/// taken away when the technician has the job open with its updates on it.
enum JobUpdateNotifications {

    static let identifierPrefix = "field-assist.office-update."
    static let title = String(localized: "Update from the office")

    static func identifier(jobID: String) -> String { identifierPrefix + jobID }

    /// What kind of update it is, in the technician's words. A kind this build does not know is
    /// an update all the same.
    static func kindWords(_ updateKind: String) -> String {
        switch updateKind {
        case "parts": return String(localized: "parts update")
        case "schedule": return String(localized: "new time")
        case "note": return String(localized: "note from the office")
        default: return String(localized: "update")
        }
    }

    /// "Job 1007: parts update". A job with no number is not given one.
    static func body(jobLabel: String?, updateKind: String) -> String {
        let words = kindWords(updateKind)
        guard let jobLabel, !jobLabel.isEmpty else {
            return String(localized: "One of your jobs: \(words)")
        }
        return "\(jobLabel): \(words)"
    }

    /// Whether a notification is one of these, by its identifier.
    static func isUpdate(identifier: String) -> Bool { identifier.hasPrefix(identifierPrefix) }

    /// Post it, asking for permission the first time and giving up quietly if refused: the Jobs
    /// list carries the same fact for a technician who has said no to notifications.
    @MainActor
    static func post(jobID: String, jobLabel: String?, updateKind: String,
                     center: UNUserNotificationCenter = .current()) {
        Task { @MainActor in
            let settings = await center.notificationSettings()
            do {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    break
                case .notDetermined:
                    guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
                case .denied:
                    return
                @unknown default:
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body(jobLabel: jobLabel, updateKind: updateKind)
                content.sound = .default
                content.userInfo = [JobSendNotifications.openTabKey: MainTab.job.rawValue]
                let request = UNNotificationRequest(identifier: identifier(jobID: jobID), content: content, trigger: nil)
                try await center.add(request)
            } catch {
                // The Jobs list still shows the update if notifications are unavailable.
            }
        }
    }

    /// The technician has the job open: its notification has said what it had to.
    @MainActor
    static func clear(jobID: String, center: UNUserNotificationCenter = .current()) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier(jobID: jobID)])
        center.removeDeliveredNotifications(withIdentifiers: [identifier(jobID: jobID)])
    }

    /// Every one of them, for leaving the organisation.
    @MainActor
    static func clearAll(center: UNUserNotificationCenter = .current()) {
        Task { @MainActor in
            let delivered = await center.deliveredNotifications()
            let ours = delivered.map(\.request.identifier).filter(isUpdate(identifier:))
            guard !ours.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: ours)
        }
    }
}
