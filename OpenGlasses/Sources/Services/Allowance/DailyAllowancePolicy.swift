import Foundation

/// Plan NH — 15 minutes of the assistant a day for everyone, unlimited with a subscription.
///
/// The allowance counts **assistant time**: a turn from the moment it is sent until its reply has
/// finished (spoken or shown), and every second a Live session is connected. Every model counts the
/// same — a cloud model on the user's own key, a downloaded model or Apple Intelligence — because
/// the subscription pays for the app, not for compute (decisions 1–3).
///
/// Pure: seconds used today, the allowance and whether the user is exempt in; a decision out.
/// `AssistantTimeLedger` keeps the seconds, `AllowanceExemption` decides who is never counted, and
/// `AllowanceService` applies the decision on the phone.
enum DailyAllowancePolicy {

    /// The free allowance, in seconds of assistant time a local calendar day.
    static let allowanceSeconds = 900
    /// Below this many seconds left the Home line turns amber and the decision carries a notice.
    static let noticeBelowSeconds = 180
    /// A Live session says its one warning with this many seconds left.
    static let liveWarningSeconds = 60
    /// A Live session that reaches zero finishes the answer it is giving, and closes this many
    /// seconds after zero at the latest (decision 11).
    static let liveGraceSeconds: TimeInterval = 60
    /// Each turn counts at least this long…
    static let turnFloorSeconds = 5
    /// …and at most this long, so a stuck turn cannot drain the day.
    static let turnCeilingSeconds = 180

    enum Decision: Equatable {
        /// Go ahead.
        case proceed
        /// Go ahead; fewer than `noticeBelowSeconds` are left.
        case proceedWithNotice(remainingSeconds: Int)
        /// Today's allowance is used: answer with `exhaustedLine` and send nothing.
        case exhausted
    }

    static func remaining(usedSeconds: Int, allowanceSeconds: Int = allowanceSeconds) -> Int {
        max(0, allowanceSeconds - max(0, usedSeconds))
    }

    static func decide(usedSeconds: Int, allowanceSeconds: Int = allowanceSeconds, exempt: Bool) -> Decision {
        guard !exempt else { return .proceed }
        let left = remaining(usedSeconds: usedSeconds, allowanceSeconds: allowanceSeconds)
        if left <= 0 { return .exhausted }
        if left < noticeBelowSeconds { return .proceedWithNotice(remainingSeconds: left) }
        return .proceed
    }

    /// What one turn costs, from when it was sent to when its reply finished: whole seconds,
    /// rounded up, never under the floor and never over the ceiling. A clock that went backwards
    /// still charges the floor.
    static func turnCharge(startedAt: Date, finishedAt: Date) -> Int {
        let elapsed = finishedAt.timeIntervalSince(startedAt)
        let seconds = elapsed.isFinite ? Int(elapsed.rounded(.up)) : turnCeilingSeconds
        return min(turnCeilingSeconds, max(turnFloorSeconds, seconds))
    }

    // MARK: - What the user is told

    /// The reply to a turn that arrives with nothing left, spoken in voice modes and shown in chat.
    static var exhaustedLine: String {
        String(localized: "That's today's 15 free minutes. Unlimited is in Settings, under Subscription, or the minutes come back at midnight.")
    }

    /// The Live session's one warning.
    static var liveWarningLine: String {
        String(localized: "About a minute of today's free time is left.")
    }

    /// The status card's line after a Live session closed at zero.
    static var liveEndedNotice: String {
        String(localized: "Session ended: today's 15 free minutes are used")
    }

    /// The Home card's line. Nil when it is not shown: for an exempt user, and before any turn has
    /// run today.
    struct HomeStatus: Equatable {
        let remainingSeconds: Int
        /// Amber: fewer than `noticeBelowSeconds` left.
        let isLow: Bool

        var text: String {
            if remainingSeconds <= 0 { return String(localized: "No free minutes left today") }
            if remainingSeconds < 60 { return String(localized: "Less than a minute left today") }
            let minutes = remainingSeconds / 60
            return String(localized: "\(minutes) min left today")
        }
    }

    static func homeStatus(usedSeconds: Int, allowanceSeconds: Int = allowanceSeconds,
                           exempt: Bool) -> HomeStatus? {
        guard !exempt, usedSeconds > 0 else { return nil }
        let left = remaining(usedSeconds: usedSeconds, allowanceSeconds: allowanceSeconds)
        return HomeStatus(remainingSeconds: left, isLow: left < noticeBelowSeconds)
    }
}

/// The turn gate's outcome, the same shape as `SpendCapGate.Outcome`: the turn goes ahead, goes
/// ahead with a notice, or is answered with a line and never sent.
enum DailyAllowanceOutcome: Equatable {
    case proceed
    /// Go ahead; this few seconds are left (the Home line is amber).
    case proceedWithNotice(remainingSeconds: Int)
    /// Answer with this line instead of calling any model, local or cloud.
    case answer(String)
}

/// Whether an utterance asks for first aid. Deterministic and deliberately broad: a false match
/// costs one free turn, a missed one could refuse someone in an emergency. The allowance gate runs
/// this before it decides anything, so an emergency phrase is never counted and never refused,
/// even at zero (Plan NH §2, decision 5).
enum FirstAidTurnRecognizer {

    /// Matched as whole words or phrases in the lowercased utterance.
    static let phrases: [String] = [
        "first aid", "cpr", "aed", "defibrillator", "defib",
        "not breathing", "isn't breathing", "is not breathing", "stopped breathing", "can't breathe",
        "cannot breathe", "can not breathe", "struggling to breathe", "trouble breathing",
        "choking", "choked", "heart attack", "cardiac arrest", "no pulse",
        "unconscious", "unresponsive", "passed out", "collapsed", "fainted",
        "bleeding", "tourniquet", "recovery position", "stroke", "seizure",
        "overdose", "overdosed", "anaphylaxis", "anaphylactic", "epipen", "allergic reaction",
        "drowning", "drowned", "electrocuted", "burned badly", "badly burned",
        "call an ambulance", "call ambulance", "ambulance", "emergency",
        "911", "999", "112", "000", "111",
    ]

    static func isFirstAid(_ utterance: String) -> Bool {
        let normalised = " " + utterance.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
        guard normalised.count > 2 else { return false }
        return phrases.contains { normalised.contains(" \($0) ") }
    }
}
