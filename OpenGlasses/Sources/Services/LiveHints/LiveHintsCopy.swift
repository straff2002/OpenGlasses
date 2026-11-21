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
}
