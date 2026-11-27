import Foundation

/// What "Record experience" says and shows (Plan IM P1), in one place so the phone's card, the
/// car's spoken prompts and the tests read the same words.
///
/// The five prompts are the partner's structure, offered and never enforced: the technician only
/// talks (decision 1). The second asks for the kind of site rather than the customer, because the
/// standing line asks for no names or addresses, and a site worth mentioning is one P2 moves to a
/// site note rather than a learning (decision 6).
enum ExperienceRecorderCopy {

    /// The card's five prompts, in the order a case is told.
    static var prompts: [String] {
        [
            String(localized: "The equipment: its brand and model, or what it is if you don't know the model."),
            String(localized: "The kind of site, if it matters."),
            String(localized: "The problem as it showed up."),
            String(localized: "What you checked and tried."),
            String(localized: "What fixed it, and how sure you are."),
        ]
    }

    /// The site recording's title and prompts (Plan IM P4): what a site document holds — the units,
    /// how they connect and what is local to the site (Plan HV) — offered, never enforced.
    static var siteTitle: String { String(localized: "Tell me about this site") }
    static var sitePrompts: [String] {
        [
            String(localized: "The units at the site: each one's brand and model, and where it is."),
            String(localized: "How they connect, and which one controls which."),
            String(localized: "Anything local: settings someone changed, and faults you've seen come from the link between two units."),
        ]
    }

    /// What the car reads before a site recording: the title and the site prompts.
    static var carPlaySitePrompts: String {
        ([siteTitle + "."] + sitePrompts).joined(separator: " ")
    }

    /// Said once per recording session, before the first case, on both surfaces.
    static var standingLine: String {
        String(localized: "Please leave out customer names and addresses.")
    }

    /// The card's title and its one line of how to move on.
    static var cardTitle: String { String(localized: "One case per recording") }
    static var cardHowTo: String {
        String(localized: "Say \u{201C}that's one, next case\u{201D} to start the next, or \u{201C}that's all\u{201D} to finish. Each recording stops at ten minutes.")
    }

    /// What the car reads before the first case: the prompts, then how to move on. Nothing to read
    /// on the screen, nothing to tap.
    static var carPlayPrompts: String {
        String(localized: "One case per recording. Say the equipment, its brand and model if you know it. The kind of site, if it matters. The problem as it showed up. What you checked and tried. And what fixed it, and how sure you are. Say \u{201C}that's one, next case\u{201D} to start the next, or \u{201C}that's all\u{201D} to finish.")
    }

    /// The cue that recording has begun.
    static var recordingNow: String { String(localized: "Recording.") }
    static var nextCase: String { String(localized: "Next case. Recording.") }

    static var keptOnPhone: String {
        String(localized: "Saved on this phone for your team to review.")
    }
    static var nothingHeard: String { String(localized: "Nothing was heard, so nothing was kept.") }
    static var capReached: String {
        String(localized: "That's ten minutes, the most one recording holds.")
    }
    static var conversationActive: String {
        String(localized: "Finish the conversation first, then record your experience.")
    }
    static var keptInstead: String { String(localized: "It's saved on this phone instead.") }

    static func filedOnJob(count: Int, jobReference: String?) -> String {
        switch (jobReference, count) {
        case (let reference?, 1):
            return String(localized: "Filed for your team on job \(reference).")
        case (let reference?, _):
            return String(localized: "Filed for your team on job \(reference), in \(count) parts.")
        case (nil, 1):
            return String(localized: "Filed for your team on this job.")
        case (nil, _):
            return String(localized: "Filed for your team on this job, in \(count) parts.")
        }
    }

    /// What the recorder's page says about the audio of a recording.
    static func audioLine(_ recording: ExperienceRecording, hasAudio: Bool, locale: Locale = .current) -> String {
        guard hasAudio, recording.audioDeletedAt == nil else {
            return String(localized: "Audio deleted. The transcript stays.")
        }
        let until = recording.createdAt.addingTimeInterval(ExperienceRecorderRules.audioRetention)
        let day = until.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
        return String(localized: "Audio kept on this phone until \(day).")
    }
}
