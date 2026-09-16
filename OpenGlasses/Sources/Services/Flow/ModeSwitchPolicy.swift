import Foundation

/// Plan CF — mode-switch auto-redial: switching brains mid-call must hang up and redial, not go
/// silently dead. Picking a different brain is an intent about *who the user is talking to*,
/// not a request to stop talking.
///
/// The switch sequence is encoded as data so the one interesting rule — `.startSession` appears
/// exactly when a live call existed at switch time and the target is a realtime mode — is
/// unit-testable without any audio stack. Context does not survive the swap (inherent to
/// changing brains); what the app owes the user is the automatic reconnect and honest error
/// pass-through, never a fabricated call that didn't exist.
enum ModeSwitchAction: Equatable {
    case teardown(AppMode)
    /// Let the audio session release before the new mode claims it.
    case settleDelay
    /// Wake-word listening (Direct) or background voice + camera (realtime).
    case startSubstrate(AppMode)
    /// The redial. Only ever the final action, and only for realtime targets.
    case startSession(AppMode)
}

enum ModeSwitchPolicy {

    /// How long `.settleDelay` waits for the audio session to release before the new mode claims
    /// it. Named here rather than written as a literal at each site because Plan FF P1/PR3 needed
    /// a second caller: the activator's stop-and-restart path stops and restarts *the same* audio
    /// session, which is the same handover with the same cost. Every other guess at this number —
    /// the 600 ms each Action Button / Siri entry point used to sleep before starting a session —
    /// is gone, replaced by awaiting the switch itself.
    static let settleDelay: TimeInterval = 0.5

    static func actions(from oldMode: AppMode, to newMode: AppMode,
                        wasSessionActive: Bool, autoRedial: Bool) -> [ModeSwitchAction] {
        var actions: [ModeSwitchAction] = [
            .teardown(oldMode),
            .settleDelay,
            .startSubstrate(newMode),
        ]
        // Switching FROM Direct never fabricates a call (`wasSessionActive` is only ever
        // measured on the realtime managers); switching TO Direct is already handled by the
        // wake-word substrate restart.
        if autoRedial, wasSessionActive, newMode.isRealtime {
            actions.append(.startSession(newMode))
        }
        return actions
    }
}

extension Config {
    /// Kill switch for the auto-redial (default on). With it off, a mid-call mode switch
    /// reverts to the old behavior: substrate up, no session — the user reconnects manually.
    static var modeSwitchAutoRedialEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "modeSwitchAutoRedialEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "modeSwitchAutoRedialEnabled") }
    }
}
