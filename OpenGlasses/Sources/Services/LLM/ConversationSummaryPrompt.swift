import Foundation

/// The instruction `LLMService` sends when it folds older messages into one summary message.
///
/// The summary outlives the day it is written: it is persisted on the conversation thread and read
/// back on later turns, possibly days later. A summary that says "tomorrow" or "next Friday" is then
/// wrong without anyone noticing, so the prompt gives the model today's date and asks for absolute
/// dates. Where the excerpt doesn't make clear which date is meant (a restored thread may be older
/// than today), the speaker's words are kept in quotes rather than resolved against the wrong day.
enum ConversationSummaryPrompt {

    /// Written as e.g. "Saturday 31 October 2026": unambiguous in every locale the model reads.
    static func dateLine(now: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return formatter.string(from: now)
    }

    static func make(transcript: String, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let today = dateLine(now: now, timeZone: timeZone)
        return """
        Summarize the following conversation excerpt concisely. Preserve:
        - All user-stated facts, names, and preferences
        - Decisions made and commitments given
        - Tool calls and their key results
        - Memory commands ([REMEMBER], [FORGET])
        - Any unresolved questions or action items

        Today is \(today). Write every date as an absolute date (for example "\(today)"), never \
        "today", "tomorrow", "yesterday" or "next week": this summary is read again on later days. \
        If the excerpt doesn't make clear which date is meant, keep the speaker's words in quotes.

        Keep it under 300 words. Use plain text, no formatting.

        CONVERSATION:
        \(transcript)
        """
    }
}
