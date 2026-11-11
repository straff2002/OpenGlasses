import Foundation
import UserNotifications
#if canImport(AlarmKit)
import AlarmKit
#endif

/// A timer or alarm that has just finished, as the lens's timer card (Plan KX §6) needs it. The
/// label is the wearer's own words for it and is never logged.
struct FinishedTimer: Equatable {
    enum Kind: Equatable {
        /// `set_timer`: a local notification after a delay.
        case timer
        /// `set_alarm` through AlarmKit (Plan JH): it rings like a Clock alarm until stopped.
        case alarm
    }

    /// The notification request id (a timer) or the AlarmKit alarm id (an alarm).
    let id: String
    let kind: Kind
    let label: String?
    /// Whether **+5 min** can be offered: a timer is set again for five minutes, an alarm is
    /// stopped and set again five minutes on, under the same label.
    let canExtend: Bool
}

/// Plan KX §6: hears a timer or an AlarmKit alarm finish while the app runs, for the lens.
///
/// **Why it exists.** Neither backend calls the app back: `set_timer` schedules a local
/// notification and nothing else, and AlarmKit rings by itself. So a timer the app set is watched
/// in-process until it is due (a timer is relative, so its due time is known exactly), and AlarmKit
/// alarms are followed through `AlarmManager.alarmUpdates` for the moment one starts alerting. Both
/// are best effort while the app is running — which it is while the wearer uses the glasses — and
/// neither changes how the timer or alarm itself rings on the phone.
///
/// **What it can do back.** Stop (the timer's delivered notification is removed; the alarm is
/// stopped through AlarmKit) and **+5 min** (the same label, set again five minutes from now through
/// the same backend). The notification fallback for an alarm (no AlarmKit permission) is not
/// watched: it is a calendar trigger the app cannot stop once delivered, and it rings once.
@MainActor
final class TimerCompletionWatch {
    static let shared = TimerCompletionWatch()

    /// How long **+5 min** adds.
    static let extensionSeconds = 5 * 60

    /// Heard when a watched timer or alarm finishes. Set by AppState (the lens's timer card).
    var onFinished: ((FinishedTimer) -> Void)?

    /// Test seam: sleep until a timer is due. Production sleeps on the main actor.
    var sleep: (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    private var timers: [String: Task<Void, Never>] = [:]
    private var alarmWatch: Task<Void, Never>?
    /// AlarmKit alarms already announced while alerting, so one alarm raises one card.
    private var announcedAlarms: Set<String> = []

    /// Watch a timer `set_timer` just scheduled, due at `fireAt`.
    func timerScheduled(id: String, label: String?, fireAt: Date) {
        timers[id]?.cancel()
        let delay = fireAt.timeIntervalSinceNow
        timers[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleep(delay)
            guard !Task.isCancelled else { return }
            self.timers[id] = nil
            self.onFinished?(FinishedTimer(id: id, kind: .timer, label: label, canExtend: true))
        }
    }

    /// Stop watching a timer (it was cancelled before it was due).
    func timerCancelled(id: String) {
        timers[id]?.cancel()
        timers[id] = nil
    }

    var watchedTimerIDs: Set<String> { Set(timers.keys) }

    // MARK: - AlarmKit

    /// Follow AlarmKit's alarms for one starting to alert. Only when the wearer has already allowed
    /// alarms: reading the state asks nothing, and nothing here ever prompts.
    func startWatchingAlarms() {
        #if canImport(AlarmKit)
        guard alarmWatch == nil else { return }
        if #available(iOS 26.1, *) {
            guard AlarmManager.shared.authorizationState == .authorized else { return }
            alarmWatch = Task { @MainActor [weak self] in
                for await alarms in AlarmManager.shared.alarmUpdates {
                    guard let self, !Task.isCancelled else { return }
                    self.alarmsChanged(alarms.map { ($0.id.uuidString, $0.state == .alerting) })
                }
            }
        }
        #endif
    }

    /// The alarms as AlarmKit reports them: an alarm newly alerting raises the card once; one that
    /// stopped alerting may raise it again the next time it rings. Internal so a test drives it.
    func alarmsChanged(_ alarms: [(id: String, alerting: Bool)]) {
        let alerting = Set(alarms.filter(\.alerting).map(\.id))
        let fresh = alerting.subtracting(announcedAlarms)
        announcedAlarms = alerting
        let labels = Self.alarmLabels()
        for id in fresh.sorted() {
            onFinished?(FinishedTimer(id: id, kind: .alarm, label: labels[id], canExtend: true))
        }
    }

    private static func alarmLabels() -> [String: String] {
        #if canImport(AlarmKit)
        return AlarmLabelStore.labels()
        #else
        return [:]
        #endif
    }

    // MARK: - Stop and +5 min

    /// Silence `timer`: the timer's delivered notification goes; the alarm stops.
    func stop(_ timer: FinishedTimer) {
        switch timer.kind {
        case .timer:
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [timer.id])
        case .alarm:
            #if canImport(AlarmKit)
            if #available(iOS 26.1, *), let id = UUID(uuidString: timer.id) {
                try? AlarmManager.shared.stop(id: id)
            }
            #endif
        }
    }

    /// Set `timer` again, five minutes from now, through its own backend. The old one is stopped.
    func extend(_ timer: FinishedTimer) {
        stop(timer)
        let label = timer.label
        switch timer.kind {
        case .timer:
            Task { @MainActor in
                guard let id = try? await TimerTool.scheduleNotification(seconds: Self.extensionSeconds, label: label) else { return }
                self.timerScheduled(id: id, label: label, fireAt: Date().addingTimeInterval(TimeInterval(Self.extensionSeconds)))
            }
        case .alarm:
            #if canImport(AlarmKit)
            if #available(iOS 26.1, *) {
                let plan = AlarmPlan(label: label ?? String(localized: "Alarm", comment: "The label of an alarm set again five minutes on from the glasses."),
                                     date: Date().addingTimeInterval(TimeInterval(Self.extensionSeconds)))
                Task { _ = try? await AlarmKitScheduler().schedule(plan) }
            }
            #endif
        }
    }
}
