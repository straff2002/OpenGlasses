import Foundation

/// What the wearer is told when the wake-word listener could not be started (Plan KD P1).
///
/// Build 581, twice: the end-of-turn re-arm ran in the same second the app went to the background,
/// iOS refused the microphone three times (`'what'`), and the app set "Tap Test Microphone to
/// restart". The listener came back by itself at the next foreground, but the message stayed; the
/// screen it showed on has no Test Microphone button; and the session card said "Ready" the whole
/// time nothing was listening. So:
///
/// - The message names the control the main screen has, Tap & Talk.
/// - A start refused while the app is not in front shows no instruction at all — nobody is looking,
///   and the foreground re-arm is the fix. The failure is still recorded, so the card is honest
///   if that re-arm fails too.
/// - The message is cleared the moment a listener starts (`AppState.noteWakeListenerRunning`),
///   and only that message: an unrelated error stays.
/// - While the listener is expected and down, the card says so instead of "Ready".
enum WakeListenerFailurePolicy {

    /// The banner for a start that failed in front of the wearer.
    static var messageText: String { String(localized: "Microphone stopped — tap Tap & Talk to try again") }

    /// The session card's headline while the listener is down.
    static var headline: String { String(localized: "Not listening — tap Tap & Talk") }

    /// The banner for a failed start, or nil when the app is not in front.
    static func message(appActive: Bool) -> String? { appActive ? messageText : nil }

    /// Whether the listener should be running and is not, after a failed start. Not while it is
    /// meant to be off — the master switch, push-to-talk, the mute — and not while a conversation
    /// holds the microphone, which the wake listener gives way to by design.
    static func isDown(failed: Bool, listeningEnabled: Bool, pushToTalk: Bool, micMuted: Bool,
                       inConversation: Bool, listenerRunning: Bool) -> Bool {
        failed && listeningEnabled && !pushToTalk && !micMuted && !inConversation && !listenerRunning
    }

    /// The Direct-mode session card headline.
    enum DirectHeadline: Equatable {
        case listening, speaking, notListening, ready
    }

    static func directHeadline(isListening: Bool, isSpeaking: Bool, listenerDown: Bool) -> DirectHeadline {
        if isListening { return .listening }
        if isSpeaking { return .speaking }
        return listenerDown ? .notListening : .ready
    }
}
