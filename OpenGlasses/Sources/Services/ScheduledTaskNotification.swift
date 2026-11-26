import Foundation
import UserNotifications

/// Where a scheduled task's result goes when the task is not set to speak it
/// (`AgentScheduler.ScheduledTask.speakResult` off, the default for new tasks): one silent
/// notification, so a result nobody was told about out loud still reaches the wearer.
///
/// No sound: a scheduled result is never chimed or spoken through the phone unless the wearer
/// turned Speak Result on for that task. Each task posts under its own identifier, so its next
/// result replaces the last one rather than stacking a banner per run. Lock-screen previews
/// follow the wearer's iOS setting.
enum ScheduledTaskNotification {
    static let threadIdentifier = "scheduled_task"
    static let logReason = PrivacyToken("scheduledTaskResult")

    /// The identifier one task's results post under.
    static func identifier(forTaskID taskID: String) -> String {
        "scheduled_task.\(taskID)"
    }

    /// The silent notification for one task's result.
    static func request(taskID: String, taskName: String, result: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = taskName
        content.body = result
        content.sound = nil
        content.threadIdentifier = threadIdentifier
        content.categoryIdentifier = threadIdentifier
        return UNNotificationRequest(identifier: identifier(forTaskID: taskID), content: content, trigger: nil)
    }

    static func postToCenter(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                PrivacyLog.agent(.notifications, .taskFailed, reason: logReason,
                                 error: SafeErrorSummary(error))
            }
        }
    }
}
