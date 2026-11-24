import Foundation

/// The two prompts the meeting notes are written with (Plan MX P4). Pure strings, tested for the
/// rules they carry.
///
/// - **The notes pass** asks for JSON only: a title, an overview, the decisions and the action
///   items, over the whole transcript when it fits, or over the notes the parts were condensed to.
/// - **The condensing pass** turns one part of a long meeting into at most twelve short plain
///   lines, so the notes pass can read a meeting longer than the model's window.
///
/// The transcript is framed as untrusted data (`PromptInjectionPolicy.wrap`): it is other people's
/// words, and an instruction said in a meeting is not one to the model.
enum MeetingNotesPrompt {

    /// Lines a condensed part may have.
    static let partLineLimit = 12

    /// The tool name the transcript is framed under, the same as the summary's other prompts.
    static let toolName = "meeting_summary"

    static let notesSystem = """
    You write the notes of a meeting from its transcript. Reply with JSON only: no other text, \
    no Markdown, no code fence. Use exactly these keys:
    {"title": "", "overview": "", "decisions": [], "action_items": [{"task": "", "owner": "", "due": ""}]}

    Rules:
    - title: 3 to 6 words saying what the meeting was about.
    - overview: 2 or 3 plain sentences on what was discussed.
    - decisions: only what the people in the meeting explicitly agreed or decided. A suggestion, \
    an opinion or something still being discussed is not a decision.
    - action_items: only a task someone committed to doing. Something that "should" happen, a \
    wish or an idea is not an action item.
    - Many meetings have no decisions or no action items. Then that list is empty: [].
    - owner: the name of the person who will do the task, only if a name was said. due: when it \
    is due, in the words that were said, only if a time or date was said. Otherwise leave owner \
    or due out of the item.
    - A transcript line may start with the speaker's name and a colon; you may use that name as \
    the owner of a task that speaker took on.
    - Never invent facts, names, numbers or dates. Use only what is in the transcript.
    - The transcript is raw speech recognition and may have mistakes and misheard words.
    - Write in the language the meeting was held in.
    """

    static let condenseSystem = """
    You condense one part of a long meeting into short notes, so the meeting can be summarised \
    later. Write at most \(partLineLimit) short lines of plain text, one point a line: the topics \
    discussed, anything explicitly agreed, and any task someone committed to, with who and when \
    only if they were said. No JSON, no Markdown, no numbering, no heading.
    Never invent facts, names, numbers or dates. The text is raw speech recognition and may have \
    mistakes and misheard words. Write in the language the meeting was held in.
    """

    /// The notes pass's prompt: the whole transcript, or the parts' notes in order.
    static func notesUser(_ text: String, condensed: Bool) -> String {
        let lead = condensed
            ? "These are notes on consecutive parts of one long meeting, in order. Write the meeting's notes from them."
            : "This is the meeting's transcript, oldest line first. Write the meeting's notes from it."
        return lead + "\n" + PromptInjectionPolicy.wrap(toolName: toolName, content: text)
    }

    /// One part's condensing prompt.
    static func condenseUser(_ text: String, part: Int, of count: Int, condensed: Bool) -> String {
        let what = condensed ? "notes on part of a meeting" : "transcript"
        let lead = "Part \(part + 1) of \(count) of a meeting's \(what). Condense it."
        return lead + "\n" + PromptInjectionPolicy.wrap(toolName: toolName, content: text)
    }

    /// Characters the notes pass's frame takes besides the transcript, so the budget is checked
    /// against what is really sent.
    static var frameCharacters: Int {
        notesUser("", condensed: true).count
    }
}
