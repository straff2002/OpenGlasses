import Foundation

/// Where a spoken line came from (Plan KL P4).
///
/// A support report logs the length of every line the app speaks (`tts event=speaking
/// characters=94`) and never its words: the words are the assistant's half of the conversation and
/// as private as the wearer's. A length alone could not say what a line was. One report had a
/// 94-character line hold back a turn by six seconds, and nothing in it said whether that was the
/// reply, a switch notice, a disclosure or a job line. So every line now carries one of these
/// tokens, logged beside its length as `source=<token>`.
///
/// **Required, not defaulted.** `TextToSpeechService.speak`, `speakReporting` and `speakStreaming`
/// take it with no default, so the compiler finds every caller and a new one has to say what it is.
/// `SpeechSourceGuardTests` scrapes the sources for the rest: a wrapper that forwarded a default
/// would put every line through it under one token.
///
/// The set is coarse on purpose: a kind of line, not a call site. A report reader needs to tell the
/// answer from the app talking about itself, and the app's own lines from one another; a token per
/// file would be noise. Each is a case name: an enum token, PrivacyLog-safe, and never text.
enum SpeechSource: String, CaseIterable, Sendable {
    /// The model's answer to the wearer: a Direct turn's reply, spoken whole or a sentence at a
    /// time, a photo answer, the agent's or the gateway's reply, a tool's own spoken result.
    case reply
    /// An answer made on the phone with no model: a tier-0 tool answer, or the offline handoff's
    /// reply and hold line.
    case phoneAnswer
    /// What a turn says when it could not answer: the cascade's exhaustion line, a photo failure.
    case errorLine
    /// The model-switch and routing notice played alongside the request (`TurnAnnouncement`).
    case switchNotice
    /// "This is AI": the conversation cue and its once-ever introduction, the translation and
    /// assessment disclosures, the interpreter's cloud notice.
    case disclosure
    /// A question the wearer has to answer: the tool-consent prompt, an ambiguous face.
    case confirmation
    /// A command done or refused: goodbye, a new chat, media resuming, a temple-tap result.
    case acknowledgement
    /// Work still going: a long tool's "still working", the agent harness narrating, a remote
    /// command about to run.
    case progress
    /// Something the app raised on its own: a calendar or place reminder, a briefing, a digest, a
    /// memory nudge, what was held while the wearer was away, a chat line read back.
    case alert
    /// The state of the glasses, the connection or a recording: an update requirement, a recording
    /// stopped, a broadcast or expert stream ended, the offline handoff, a sync conflict.
    case statusNotice
    /// Field Assist: the guided job's steps and questions, a debrief, an upcoming job, a job file,
    /// a clip, a send to the office.
    case job
    /// Speech on behalf of someone else's words: a live translation, a fingerspelled word.
    case translation
    /// Getting around: walking directions, navigation and assistive guidance, Scan Assist
    /// reminders, the parking photo.
    case navigation
    /// Describing what the camera sees: scene narration and its notices, a recognised face.
    case narration
    /// Coaching while the wearer works: the live coach, first aid.
    case coaching
    /// The assistant starting, stopping or failing to start (the audible lifecycle, a live start).
    case lifecycle
    /// Words an agent, a remote command or an MCP client asked the glasses to say.
    case agent
    /// The wearer pressed a button to hear something on screen read out.
    case readAloud
    /// A test line: a subsystem probe, the live readiness check, the readiness walkthrough.
    case diagnostic

    /// The log token.
    var token: PrivacyToken { PrivacyToken(rawValue) }
}
