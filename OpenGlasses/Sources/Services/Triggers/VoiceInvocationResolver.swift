import Foundation

/// What a request from the glasses' own assistant to open the app depends on (Plan JV P1).
///
/// Meta's SDK can hand the app a "launch" request when the wearer says "Hey Meta, open Avenkin".
/// That request is an experimental API and is only ever received in a flagged build
/// (`Sources/Glasses/Experimental/`); deciding what it means needs none of it, so the decision
/// lives here, compiled and tested in every build.
struct VoiceInvocationContext: Equatable {
    /// The same reading the temple taps decide on.
    var temple: TempleContext
    /// Another person is on the line — live translation or an expert call
    /// (`MediaTriggerPolicy.classify` is `.otherParty`). The request stays out of it, the same as
    /// the temple taps' claim does.
    var otherPartyOnLine: Bool = false
}

/// The thing to do for a request that is taken.
enum VoiceInvocationAction: Equatable {
    /// What "start talking" means in the chosen mode: Direct mode listens for a turn
    /// (`handleWakeWordDetected(manual: true)`), a live mode starts its session
    /// (`requestLiveSession(_, source: .voiceInvocation)`).
    case startListening
    /// A reply is being spoken: stop it and listen, the same barge-in as speaking over it.
    case interruptAndListen
}

/// Why a request was answered with a failure. Each carries the short sentence Meta's assistant may
/// say back to the wearer.
enum VoiceInvocationRefusal: String, Equatable, CaseIterable {
    /// The wake-word mic, or the running live session's mic, is muted.
    case micMuted
    /// Another person is on the line.
    case otherParty
    /// A reply is being worked out, or another mode owns the loop.
    case busy
    /// The wearer turned the feature off (it can be asked for just as the switch changes).
    case switchedOff
    /// The action ran but nothing ended up listening.
    case didNotStart
    /// No answer within the deadline. The request is never left unanswered.
    case timedOut

    /// At most one short sentence: the assistant reads it aloud.
    var actionOutput: String {
        switch self {
        case .micMuted:
            return String(localized: "Avenkin's microphone is muted.")
        case .otherParty:
            return String(localized: "Avenkin is in a call right now.")
        case .busy:
            return String(localized: "Avenkin is busy right now.")
        case .switchedOff:
            return String(localized: "That's turned off in Avenkin's settings.")
        case .didNotStart:
            return String(localized: "Avenkin couldn't start listening.")
        case .timedOut:
            return String(localized: "Avenkin didn't respond in time.")
        }
    }
}

enum VoiceInvocationOutcome: Equatable {
    case run(VoiceInvocationAction)
    /// Already listening (a turn, or a live session): nothing to do, and the answer is success.
    case alreadyListening
    case refuse(VoiceInvocationRefusal)
}

/// How a request is answered: success or failure, with at most one short sentence of output.
struct VoiceInvocationAnswer: Equatable {
    var success: Bool
    /// Nil on success: the app's own tone and listening are the confirmation.
    var actionOutput: String?
    /// Why it failed, for the support report; nil on success.
    var refusal: VoiceInvocationRefusal?

    static let success = VoiceInvocationAnswer(success: true, actionOutput: nil, refusal: nil)

    static func failure(_ refusal: VoiceInvocationRefusal) -> VoiceInvocationAnswer {
        VoiceInvocationAnswer(success: false, actionOutput: refusal.actionOutput, refusal: refusal)
    }
}

/// Maps "Hey Meta, open Avenkin" to what it should do right now (Plan JV P1). Pure.
///
/// A launch request means what "start talking" means everywhere else, so the activity table is the
/// temple taps' (`TempleActionResolver`, `.startTalking`); this adds only what a request from
/// another assistant needs on top: it must always be answered, it stays out of a call another
/// person is on, and a muted mic is a reason to say no rather than to listen anyway.
enum VoiceInvocationResolver {

    static func resolve(_ context: VoiceInvocationContext, enabled: Bool = true) -> VoiceInvocationOutcome {
        guard enabled else { return .refuse(.switchedOff) }
        if context.otherPartyOnLine { return .refuse(.otherParty) }
        let temple = context.temple
        let muted = temple.activity == .liveSession ? temple.liveMicMuted : temple.micMuted
        if muted, temple.activity != .busy { return .refuse(.micMuted) }
        switch TempleActionResolver.resolve(action: .startTalking, context: temple) {
        case .run(.startListening): return .run(.startListening)
        case .run(.interruptAndListen): return .run(.interruptAndListen)
        case .ignored(.alreadyListening): return .alreadyListening
        case .ignored, .run: return .refuse(.busy)
        }
    }

    /// The answer for an outcome once its action, if any, has run. `started` is whether something
    /// is listening afterwards; it is ignored for outcomes that ran nothing.
    static func answer(for outcome: VoiceInvocationOutcome, started: Bool) -> VoiceInvocationAnswer {
        switch outcome {
        case .run: return started ? .success : .failure(.didNotStart)
        case .alreadyListening: return .success
        case .refuse(let refusal): return .failure(refusal)
        }
    }

    /// Whether the app is listening for the wearer, for `answer(for:started:)` after an action.
    /// Thinking counts: a turn that heard nothing and closed fast is still a start.
    static func isListening(_ activity: TempleContext.Activity) -> Bool {
        switch activity {
        case .listening, .liveSession, .thinking: return true
        case .standby, .speaking, .busy: return false
        }
    }

    /// How long the glasses' assistant waits for an answer before the app answers failure itself.
    static let answerDeadline: Duration = .seconds(5)
}
