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

    /// Plan KX §5: how a live session (Gemini Live, OpenAI Realtime, Qwen, Doubao) captures. A live
    /// session has no mic picker of its own: it captures on the glasses' hands-free mic whenever the
    /// camera streams from them, which is the **Glasses Mic** route. That goes through
    /// `conversationRoute` like any conversation, so with the Meta Display on (and the rollback on)
    /// it becomes the iPhone mic — `.lensPhoneMic`, output still on the glasses over A2DP, and with
    /// no camera streaming too, since the lens being on means the glasses are on the wearer. The
    /// interpreter keeps its own route. `useIPhoneMode` is the session's echo posture: the phone's
    /// mic hears the glasses' open-ear speakers, so the lens route mutes capture while the model
    /// speaks on the half-duplex tier, exactly as the phone route does.
    struct LiveAudio: Equatable {
        let route: RealtimeAudioRoute
        let useIPhoneMode: Bool
    }

    static func liveAudio(cameraOnGlasses: Bool, interpreting: Bool,
                          lensOn: Bool, keepPhoneMic: Bool) -> LiveAudio {
        if interpreting { return LiveAudio(route: .interpreter, useIPhoneMode: false) }
        if conversationRoute(preferred: .glasses, lensOn: lensOn, keepPhoneMic: keepPhoneMic) == .phone {
            return LiveAudio(route: .lensPhoneMic, useIPhoneMode: true)
        }
        return LiveAudio(route: .standard, useIPhoneMode: !cameraOnGlasses)
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
