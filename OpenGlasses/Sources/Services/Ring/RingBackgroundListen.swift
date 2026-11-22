import Foundation

/// What the app can do with the microphone when a clench arrives (Plan MZ §8, follow-up). Read by
/// the app, decided on here.
///
/// iOS lets an app in the background keep recording, but not begin: starting the microphone needs
/// an audio session that is already live. Always-on listening keeps one live, with the shared
/// engine running in the background and the phone locked. Without it, a clench from a phone in a
/// pocket would only start a turn that iOS refuses. The wearer hears nothing either way.
struct RingMicrophoneFacts: Equatable, Sendable {
    /// The app is in the foreground (`UIApplication.applicationState == .active`).
    var appActive: Bool
    /// The audio session is live: the shared engine is running (always-on listening), or the
    /// assistant is speaking.
    var audioLive: Bool

    static let foreground = RingMicrophoneFacts(appActive: true, audioLive: false)

    /// Whether a turn can open the microphone now.
    var canOpenMicrophone: Bool { appActive || audioLive }
}

/// Whether a clench that opens the microphone goes ahead, and when the wearer is told it can't.
/// Pure.
///
/// A refused clench posts one notification. Clenches are easy to repeat and a phone in a pocket
/// buzzes for each one, so further refusals within `noticeCooldown` stay silent: they are still
/// logged.
struct RingBackgroundListenGate: Equatable, Sendable {

    enum Decision: Equatable, Sendable {
        case proceed
        /// Not carried out. `notify` is whether to post the notice this time.
        case refuse(notify: Bool)
    }

    static let noticeCooldown: TimeInterval = 5 * 60

    private(set) var lastNotice: Date?

    /// The effects that start a turn, and so need the microphone.
    static func opensMicrophone(_ effect: TempleEffect) -> Bool {
        switch effect {
        case .startListening, .interruptAndListen, .askAgent: return true
        default: return false
        }
    }

    mutating func decide(_ effect: TempleEffect, facts: RingMicrophoneFacts, now: Date) -> Decision {
        guard Self.opensMicrophone(effect), !facts.canOpenMicrophone else { return .proceed }
        if let lastNotice, now >= lastNotice, now.timeIntervalSince(lastNotice) < Self.noticeCooldown {
            return .refuse(notify: false)
        }
        lastNotice = now
        return .refuse(notify: true)
    }

    mutating func reset() {
        lastNotice = nil
    }
}

/// The notice for a clench the phone couldn't act on. Names the setting that makes it work.
enum RingBackgroundListenNotice {
    static var title: String { String(localized: "Open Avenkin to talk") }
    static var body: String {
        String(localized: "iOS won't let Avenkin start the microphone from the background. Turn on Listen for Wake Phrase to talk with a clench while your phone is locked.")
    }
}
