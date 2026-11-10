import Foundation
import UserNotifications

/// Pomodoro / focus timer that manages work and break cycles.
/// Tracks session state in UserDefaults so the LLM can report progress.
struct PomodoroTool: NativeTool {
    let name = "pomodoro"
    let description = "Start a Pomodoro focus session (25 min work, 5 min break), check status, or stop. Helps with productivity and time management."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "Action: 'start' to begin a focus session, 'status' to check current session, 'stop' to end the session, or 'start_break' to start a break."
            ],
            "work_minutes": [
                "type": "integer",
                "description": "Work duration in minutes. Defaults to 25."
            ],
            "break_minutes": [
                "type": "integer",
                "description": "Break duration in minutes. Defaults to 5."
            ],
            "task": [
                "type": "string",
                "description": "Optional description of what the user is working on."
            ]
        ],
        "required": ["action"]
    ]

    private static let stateKey = "pomodoro_state"

    private struct PomodoroState: Codable {
        let startTime: Date
        let durationMinutes: Int
        let isBreak: Bool
        let task: String?
        let sessionsCompleted: Int
    }

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String ?? "start").lowercased()

        switch action {
        case "start", "begin", "focus":
            return await startSession(args: args, isBreak: false)
        case "start_break", "break":
            return await startSession(args: args, isBreak: true)
        case "status", "check":
            return checkStatus()
        case "stop", "cancel", "end":
            return stopSession()
        default:
            return "Unknown action '\(action)'. Use: start, status, stop, or start_break."
        }
    }

    private func startSession(args: [String: Any], isBreak: Bool) async -> String {
        let previousState = loadState()
        var sessionsCompleted = previousState?.sessionsCompleted ?? 0

        // If finishing a work session to start break, increment count
        if isBreak, let prev = previousState, !prev.isBreak {
            sessionsCompleted += 1
        }

        let defaultMinutes = isBreak ? 5 : 25
        let minutes: Int
        if isBreak {
            minutes = (args["break_minutes"] as? Int) ?? defaultMinutes
        } else {
            minutes = (args["work_minutes"] as? Int) ?? defaultMinutes
        }
        let task = args["task"] as? String

        let state = PomodoroState(
            startTime: Date(),
            durationMinutes: minutes,
            isBreak: isBreak,
            task: task,
            sessionsCompleted: sessionsCompleted
        )
        saveState(state)

        // Schedule notification
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }

        // Remove old pomodoro notifications
        center.removePendingNotificationRequests(withIdentifiers: ["pomodoro-timer"])

        let content = UNMutableNotificationContent()
        if isBreak {
            content.title = "Break Over!"
            content.body = "Time to get back to work. You've completed \(sessionsCompleted) session\(sessionsCompleted == 1 ? "" : "s") so far."
        } else {
            content.title = "Focus Session Complete!"
            content.body = task != nil ? "Great work on \(task!)! Time for a break." : "Great work! Time for a break."
        }
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(minutes * 60), repeats: false)
        let request = UNNotificationRequest(identifier: "pomodoro-timer", content: content, trigger: trigger)
        let scheduled = (try? await center.add(request)) != nil
        // Plan LA: the session is running and its end is scheduled; without the notification the
        // wearer would not be told when it ends, so that is spoken.
        ActionCompletionReport.record(Self.startCompletion(isBreak: isBreak, minutes: minutes,
                                                           notificationScheduled: scheduled))

        if isBreak {
            return "Break started: \(minutes) minutes. You've completed \(sessionsCompleted) focus session\(sessionsCompleted == 1 ? "" : "s"). Relax!"
        }

        var msg = "Focus session started: \(minutes) minutes."
        if let task {
            msg += " Working on: \(task)."
        }
        msg += " I'll notify you when it's time for a break. Stay focused!"
        return msg
    }

    static func startCompletion(isBreak: Bool, minutes: Int, notificationScheduled: Bool) -> ActionCompletion {
        guard notificationScheduled else { return .partial(reason: .unverified) }
        return .done(summary: isBreak ? "Break \(minutes) minutes" : "Focus \(minutes) minutes")
    }

    private func checkStatus() -> String {
        guard let state = loadState() else {
            return "No active Pomodoro session. Say 'start a focus session' to begin one."
        }

        let elapsed = Date().timeIntervalSince(state.startTime)
        let totalSeconds = state.durationMinutes * 60
        let remaining = totalSeconds - Int(elapsed)

        if remaining <= 0 {
            let kind = state.isBreak ? "break" : "focus session"
            clearState()
            return "Your \(kind) ended \(formatAgo(Int(-remaining))) ago. \(state.isBreak ? "Ready to start another focus session?" : "Time for a break!")"
        }

        let mins = remaining / 60
        let secs = remaining % 60
        let kind = state.isBreak ? "break" : "focus session"
        var msg = "\(mins) minute\(mins == 1 ? "" : "s") and \(secs) second\(secs == 1 ? "" : "s") left in your \(kind)."
        if let task = state.task, !state.isBreak {
            msg += " Working on: \(task)."
        }
        msg += " Sessions completed today: \(state.sessionsCompleted)."
        return msg
    }

    private func stopSession() -> String {
        guard let state = loadState() else {
            return "No active Pomodoro session to stop."
        }

        let elapsed = Int(Date().timeIntervalSince(state.startTime))
        let kind = state.isBreak ? "break" : "focus session"

        // Remove notification
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["pomodoro-timer"])
        clearState()
        ActionCompletionReport.record(.done(summary: state.isBreak ? "Break stopped" : "Focus session stopped"))

        return "Stopped \(kind) after \(elapsed / 60) minutes. Total sessions completed: \(state.sessionsCompleted)."
    }

    private func formatAgo(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) seconds" }
        let mins = seconds / 60
        return "\(mins) minute\(mins == 1 ? "" : "s")"
    }

    // MARK: - Persistence

    private func loadState() -> PomodoroState? {
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey) else { return nil }
        return try? JSONDecoder().decode(PomodoroState.self, from: data)
    }

    private func saveState(_ state: PomodoroState) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
    }

    private func clearState() {
        UserDefaults.standard.removeObject(forKey: Self.stateKey)
    }
}
