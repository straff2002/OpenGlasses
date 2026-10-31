import Foundation

/// The streaming platforms the Live Streaming settings offer. The raw values are what
/// `Config.broadcastPlatform` stores.
enum GoLivePlatform: String, CaseIterable, Sendable {
    case youtube
    case twitch
    case kick
    case tiktok
    case custom

    /// A stored value this build does not know is an endpoint the wearer typed themselves.
    init(stored: String) {
        self = GoLivePlatform(rawValue: stored) ?? .custom
    }
}

/// The words of the "How to go live" guide in Live Streaming settings. Pure, so the copy can be
/// held to what the app and the platforms really do.
///
/// Each key line says what that platform's own help page says, and no more. A menu name goes in
/// only when the page gives it. TikTok's pages say a server URL and key are "provided by TikTok" and
/// never where, so its line names no menu and states no rule about who gets one.
enum GoLiveGuide {

    /// Where this platform keeps its key. One line, for the selected platform only.
    static func keyLine(for platform: GoLivePlatform) -> String {
        switch platform {
        case .youtube:
            return String(localized: "In YouTube Studio, choose Create, then Go Live, and open the Stream tab. Your stream key is there. If this is your first stream, create a stream first.")
        case .twitch:
            return String(localized: "In your Twitch Creator Dashboard, open Settings, then Stream. Your stream key is there.")
        case .kick:
            return String(localized: "In your Kick Creator Dashboard, open Stream URL and Key under Channel. Your stream key is there.")
        case .tiktok:
            return String(localized: "Look in your channel's stream or creator dashboard on TikTok for a server URL and stream key, and enter both above.")
        case .custom:
            return String(localized: "Your streaming service gives you an RTMP URL and a stream key. Enter both above.")
        }
    }

    /// The whole guide for `platform`, in order.
    static func steps(for platform: GoLivePlatform) -> [String] {
        [
            String(localized: "Choose your platform above."),
            keyLine(for: platform),
            String(localized: "Paste the key into Stream Key above. Treat it like a password: anyone who has it can stream to your channel."),
            String(localized: "In the Avenkin tab, find Preview in the button grid and tap it. Then tap the Go Live button, which looks like a broadcast signal."),
            String(localized: "LIVE shows on the button while you are on air, and you can switch camera while streaming."),
            String(localized: "Tap the button again to stop."),
            String(localized: "Expect viewers to see you a few seconds late."),
        ]
    }

    /// What is true about the phone camera, shown under the steps.
    static var phoneCameraNotes: [String] {
        [
            String(localized: "If Camera is set to Glasses and none are connected, Go Live uses the phone's back camera instead, unless Blur Bystander Faces is on. The picture doesn't show in the preview."),
            String(localized: "Blur Bystander Faces covers the glasses camera only. It won't blur a stream from the phone camera, and your microphone is streamed either way."),
        ]
    }

    /// The Live Streaming footer once a URL and key are in. Names no camera, because either can
    /// feed the stream.
    static func readyLine(for platform: GoLivePlatform) -> String {
        switch platform {
        case .youtube: return String(localized: "Ready to stream to YouTube.")
        case .twitch: return String(localized: "Ready to stream to Twitch.")
        case .kick: return String(localized: "Ready to stream to Kick.")
        case .tiktok: return String(localized: "Ready to stream to TikTok.")
        case .custom: return String(localized: "Ready to stream to your RTMP server.")
        }
    }
}

/// The Things to Try link to the live preview. Not a scenario: a scenario is a turn the wearer
/// could say, and there is no tool that starts a stream. It is a shortcut for someone who has
/// already set streaming up, so it has no setup state of its own.
enum StreamLiveLink {
    /// Pure. With streaming not set up there is no row at all. HIPAA hides it on the page's own
    /// rule: nothing there offers a way to take something off the phone (`ScenarioReadiness`).
    /// Simple Mode's hidden categories and an organisation's are both in `unreachableSettings`.
    static func isVisible(broadcastConfigured: Bool, in context: ScenarioContext) -> Bool {
        broadcastConfigured && !context.hipaaMode && !context.unreachableSettings.contains(.capture)
    }
}
