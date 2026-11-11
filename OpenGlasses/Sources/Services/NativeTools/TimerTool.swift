import Foundation
import UserNotifications

/// Sets a timer using local notifications. No external API needed.
struct TimerTool: NativeTool {
    let name = "set_timer"
    let description = "Set a timer that will notify the user after the specified duration."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "seconds": [
                "type": "integer",
                "description": "Timer duration in seconds"
            ],
            "label": [
                "type": "string",
                "description": "Optional label for the timer, e.g. 'pasta' or 'break time'"
            ]
        ],
        "required": ["seconds"]
    ]

    /// The wearer's words for this call's turn, when there are any to check against.
    var utterance: () -> String? = RelativeTimeGuard.utteranceForCurrentCall

    func execute(args: [String: Any]) async throws -> String {
        // "Set a timer for 15 minutes" in the wearer's own words beats the model's conversion
        // (see `RelativeTimeGuard`).
        let resolution = TimerDurationResolution.resolve(modelArgument: args["seconds"],
                                                         utterance: utterance())
        if let disagreement = resolution.overridden {
            RelativeTimeGuard.logOverride(tool: name, disagreement)
        }
        guard let seconds = resolution.seconds else {
            return "Missing timer duration."
        }

        guard seconds > 0 && seconds <= 86400 else {
            return "Timer must be between 1 second and 24 hours."
        }

        let label = args["label"] as? String

        // Request notification permission
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            if !granted {
                return "Timer set for \(formatDuration(seconds)), but notifications are disabled. You won't get an alert."
            }
        }

        let requestId = try await Self.scheduleNotification(seconds: seconds, label: label)
        // Plan KX §6: the lens's timer card hears it finish while the app runs.
        let fireAt = Date().addingTimeInterval(TimeInterval(seconds))
        await MainActor.run {
            TimerCompletionWatch.shared.timerScheduled(id: requestId, label: label, fireAt: fireAt)
        }

        let durationStr = formatDuration(seconds)
        if let label {
            return "Timer set: \(label) for \(durationStr)."
        }
        return "Timer set for \(durationStr)."
    }

    /// Schedule the timer's notification and return its request id. Also what the lens's **+5 min**
    /// sets again (Plan KX §6), so a timer set from the glasses is the same timer.
    static func scheduleNotification(seconds: Int, label: String?) async throws -> String {
        let content = UNMutableNotificationContent()
        content.title = label ?? "Timer"
        content.body = label.map { "Your \($0) timer is done!" } ?? "Timer complete!"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        let requestId = "timer-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: requestId, content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
        return requestId
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds) second\(seconds == 1 ? "" : "s")"
        }
        let mins = seconds / 60
        let secs = seconds % 60
        if mins < 60 {
            if secs == 0 {
                return "\(mins) minute\(mins == 1 ? "" : "s")"
            }
            return "\(mins) minute\(mins == 1 ? "" : "s") and \(secs) second\(secs == 1 ? "" : "s")"
        }
        let hours = mins / 60
        let remainMins = mins % 60
        if remainMins == 0 {
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        }
        return "\(hours) hour\(hours == 1 ? "" : "s") and \(remainMins) minute\(remainMins == 1 ? "" : "s")"
    }
}
