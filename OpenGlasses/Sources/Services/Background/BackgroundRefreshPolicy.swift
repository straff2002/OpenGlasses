import Foundation

/// Plan LM P0 — what one iOS background wake may do, decided without iOS.
///
/// iOS background refresh is a chance, not a schedule: the system decides when, often runs nothing
/// overnight, and gives an app-refresh task about thirty seconds. Everything here is pure so the
/// rules are provable headless; `BackgroundRefreshCoordinator` is the only file that talks to
/// `BGTaskScheduler`.
enum BackgroundRefreshPolicy {

    /// The one background wake identifier every plan shares (listed in
    /// `BGTaskSchedulerPermittedIdentifiers`; `BackgroundRefreshPlistGuardTests` pins the two
    /// together). A plan joins by adding a participant, never by registering its own task.
    static let taskIdentifier = "com.openglasses.app.refresh"

    /// The part of iOS's roughly thirty seconds the participants may use. The rest is for writing
    /// the record and submitting the next request.
    static let budget: TimeInterval = 25

    /// Never ask to be woken sooner than this; iOS would not honour a shorter interval anyway.
    static let minimumInterval: TimeInterval = 15 * 60

    /// When to ask iOS for the next wake: the soonest any participant wants, but not sooner than
    /// `minimumInterval` from now. Nil — ask for nothing — when no participant wants a wake.
    static func earliestBeginDate(now: Date, wanted: [Date?]) -> Date? {
        guard let soonest = wanted.compactMap({ $0 }).min() else { return nil }
        return max(soonest, now.addingTimeInterval(minimumInterval))
    }

    /// Whether a participant that next wants a wake at `nextWake` should run in a wake at `now`.
    static func isDue(nextWake: Date?, now: Date) -> Bool {
        guard let nextWake else { return false }
        return nextWake <= now
    }

    /// Whether a participant needing `minimumSeconds` may start with `remaining` seconds left.
    /// One that cannot finish is not started: iOS ends the whole process at its limit, and a
    /// half-written store is worse than a skipped check.
    static func mayStart(minimumSeconds: TimeInterval, remaining: TimeInterval) -> Bool {
        remaining > 0 && remaining >= minimumSeconds
    }
}

/// How one participant's turn in a wake ended. A fixed vocabulary: it is logged and stored, and
/// it never carries what the participant found.
enum BackgroundWorkOutcome: String, Codable, Equatable, CaseIterable, Sendable {
    /// It ran and changed something (filed a digest line, posted a notification).
    case didWork
    /// It ran and had nothing to do.
    case nothingToDo
    /// It could not run now and wants another chance (a store unreadable while locked).
    case deferred
    /// It ran and failed.
    case failed
    /// The wake expired or was cancelled before or while it ran.
    case cancelled
    /// It did not want this wake (switched off, or not due yet).
    case notDue
    /// Too little of the wake was left for it to start.
    case skippedNoTime
}

/// What started a pass.
enum BackgroundRunTrigger: String, Codable, Equatable, Sendable {
    /// iOS woke the app with the shared app-refresh task.
    case systemRefresh
    /// The Developer panel's Run now — the same pass, in the foreground.
    case manual
}

/// One participant's line in a wake's record.
struct BackgroundParticipantResult: Codable, Equatable, Sendable {
    /// The participant's fixed id (`goal-check-ins`) — a literal, never wearer content.
    var id: String
    var outcome: BackgroundWorkOutcome
    var seconds: TimeInterval
}

/// One background pass, as the Developer panel shows it and the device pass reads it (Plan LM P4).
struct BackgroundRunRecord: Codable, Equatable, Sendable {
    var startedAt: Date
    var trigger: BackgroundRunTrigger
    /// The earliest-begin date the last request asked for, if one was recorded — how late iOS was.
    var requestedEarliest: Date?
    var results: [BackgroundParticipantResult]
    var seconds: TimeInterval
    /// iOS ended the wake before the pass finished.
    var expired: Bool

    /// The ledger keeps this many wakes, newest last.
    static let keep = 40

    /// `records` with `record` appended, trimmed to the newest `keep`.
    static func appending(_ record: BackgroundRunRecord, to records: [BackgroundRunRecord]) -> [BackgroundRunRecord] {
        Array((records + [record]).suffix(keep))
    }
}

/// The last request made of iOS, and how it went.
struct BackgroundRequestRecord: Codable, Equatable, Sendable {
    var submittedAt: Date
    /// Nil when no participant wanted a wake, so nothing was asked for (any pending request was
    /// cancelled).
    var earliestBegin: Date?
    /// Nil on success; otherwise a fixed reason token (`unavailable`, `tooManyPending`,
    /// `notPermitted`, `other`) — never the error's own text.
    var failure: String?
}

/// The Developer panel's lines. Fixed English and a fixed clock format: this is evidence read by
/// whoever runs the device pass, not wearer copy.
enum BackgroundRunSummary {

    private static func stamp(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// A duration as `45m`, `2h 05m` or `1d 3h` — or `on time` within a minute.
    static func lateness(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded(.down))
        if minutes < 1 { return "on time" }
        if minutes < 60 { return "\(minutes)m late" }
        let hours = minutes / 60
        if hours < 24 { return String(format: "%dh %02dm late", hours, minutes % 60) }
        return "\(hours / 24)d \(hours % 24)h late"
    }

    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1fs", value)
    }

    /// `2026-11-11 21:04 · system · 2h 05m late · goal-check-ins didWork 0.4s · 0.5s`
    static func line(_ record: BackgroundRunRecord, calendar: Calendar = .current) -> String {
        var parts = [stamp(record.startedAt, calendar: calendar), record.trigger == .manual ? "manual" : "system"]
        if record.trigger == .systemRefresh, let asked = record.requestedEarliest {
            parts.append(lateness(record.startedAt.timeIntervalSince(asked)))
        }
        if record.results.isEmpty {
            parts.append("no participants")
        } else {
            parts.append(contentsOf: record.results.map { "\($0.id) \($0.outcome.rawValue) \(seconds($0.seconds))" })
        }
        parts.append(seconds(record.seconds))
        if record.expired { parts.append("EXPIRED") }
        return parts.joined(separator: " · ")
    }

    /// `Asked 2026-11-11 21:04 for 21:19 or later` / `Asked … for nothing` / `… failed: unavailable`
    static func line(_ request: BackgroundRequestRecord, calendar: Calendar = .current) -> String {
        let asked = "Asked \(stamp(request.submittedAt, calendar: calendar))"
        if let failure = request.failure { return "\(asked) — failed: \(failure)" }
        guard let begin = request.earliestBegin else { return "\(asked) for nothing (no participant wants a wake)" }
        return "\(asked) for \(stamp(begin, calendar: calendar)) or later"
    }
}
