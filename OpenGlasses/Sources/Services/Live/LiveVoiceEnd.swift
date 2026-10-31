import Foundation

/// Ending a live session by saying so.
///
/// A live session had no spoken way out: a temple tap, the Action Button, the app's own button or
/// the idle clock, and "bye" left the microphone open. The model is the one that can tell a goodbye
/// said to it from one said across the room, in any language, so it decides through a session-only
/// tool. The transcript check below is the backstop for a model that says goodbye and forgets the
/// tool, or a protocol that has no tools at all.
enum LiveVoiceEndPolicy {

    /// Declared per session beside the tool list, never a `NativeTool`: Direct has its own goodbye,
    /// and this must not reach its prompt or its tool list.
    static let toolName = "end_live_session"

    /// The most words the backstop reads as a sign-off. Anything longer is left to the model.
    static let maxBackstopWords = 6

    /// How long the goodbye may take to finish before the session ends regardless.
    static let speakingBound: TimeInterval = 8

    /// How long after the request a quiet session is taken to have finished. The turn that called
    /// the tool can complete before the reply to its result has started.
    static let settle: TimeInterval = 1.5

    static let toolResult = "The session is ending. Say one short goodbye and nothing else."

    /// Gemini refuses an object with no properties, and the OpenAI mapping needs a `parameters`
    /// value, so the one optional property keeps both happy. Nothing reads it.
    static let declaration: [String: Any] = [
        "name": toolName,
        "description": """
            End this voice session because the user is saying goodbye to you. Never call it for a \
            goodbye said to someone else, or for a question about a word.
            """,
        "parameters": [
            "type": "object",
            "properties": [
                "goodbye": [
                    "type": "string",
                    "description": "The short goodbye you are saying.",
                ]
            ],
        ] as [String: Any],
    ]

    /// Whether a finished turn counts as a goodbye the model did not act on.
    ///
    /// - A model that stayed silent decided it was not being spoken to, so a "bye" on the TV ends
    ///   nothing.
    /// - During a job the tool alone decides. A technician saying "bye" to a customer must not
    ///   drop the session; saying it twice costs less.
    /// - An interpreter translates every line, so a reply proves nothing, and a goodbye between the
    ///   two people is what it is there to say.
    static func backstopApplies(transcript: String, modelReplied: Bool, jobActive: Bool,
                                interpreting: Bool = false, parser: VoiceCommandParser) -> Bool {
        guard modelReplied, !jobActive, !interpreting else { return false }
        guard PhraseMatcher.tokenize(transcript).count <= maxBackstopWords else { return false }
        return parser.isGoodbye(transcript)
    }
}

/// What has been asked for and what is still in the way: the goodbye still being spoken, or a tool
/// still running. Time is passed in, so every case is tested without a session.
struct LiveVoiceEndTracker: Equatable {

    private(set) var requestedAt: Date?
    /// When the tools last went quiet; the speaking bound counts from here.
    private var quietSince: Date?
    private var turnEnded = false

    var isPending: Bool { requestedAt != nil }

    /// The session should end. A second request, the backstop after the tool, changes nothing.
    mutating func request(now: Date, turnAlreadyEnded: Bool = false) {
        guard requestedAt == nil else { return }
        requestedAt = now
        quietSince = now
        turnEnded = turnAlreadyEnded
    }

    mutating func noteTurnComplete() {
        guard isPending else { return }
        turnEnded = true
    }

    /// Whether the session can stop now. A running tool holds it, however long: the wearer asked
    /// for that too, and the reply to it restarts the wait.
    mutating func shouldStop(now: Date, toolRunning: Bool, playbackPending: Bool) -> Bool {
        guard let requestedAt, let quiet = quietSince else { return false }
        if toolRunning {
            quietSince = now
            turnEnded = false
            return false
        }
        if now.timeIntervalSince(quiet) >= LiveVoiceEndPolicy.speakingBound { return true }
        return turnEnded && !playbackPending
            && now.timeIntervalSince(requestedAt) >= LiveVoiceEndPolicy.settle
    }
}

/// The Live instruction's words about who is being spoken to and how a session ends.
enum LiveAddressingInstruction {

    /// Presets that exist to hear everyone in the room.
    private static let hearsTheRoom: Set<String> = ["translator", LiveAIMode.interpreterID]

    static func block(modeID: String, canEndSession: Bool) -> String {
        var sections: [String] = []
        if !hearsTheRoom.contains(modeID) {
            var room = """
            WHO YOU ARE TALKING TO:
            The microphone hears the whole room. Reply only when the user is speaking to you. Stay \
            silent for a TV, radio or music, and when people are talking to each other: say nothing \
            at all, not even a short acknowledgment.
            """
            if modeID == BlindAssistanceContract.presetID {
                room += " If it could be a question for you, answer it."
            }
            sections.append(room)
        }
        if canEndSession {
            sections.append("""
            ENDING THE SESSION:
            When the user is saying goodbye to you, in any language ("bye", "I've got to go", \
            "talk to you later"), say one short goodbye and call \(LiveVoiceEndPolicy.toolName).
            """)
        }
        return sections.joined(separator: "\n\n")
    }
}
