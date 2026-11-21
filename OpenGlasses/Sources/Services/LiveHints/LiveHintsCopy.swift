import Foundation

/// The words live hints shows and says about itself (Plan MO §10). English for now; the catalog
/// pass translates them.
enum LiveHintsCopy {

    /// The capture notice, on the phone at every start. Exactly this line.
    static var captureNotice: String {
        String(localized: "Live hints listens to everyone near you. Tell people you're using it.",
               comment: "Live hints: the notice shown on the phone every time a session starts.")
    }

    // MARK: - The first-run sheet

    static var firstRunTitle: String {
        String(localized: "Before you start live hints",
               comment: "Live hints first-run sheet: title.")
    }

    /// Where the audio goes, path by path.
    static var firstRunAudio: String {
        String(localized: "Your phone's microphone listens to the room. Captions are made on this phone, unless you've turned on Diarization or translated captions, which send the audio to the cloud service you set up.",
               comment: "Live hints first-run sheet: where the room's audio goes.")
    }

    /// Where a question goes.
    static var firstRunQuestions: String {
        String(localized: "When someone asks you a question, the app searches your documents on this phone. The question, a few lines before it and the passages it found go to the AI model you've chosen for a short answer. In keyword mode nothing goes to a model.",
               comment: "Live hints first-run sheet: what is sent to the model.")
    }

    /// What is kept.
    static var firstRunKept: String {
        String(localized: "Nothing is kept. Hints and the questions they answer stay in memory until you stop, and are never saved to your conversations or memory.",
               comment: "Live hints first-run sheet: what is kept.")
    }

    static var firstRunPeople: String {
        String(localized: "It hears everyone near you. Tell people you're using it.",
               comment: "Live hints first-run sheet: tell the people nearby.")
    }

    static var firstRunContinue: String {
        String(localized: "Start live hints", comment: "Live hints first-run sheet: button that starts the session.")
    }

    static var firstRunCancel: String {
        String(localized: "Not now", comment: "Live hints first-run sheet: button that closes the sheet without starting.")
    }

    static var firstRunTurnOff: String {
        String(localized: "Turn off live hints", comment: "Live hints first-run sheet: button that switches the feature off.")
    }

    // MARK: - Spoken

    /// Five minutes before the two-hour limit.
    static var limitWarning: String {
        String(localized: "Live hints stops in 5 minutes.",
               comment: "Live hints: spoken five minutes before a session reaches its two-hour limit.")
    }

    static var limitReached: String {
        String(localized: "Live hints stopped after 2 hours.",
               comment: "Live hints: spoken when a session reaches its two-hour limit.")
    }

    static var allowanceSpent: String {
        String(localized: "Live hints stopped: today's free time is used up.",
               comment: "Live hints: spoken when the app-wide daily allowance runs out during a session.")
    }
    /// The app was in the background past the rule captions follow, so the session ended.
    static var backgroundStopped: String {
        String(localized: "Live hints stopped while the app was in the background.",
               comment: "Live hints: shown, and spoken, when a session ends because the app stayed in the background.")
    }

    // MARK: - The demo (§11)

    /// The demo's notice in place of the capture notice: nothing is listening.
    static var demoNotice: String {
        String(localized: "This is a demo. Nothing is listening: the conversation is played inside the app.",
               comment: "Live hints demo: the notice shown when the demo session starts.")
    }

    // MARK: - Spoken replies to the voice commands (P2)

    static var started: String {
        String(localized: "Live hints is on.", comment: "Live hints: spoken when the wearer starts a session by voice.")
    }

    static var stopped: String {
        String(localized: "Live hints is off.", comment: "Live hints: spoken when the wearer stops a session by voice.")
    }

    static var alreadyRunning: String {
        String(localized: "Live hints is already on.",
               comment: "Live hints: spoken when the wearer asks to start a session that is already running.")
    }

    static var notRunning: String {
        String(localized: "Live hints isn't on.",
               comment: "Live hints: spoken when the wearer asks to stop or show hints with no session running.")
    }

    static var needsPhone: String {
        String(localized: "Live hints needs a look at your phone before its first start.",
               comment: "Live hints: spoken when a voice start raised the one-time sheet on the phone.")
    }

    static var switchedOff: String {
        String(localized: "Live hints is switched off in Settings.",
               comment: "Live hints: spoken when the wearer asks to start a session but the feature is turned off.")
    }

    static var noTimeLeft: String {
        String(localized: "There's no free time left today for live hints.",
               comment: "Live hints: spoken when the app-wide daily allowance has no time left at a voice start.")
    }

    static var noHintToShow: String {
        String(localized: "There's no hint to show yet.",
               comment: "Live hints: spoken when the wearer asks to show hints and none has arrived.")
    }

    /// Keyword mode: the keyword now puts its passage on the lens when anyone says it.
    static func keywordAdded(_ keyword: String) -> String {
        String(localized: "I'll hint you when someone says \(keyword).",
               comment: "Live hints: spoken when the wearer adds a keyword by voice in keyword mode. The argument is the keyword.")
    }

    /// The other modes: the keyword helps the captions catch the word; it fires in keyword mode.
    static func keywordListened(_ keyword: String) -> String {
        String(localized: "I'll listen out for \(keyword).",
               comment: "Live hints: spoken when the wearer adds a keyword by voice outside keyword mode. The argument is the keyword.")
    }
}
