import Foundation

/// Every word Scan Assist says or shows for a value that varies — a side, an interval, a session
/// length, a refusal, an ending.
///
/// Gathered in one type for three reasons. Translators get the whole feature's wearer-relative
/// left/right vocabulary in one place, which the plan asks for explicitly. Tests can assert the
/// exact line a cue speaks without standing a view up. And the efficacy rule — Scan Assist helps
/// someone practise checking a side, it does not treat, score or verify anything — is enforceable
/// by reading one file rather than by hoping nobody writes "you missed the left" into a view.
///
/// Nothing here may claim the wearer looked, checked, saw, finished or is safe. A camera frame
/// cannot establish attention, and Scan Assist reads no frames at all.
enum ScanAssistCopy {

    // MARK: - Spoken cues

    /// The reminder itself. An invitation with no deadline in it: "when you're ready" is the
    /// difference between a prompt and a demand, and this arrives every interval for minutes.
    static func cue(for side: ScanAssistSide) -> String {
        switch side {
        case .left: return String(localized: "Check to your left when you're ready.")
        case .right: return String(localized: "Check to your right when you're ready.")
        }
    }

    /// The same line, announced as a rehearsal so a wearer hearing it in a quiet room knows the
    /// session has not started. The side is named out loud: a preview that does not say which side
    /// it is previewing cannot catch a side chosen by mistake.
    static func preview(for side: ScanAssistSide) -> String {
        switch side {
        case .left: return String(localized: "Preview: check to your left when you're ready.")
        case .right: return String(localized: "Preview: check to your right when you're ready.")
        }
    }

    // MARK: - Status lines

    /// Shown (not spoken) when Start or Preview is used before a side has been chosen.
    static var needsSideChoice: String {
        String(localized: "Choose a side first — Left or Right — so reminders know which way to point.")
    }

    static var sessionRunning: String {
        String(localized: "Reminders are running.")
    }

    static var sessionPaused: String {
        String(localized: "Reminders are paused.")
    }

    static func sessionEnded(_ reason: ScanAssistEndReason) -> String {
        switch reason {
        case .stopped: return String(localized: "Reminders stopped.")
        case .expired: return String(localized: "Session finished.")
        }
    }

    // MARK: - Control labels

    static func sideLabel(_ side: ScanAssistSide) -> String {
        switch side {
        case .left: return String(localized: "Left")
        case .right: return String(localized: "Right")
        }
    }

    /// What the chosen side means, spelled out. "Left" on a screen is ambiguous — left of the page,
    /// of the room, of the person opposite — and the whole feature rests on it meaning one thing.
    static func sideDescription(_ side: ScanAssistSide) -> String {
        switch side {
        case .left: return String(localized: "Your left, from your own perspective.")
        case .right: return String(localized: "Your right, from your own perspective.")
        }
    }

    static var sideNotChosen: String {
        String(localized: "Not chosen yet")
    }

    static func cueStyleLabel(_ style: ScanAssistCueStyle) -> String {
        switch style {
        case .spoken: return String(localized: "Spoken direction")
        case .sound: return String(localized: "Gentle sound")
        }
    }

    static func intervalLabel(_ interval: ScanAssistInterval) -> String {
        switch interval {
        case .fifteenSeconds: return String(localized: "Every 15 seconds")
        case .thirtySeconds: return String(localized: "Every 30 seconds")
        case .oneMinute: return String(localized: "Every minute")
        case .twoMinutes: return String(localized: "Every 2 minutes")
        }
    }

    static func sessionDurationLabel(_ duration: ScanAssistSessionDuration) -> String {
        switch duration {
        case .twoMinutes: return String(localized: "2 minutes")
        case .fiveMinutes: return String(localized: "5 minutes")
        case .tenMinutes: return String(localized: "10 minutes")
        }
    }

    /// The countdown, spoken by VoiceOver as words rather than read off a "4:30" glyph.
    static func remaining(seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.up)))
        let minutes = whole / 60
        let remainder = whole % 60
        if minutes > 0 && remainder > 0 {
            return String(localized: "\(minutes) min \(remainder) sec left")
        }
        if minutes > 0 {
            return String(localized: "\(minutes) min left")
        }
        return String(localized: "\(remainder) sec left")
    }
}
