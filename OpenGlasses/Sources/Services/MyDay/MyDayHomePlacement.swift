import Foundation

/// Whether My Day has a card on the home screen, and what each control that changes it writes.
///
/// Two facts, two keys, and every control reads the same keys:
///   - `myDayEnabled` — My Day is on at all. It drives more than the card: the scheduled morning
///     and evening briefings, the `daily_briefing` tool and the leave-by travel alerts.
///   - `myDayOnHome` — the card's *placement*. Taking the card off the home screen is a choice
///     about the home screen, so it does not silently stop a morning briefing.
///
/// The card shows only when both hold. With My Day off there is nothing of it on the home screen —
/// no set-up card standing in for it.
enum MyDayHomePlacement {
    static let enabledKey = "myDayEnabled"
    static let onHomeKey = "myDayOnHome"
    /// A fresh install has never removed the card, so turning My Day on puts it on the home screen.
    static let onHomeDefault = true

    static func isShown(enabled: Bool, onHome: Bool) -> Bool {
        enabled && onHome
    }

    /// What a "show My Day on the home screen" switch writes — the editor's, which presents the
    /// placement and the feature as one control.
    ///
    /// Turning it on is an opt-in when My Day was off, so both flags go on. Turning it off only
    /// takes the card away: the briefings, the tool and the alerts keep their own settings.
    static func settingShown(_ shown: Bool,
                             enabled: Bool) -> (enabled: Bool, onHome: Bool, optedIn: Bool) {
        if shown {
            return (enabled: true, onHome: true, optedIn: !enabled)
        }
        return (enabled: enabled, onHome: false, optedIn: false)
    }
}

extension Config {
    /// Whether the My Day card sits on the home screen when My Day is on — see `MyDayHomePlacement`.
    static var myDayOnHome: Bool {
        get {
            UserDefaults.standard.object(forKey: MyDayHomePlacement.onHomeKey) as? Bool
                ?? MyDayHomePlacement.onHomeDefault
        }
        set { UserDefaults.standard.set(newValue, forKey: MyDayHomePlacement.onHomeKey) }
    }

    /// The one writer behind every "show My Day on the home screen" control.
    static func setMyDayShownOnHome(_ shown: Bool) {
        let next = MyDayHomePlacement.settingShown(shown, enabled: myDayEnabled)
        myDayOnHome = next.onHome
        if next.enabled != myDayEnabled { setMyDayEnabled(next.enabled) }
    }
}
