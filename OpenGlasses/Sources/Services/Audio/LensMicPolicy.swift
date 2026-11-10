import Foundation

/// Plan KX §2.5: while the Meta Display is on, the conversation mic stays on the iPhone.
///
/// On current Ray-Ban Display firmware, bringing up the glasses' hands-free (HFP) microphone ends
/// the app's display session (meta-wearables-dat-ios #342), and the glasses put their call screen
/// over the lens. `MicRoute.headset` already exists for that fight; this closes it for the
/// **Glasses Mic** route too: with the HUD on and a Meta Display connected, a conversation captures
/// on the phone. The stored preference is not changed and Settings still shows it as chosen, with
/// a line saying why it is overridden. **Keep the mic on the iPhone while the display is on**
/// (`Config.lensKeepsPhoneMic`, on by default) is the rollback.
///
/// The idle wake-word listener already waits on the phone mic by default (Plan GU), so this is
/// about the conversation itself.
enum LensMicPolicy {
    /// Whether a Meta Display is connected (written by `GlassesDisplayService.deviceSupportsDisplay`,
    /// read where a conversation picks its mic). Main-thread writes and reads; a stale read only
    /// changes which mic one turn uses.
    nonisolated(unsafe) static var metaDisplayPresent = false

    /// The route a conversation captures on. Only **Glasses Mic** moves, and only to the phone:
    /// a headset's hands-free link does not touch the lens.
    static func conversationRoute(preferred: MicRoute, lensOn: Bool, keepPhoneMic: Bool) -> MicRoute {
        guard preferred == .glasses, lensOn, keepPhoneMic else { return preferred }
        return .phone
    }

    /// Whether `preferred` is being overridden right now, for the Settings footnote.
    static func overrides(preferred: MicRoute, lensOn: Bool, keepPhoneMic: Bool) -> Bool {
        conversationRoute(preferred: preferred, lensOn: lensOn, keepPhoneMic: keepPhoneMic) != preferred
    }

    static var settingsFootnote: String {
        String(localized: "While the display is on, the iPhone mic is used: the glasses' own mic turns the display off.",
               comment: "Settings footnote under the Microphone picker when the Glasses Mic is overridden for the in-lens display.")
    }
}
