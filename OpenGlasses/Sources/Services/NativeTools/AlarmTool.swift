import Foundation

/// Sets an alarm at a clock time (Plan JH). Unlike timers (relative delay), alarms fire at a
/// specific time of day.
///
/// First choice is a real alarm through AlarmKit (iOS 26): the system rings it like a Clock
/// alarm — full-screen on the lock screen, through silent mode and Focus — and it is the app's,
/// so it is **not listed in the Clock app**; every string the model sees says so. A tester asked
/// for seven o'clock, was told it was set, asked whether he would see it in the Clock app, was
/// told yes, found nothing, and asked the assistant not to claim an alarm it had not set. If the
/// wearer refuses the alarm permission the alarm falls back to a notification from the app, and
/// the result says that too, with why.
struct AlarmTool: NativeTool {
    let name = "set_alarm"
    let description = "Set an alarm for a specific time. Unlike a timer, an alarm fires at a clock time (e.g. '7:00 AM'). Supports 'tomorrow', specific dates, or today by default. The alarm rings on this iPhone like a Clock alarm — through silent mode and Focus, with a Stop button — but it belongs to this app: \(Wording.notClockApp) If the user asks where to see it, say the app's alarm list (ask me to list alarms); never say it is in the Clock app. If they want an alarm in the Clock app itself, tell them to set it there or ask Siri — you cannot."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "time": [
                "type": "string",
                "description": "The time for the alarm, e.g. '7:00 AM', '6:30', '22:00'"
            ],
            "date": [
                "type": "string",
                "description": "Date for the alarm: 'tomorrow', 'today', or 'YYYY-MM-DD'. Defaults to next occurrence of the time."
            ],
            "label": [
                "type": "string",
                "description": "Label for the alarm, e.g. 'Wake up', 'Take medicine'"
            ],
            "action": [
                "type": "string",
                "description": "Action: 'set' to create alarm, 'list' to show pending alarms, 'cancel_all' to remove all alarms. Defaults to 'set'."
            ]
        ],
        "required": [] as [String]
    ]

    /// The real alarm, where this device has one; nil goes straight to `fallback`.
    let realAlarm: (any AlarmScheduler)?
    /// The notification the tool always had.
    let fallback: any AlarmScheduler
    /// "Now", for the date arithmetic; tests pin it.
    let now: () -> Date

    init(realAlarm: (any AlarmScheduler)? = AlarmSchedulers.realAlarm,
         fallback: any AlarmScheduler = AlarmSchedulers.notification,
         now: @escaping () -> Date = Date.init) {
        self.realAlarm = realAlarm
        self.fallback = fallback
        self.now = now
    }

    /// The one fact about these alarms the model must never lose: they are the app's.
    enum Wording {
        static let notClockApp = "It is NOT an alarm in the iPhone's Clock app and never appears there."

        /// A real alarm was set.
        static func alarmSet(label: String, when: String, hoursUntil: Int, minutesUntil: Int) -> String {
            "Alarm set: \(label) at \(when)\(untilClause(hoursUntil, minutesUntil)). It will ring on this iPhone "
            + "like a Clock alarm, even on silent, with a Stop button. \(notClockApp)"
        }

        /// The notification fallback was used instead, and why.
        static func notificationSet(label: String, when: String, hoursUntil: Int, minutesUntil: Int,
                                    reason: AlarmBackendChoice.FallbackReason) -> String {
            let why: String
            switch reason {
            case .permissionDenied:
                why = "the alarm permission for this app is off (iPhone Settings > Apps > this app > Alarms turns it on)"
            case .unavailable:
                why = "this iPhone cannot ring a real alarm for this app"
            case .schedulingFailed:
                why = "the alarm could not be scheduled"
            }
            return "Alarm set as a notification from this app: \(label) at \(when)\(untilClause(hoursUntil, minutesUntil)). "
                + "It is a notification, not a ringing alarm — it will not sound if the phone is on silent — because \(why). "
                + notClockApp
        }

        static func listing(_ alarms: [ScheduledAlarm], real: Bool, format: (Date) -> String) -> String {
            guard !alarms.isEmpty else { return "No alarms set in this app." }
            let kind = real ? "alarm" : "notification alarm"
            let lines = alarms.map { "\($0.label): \(format($0.date))" }
            return "\(alarms.count) \(kind)\(alarms.count == 1 ? "" : "s") set in this app: "
                + "\(lines.joined(separator: ". ")). \(notClockApp)"
        }

        static func cancelled(_ count: Int) -> String {
            count == 0 ? "No alarms to cancel." : "Cancelled \(count) alarm\(count == 1 ? "" : "s")."
        }

        private static func untilClause(_ hours: Int, _ minutes: Int) -> String {
            if hours > 0 { return " (\(hours)h \(minutes)m from now)" }
            if minutes > 0 { return " (\(minutes) minutes from now)" }
            return ""
        }
    }

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String ?? "set").lowercased()

        switch action {
        case "list", "show":
            return await listAlarms()
        case "cancel_all", "cancel", "clear":
            return await cancelAllAlarms()
        default:
            return await setAlarm(args: args)
        }
    }

    /// When the alarm rings, from the model's arguments. Pure; nil with the reason when it cannot
    /// be read.
    static func resolveDate(time timeStr: String?, date dateStr: String?, now: Date,
                            calendar: Calendar = .current) -> Result<Date, ResolutionError> {
        guard let timeStr, !timeStr.isEmpty else { return .failure(.noTime) }
        guard let time = parseTime(timeStr, calendar: calendar) else { return .failure(.unreadableTime(timeStr)) }
        let dateStr = (dateStr ?? "").lowercased()
        if dateStr == "tomorrow" {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            return .success(calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: tomorrow)!)
        }
        if let parsed = parseDate(dateStr, now: now, calendar: calendar) {
            return .success(calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: parsed)!)
        }
        // Default: next occurrence (today if in the future, tomorrow if already passed)
        var target = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: now)!
        if target <= now {
            target = calendar.date(byAdding: .day, value: 1, to: target)!
        }
        return .success(target)
    }

    enum ResolutionError: Error, Equatable {
        case noTime
        case unreadableTime(String)

        var message: String {
            switch self {
            case .noTime:
                return "No time provided. Say something like 'set an alarm for 7 AM'."
            case .unreadableTime(let text):
                return "Couldn't parse time '\(text)'. Try formats like '7:00 AM', '6:30', or '22:00'."
            }
        }
    }

    private func setAlarm(args: [String: Any]) async -> String {
        let alarmDate: Date
        switch Self.resolveDate(time: args["time"] as? String, date: args["date"] as? String, now: now()) {
        case .failure(let error): return error.message
        case .success(let date): alarmDate = date
        }
        let label = args["label"] as? String ?? "Alarm"
        let plan = AlarmPlan(label: label, date: alarmDate)
        let when = formatAlarmTime(alarmDate)
        let timeUntil = alarmDate.timeIntervalSince(now())
        let hoursUntil = Int(timeUntil) / 3600
        let minsUntil = (Int(timeUntil) % 3600) / 60

        let authorization = await realAlarm?.authorize() ?? .unavailable
        var choice = AlarmBackendChoice.decide(authorization: authorization)
        if case .alarmKit = choice, let realAlarm {
            do {
                _ = try await realAlarm.schedule(plan)
                // Plan LA: a real alarm is on the clock.
                ActionCompletionReport.record(.done(summary: "Alarm \(when)"))
                return Wording.alarmSet(label: label, when: when, hoursUntil: hoursUntil, minutesUntil: minsUntil)
            } catch {
                choice = .notification(reason: .schedulingFailed)
            }
        }
        guard case .notification(let reason) = choice else { return Wording.notClockApp }
        if await fallback.authorize() != .authorized {
            return "Couldn't set the alarm: the alarm permission is off and notifications for this app are off too. "
                + "Turn one of them on in iPhone Settings."
        }
        do {
            _ = try await fallback.schedule(plan)
        } catch {
            return "Couldn't set alarm: \(error.localizedDescription)"
        }
        // Plan LA: only a notification stands in for the alarm, and the reply says why — the
        // wearer hears it.
        ActionCompletionReport.record(.partial(reason: .leftNotification))
        return Wording.notificationSet(label: label, when: when, hoursUntil: hoursUntil, minutesUntil: minsUntil,
                                       reason: reason)
    }

    private func listAlarms() async -> String {
        let real = await realAlarm?.pending() ?? []
        if !real.isEmpty {
            return Wording.listing(real, real: true, format: formatListTime)
        }
        return Wording.listing(await fallback.pending(), real: false, format: formatListTime)
    }

    private func cancelAllAlarms() async -> String {
        let real = await realAlarm?.cancelAll() ?? 0
        let notifications = await fallback.cancelAll()
        return Wording.cancelled(real + notifications)
    }

    private func formatListTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE h:mm a"
        return formatter.string(from: date)
    }

    /// "today" and "tomorrow" relative to the tool's own `now`, not the wall clock, so a pinned
    /// test reads the same words a wearer would.
    private func formatAlarmTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        let today = now()
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        if calendar.isDate(date, inSameDayAs: today) {
            formatter.dateFormat = "h:mm a"
            return "today at \(formatter.string(from: date))"
        } else if calendar.isDate(date, inSameDayAs: tomorrow) {
            formatter.dateFormat = "h:mm a"
            return "tomorrow at \(formatter.string(from: date))"
        } else {
            formatter.dateFormat = "EEEE, MMM d 'at' h:mm a"
            return formatter.string(from: date)
        }
    }

    static func parseTime(_ str: String, calendar: Calendar = .current) -> (hour: Int, minute: Int)? {
        let cleaned = str.lowercased().trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        for format in ["h:mm a", "h:mma", "ha", "h a", "HH:mm", "H:mm", "HHmm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) {
                return (calendar.component(.hour, from: date), calendar.component(.minute, from: date))
            }
        }
        return nil
    }

    static func parseDate(_ str: String, now: Date, calendar: Calendar = .current) -> Date? {
        guard !str.isEmpty else { return nil }
        let formatter = DateFormatter()
        for format in ["yyyy-MM-dd", "MM/dd/yyyy", "MMM d"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: str) {
                var components = calendar.dateComponents([.month, .day], from: date)
                components.year = calendar.component(.year, from: now)
                return calendar.date(from: components)
            }
        }
        return nil
    }
}
