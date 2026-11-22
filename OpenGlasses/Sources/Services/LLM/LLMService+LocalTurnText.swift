import Foundation

/// The pure wording and checks of the local (downloaded-model) turn, kept out of `LLMService.swift`
/// so the device qualification app (`Scripts/local-model-qualification`, Plan MQ P3) compiles the
/// same lines the app speaks and prompts with, rather than a copy: the date line, the stall
/// detectors and their corrections, the Hermes fallback instruction, the native tool guide and
/// the honest-miss line. Moved unchanged from `LLMService.swift`.
extension LLMService {

    /// "Tuesday, 15 July 2026, 6:41 pm (Pacific/Auckland)" — injected into every system
    /// prompt. Pure and injectable for tests.
    nonisolated static func currentDateTimeLine(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, d MMMM yyyy, h:mm a"
        return "\(formatter.string(from: now)) (\(timeZone.identifier))"
    }

    /// True when the reply narrates an intention to fetch/check something without any
    /// tool markup — the shape a small model produces instead of acting. `assistantName` is the
    /// assistant's own name, which a small model promises in as it would in "I" (Gemma 4 E2B on the
    /// phone: "Avenkin will log the line voltage reading and calculate the voltage drop for you.").
    nonisolated static func announcesToolIntent(_ response: String,
                                                assistantName: String = Config.assistantName) -> Bool {
        let lowered = response.lowercased()
        guard !lowered.contains("<tool_call>") else { return false }
        // A promise-instead-of-action reply is SHORT (a sentence or two). A long answer that
        // merely contains "searching for"/"let me check" mid-prose is an answer, not a stall —
        // without this gate the never-speak-a-promise net could discard valid replies.
        guard lowered.count < 280 else { return false }
        let intentPhrases = [
            "looking up", "look that up", "look it up", "let me check", "i'll check",
            "i will check", "checking the", "let me get", "i'll get", "i'm getting",
            "fetching", "one moment", "just a moment", "i'm looking",
            // Search-flavoured announcements (live-traced: "I will now search for popular
            // tourist destinations in Samoa for you" — then silence). Anchored to first-person
            // intent so an answer that merely mentions searching doesn't match.
            "i will now search", "i will search", "i'll search", "let me search",
            "i'm searching", "searching for", "i should have used a tool",
            "i will use a tool", "using a tool to",
        ]
        if intentPhrases.contains(where: { lowered.contains($0) }) { return true }
        // A promise of a job action instead of the call (Plan MQ P3, traced on the phone: "I will
        // log the line voltage first, and then calculate the drop…"). Not when the reply also asks
        // something or waits on the wearer: "I'll log it once you tell me the value" is not a stall.
        guard !lowered.contains("?"), !waitingOnWearer.contains(where: { lowered.contains($0) }) else { return false }
        let straightened = lowered.replacingOccurrences(of: "\u{2019}", with: "'")
        if actionPromisePhrases.contains(where: { straightened.contains($0) }) { return true }
        // The name only as a word of its own, so a short name is not found inside another word.
        let spaced = " " + straightened
        return namedPromisePhrases(assistantName).contains { spaced.contains(" " + $0) }
    }

    /// Words that make a promise wait on the wearer rather than stand in for a call.
    nonisolated static let waitingOnWearer = ["once you", "when you", "if you", "after you", "tell me", "give me"]

    /// First-person promises of a Field Assist action: a log, a calculation.
    nonisolated static let actionPromisePhrases: [String] = {
        let openers = ["i will", "i'll", "let me", "i'm going to", "i am going to", "i will now", "i'll now", "i'm about to"]
        return openers.flatMap { opener in promisedActions.map { opener + " " + $0 } }
    }()

    nonisolated static let promisedActions = ["log", "record", "calculate", "work out", "figure out",
                                              "save the reading", "note the reading"]

    /// The same promises with the assistant's name for "I", lowercased: "avenkin will log",
    /// "avenkin is going to calculate", and the running form, "avenkin is logging". Empty for no name.
    nonisolated static func namedPromisePhrases(_ assistantName: String) -> [String] {
        let name = assistantName.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
        guard !name.isEmpty else { return [] }
        let openers = ["will", "'ll", "will now", "is going to", "is about to"].map {
            $0.hasPrefix("'") ? name + $0 : name + " " + $0
        }
        let running = ["logging", "recording", "calculating", "working out", "figuring out",
                       "saving the reading", "noting the reading"]
        return openers.flatMap { opener in promisedActions.map { opener + " " + $0 } }
            + running.map { name + " is " + $0 }
    }

    /// True when the reply asks the user to supply their location — the model has
    /// where_am_i available and must never ask (live-traced: "If you tell me your current
    /// location, I can check the forecast for you").
    nonisolated static func asksUserForLocation(_ response: String) -> Bool {
        let lowered = response.lowercased()
        guard !lowered.contains("<tool_call>") else { return false }
        let askPhrases = [
            "your location", "your current location", "where you are",
            "what city", "which city", "your city", "share your location",
        ]
        if askPhrases.contains(where: { lowered.contains($0) }) { return true }
        // "Tell me where" asks for a location only when it is the wearer's own: "tell me where you
        // are", not "tell me where you saw this E223 code" (Plan MQ P3, a restraint case on the phone).
        let straightened = lowered.replacingOccurrences(of: "\u{2019}", with: "'")
        for opener in ["tell me where ", "let me know where "] {
            var searchRange = straightened.startIndex..<straightened.endIndex
            while let found = straightened.range(of: opener, range: searchRange) {
                let rest = straightened[found.upperBound...]
                if ["you are", "you're", "youre", "you currently are", "you're currently", "you are currently"]
                    .contains(where: { rest.hasPrefix($0) }) { return true }
                searchRange = found.upperBound..<straightened.endIndex
            }
        }
        return false
    }

    /// Round 0's corrections after a stall, shared with `LocalToolLoop` so both say the same thing.
    nonisolated static let localLocationCorrection = "The user's location is already available to you — never ask for it. Call the where_am_i or get_weather tool now via <tool_call> in the exact format, then answer."
    nonisolated static let localIntentCorrection = "You said you would look that up, but you did not call a tool. Either output the <tool_call> now in the exact format, or answer directly. Never say you will check — act."
    /// The correction after a reply that said an action was done when no call did it (Plan MQ P3,
    /// `LocalToolLoop.unbackedClaim`). Read by the model, never spoken.
    nonisolated static let localClaimCorrection = "You said it was done, but no tool was called this turn, so nothing was done. Call the tool now, or say plainly that it has not been done. Never say something was done unless a tool result in this turn says so."

    /// The reduced tool block appended to the lean on-device prompt. Extracted (and pure)
    /// so the location nudge is testable: without it, a small model that has no USER
    /// LOCATION line answers "I can't find your location" instead of calling `where_am_i`.
    nonisolated static func localToolInstructions(toolNames: [String]) -> String {
        guard !toolNames.isEmpty else { return "" }
        var block = """

        \nTOOLS (use sparingly, only when the user clearly needs one):
        Output exactly: <tool_call>{"name": "tool_name", "arguments": {"key": "value"}}</tool_call>
        Available: \(toolNames.joined(separator: ", "))
        Only use a tool if the user explicitly asks for that action. Otherwise just answer directly.
        """
        if toolNames.contains("where_am_i") {
            block += "\nIf you need the user's location and it isn't given above, call where_am_i — never say you lack location access and never ask the user where they are."
        }
        if toolNames.contains("calendar") {
            // Live-traced: without the argument schema the model only ever got the default
            // ("today"), asked the user for dates it couldn't use, then denied having access.
            block += "\ncalendar arguments: {\"action\": \"today\" | \"tomorrow\" | \"next\" | \"upcoming\"} — pick the one matching the day asked about. You DO have the user's calendar through this tool; never claim you lack calendar access and never ask for a date when one of these actions fits."
        }
        return block
    }

    /// The tool block for a native tool turn. The definitions themselves are rendered by the
    /// model's chat template, so this says only how to use them.
    /// A qualification run's experiment (the device app's `--original-tool-guide`): the guide as P1
    /// shipped it, to compare against. Set only by the device qualification app; the app never sets it.
    nonisolated(unsafe) static var qualificationUsesOriginalToolGuide = false

    nonisolated static func localNativeToolGuide(toolNames: [String]) -> String {
        guard !toolNames.isEmpty else { return "" }
        if qualificationUsesOriginalToolGuide { return originalNativeToolGuide(toolNames: toolNames) }
        var block = "\n\nTOOLS: the tools you may call this turn are declared to you. When the user asks you to do "
            + "something a tool does (log, record, start, open, pause, resume, end, show, look up), call that tool now, "
            + "in this reply, with what the user said; don't ask first and don't describe the call. Never say you did "
            + "something unless a tool result in this turn says it was done. When no tool does what the user asked, "
            + "answer directly. After a tool result, answer from it in one or two spoken sentences, and never repeat a "
            + "call you have already made."
        if toolNames.contains("where_am_i") {
            block += " If you need the user's location and it isn't given above, call where_am_i — never ask the user where they are."
        }
        if toolNames.contains("reading") || toolNames.contains("field_session") {
            block += " On the job: when the technician gives a value to log, call reading with that value and its unit; "
                + "run job steps with the job tools; never invent a value."
        }
        return block
    }

    /// P1's guide, kept for the comparison above.
    nonisolated private static func originalNativeToolGuide(toolNames: [String]) -> String {
        var block = "\n\nTOOLS: the tools you may call this turn are declared to you. Call one only when the user "
            + "clearly needs it; otherwise answer directly. After a tool result, answer from it in one or two spoken "
            + "sentences, and never repeat a call you have already made."
        if toolNames.contains("where_am_i") {
            block += " If you need the user's location and it isn't given above, call where_am_i — never ask the user where they are."
        }
        if toolNames.contains("reading") || toolNames.contains("field_session") {
            block += " On the job: log a value the technician reports with reading, and run job steps with the job tools; never invent a value."
        }
        return block
    }

    /// The one honest-miss line the local path speaks when a turn produced no answer it may say —
    /// a promise it never kept, or output that was nothing but broken tool protocol. It claims
    /// nothing happened and invites a retry, which is the only truthful thing left to say.
    nonisolated static let localMissMessage = "I couldn't get that information just now — please ask me again."
}
