import Foundation

// The small decisions around a talk-through session (Plan JI §7a, P6b): who owns the captions,
// taps, ear and lens; what a tap and a few fixed words mean; which mic hears the wearer; when
// recognition must stay on the phone. Pure, so each is a test.

/// The session that owns the captions, the temple taps, the ear and the lens while it runs. Live
/// hints and talk-through never run at once (decision 25): one owner each keeps the rules simple.
enum HintSessionOwner: String, Equatable, Sendable {
    case liveHints
    case talkThrough
}

/// Starting one session while the other runs stops the other, with one spoken line.
enum HintSessionArbiter {

    struct Handover: Equatable, Sendable {
        /// The session to stop first, if any.
        let stop: HintSessionOwner?
        /// The one line said about it.
        let line: String?
    }

    static func start(_ starting: HintSessionOwner, running: HintSessionOwner?) -> Handover {
        guard let running, running != starting else { return Handover(stop: nil, line: nil) }
        switch starting {
        case .talkThrough: return Handover(stop: running, line: TalkThroughCopy.liveHintsStopped)
        case .liveHints: return Handover(stop: running, line: TalkThroughCopy.talkThroughStoppedForLiveHints)
        }
    }

    /// The session holding the taps and the Live Activity now, if any.
    static func owner(liveHintsRunning: Bool, talkThroughRunning: Bool) -> HintSessionOwner? {
        if talkThroughRunning { return .talkThrough }
        if liveHintsRunning { return .liveHints }
        return nil
    }
}

/// What a temple tap or a media button does while talk-through runs (decision 26). A tap never
/// moves the runner unless a proposal is waiting for its yes.
enum TalkThroughTapPolicy {

    enum Outcome: Equatable, Sendable {
        /// No talk-through: the tap goes on to whoever else holds the taps.
        case notOurs
        /// Yes to "Sounds like you're on …?".
        case confirmProposal
        case repeatHint
        /// Skip the hint playing, or the proposal waiting (it is not asked again on this step).
        case skip
        case ignored
    }

    static func resolve(_ gesture: TempleGesture, sessionRunning: Bool, proposalWaiting: Bool,
                        hintPlaying: Bool) -> Outcome {
        guard sessionRunning else { return .notOurs }
        switch gesture {
        case .one: return proposalWaiting ? .confirmProposal : .repeatHint
        case .two: return (hintPlaying || proposalWaiting) ? .skip : .ignored
        // Three taps do nothing, as in live hints: a stray tap must never stop the session.
        case .three: return .ignored
        }
    }

    static func earcon(for outcome: Outcome) -> TempleEarcon? {
        switch outcome {
        case .notOurs: return nil
        case .confirmProposal, .repeatHint, .skip: return .accepted
        case .ignored: return .refused
        }
    }
}

/// The fixed phrases talk-through answers. Whole utterances only, a leading filler and a trailing
/// "please" allowed, so "can you talk me through it in more detail" is a question for the
/// assistant, not a command.
enum TalkThroughVoiceCommand: Equatable, Sendable {
    case start
    case stop
    /// "Just go": proposals become spoken advances for the rest of the job.
    case justGo

    static let startPhrases: Set<String> = [
        "talk me through it", "talk me through this", "talk me through the job",
        "talk me through the procedure", "talk me through", "talk me through this job",
    ]
    static let stopPhrases: Set<String> = [
        "stop talking me through", "stop talking me through it", "stop talking me through this",
        "stop the talk through", "stop talk through", "stop talking me through the job",
    ]
    static let justGoPhrases: Set<String> = ["just go", "just go ahead", "just keep going", "just move me on"]

    private static let fillers: Set<String> = ["ok", "okay", "hey", "uh", "um", "now", "so"]

    static func parse(_ text: String) -> TalkThroughVoiceCommand? {
        let phrase = core(text)
        if startPhrases.contains(phrase) { return .start }
        if stopPhrases.contains(phrase) { return .stop }
        if justGoPhrases.contains(phrase) { return .justGo }
        return nil
    }

    /// Folded words, a leading filler and a trailing "please" dropped; "talk-through" reads as
    /// two words.
    static func core(_ text: String) -> String {
        var words = HintText.words(text.replacingOccurrences(of: "\u{2019}", with: "'"))
        words = Array(words.drop { fillers.contains($0) })
        if words.last == "please" { words.removeLast() }
        return words.joined(separator: " ")
    }
}

/// A yes or no to a waiting proposal, in a short whole utterance: the no-model procedure's own yes
/// and no words (`AnswerReader`'s, as its read-back uses them), plus a few ways to agree that are
/// not answers anywhere else ("that's right"). Anything longer is narration, not a reply.
enum TalkThroughReply {

    static let maximumWords = 4
    static let extraYes: Set<String> = ["thats right", "that s right", "right", "thats it", "that s it",
                                        "yes thats right", "yes that s right", "yep thats it", "yep that s it",
                                        "spot on", "it is", "i am"]
    static let extraNo: Set<String> = ["not yet", "no not yet", "wrong", "not there yet", "no i m not",
                                       "no im not", "nope not yet"]

    /// The confirmation's yes/no reading, the same one a no-model read-back is answered with.
    private static let confirmation = StepAnswer(recordAs: "confirmation", kind: .yesNo, label: "confirmation")

    /// True for yes, false for no, nil for anything else.
    static func parse(_ text: String) -> Bool? {
        let core = TalkThroughVoiceCommand.core(text)
        guard !core.isEmpty else { return nil }
        if extraYes.contains(core) { return true }
        if extraNo.contains(core) { return false }
        guard core.split(separator: " ").count <= maximumWords else { return nil }
        guard case .accepted(let value) = AnswerReader.read(text, for: confirmation) else { return nil }
        return value.option == "yes"
    }

    /// Whether the procedure's own voice handling would take these words on this step (Plan MN
    /// §4): a step word, the step's answer, a read-back's yes or no, a corrective note. Then the
    /// words are the procedure's, and talk-through leaves them alone.
    static func procedureNeeds(_ text: String, on presentation: ProcedureStepPresentation?,
                               locale: Locale = .current) -> Bool {
        guard let presentation else { return false }
        return ProcedureVoiceDecider.decide(text, on: presentation, locale: locale) != .fallback
    }
}

/// Which mic hears the wearer while talk-through runs (decision 24). The input is the wearer's own
/// voice, so this is the one place the glasses' mic is the right one: on glasses with no display,
/// at the cost of call-quality playback, which short hints can live with. On Display glasses the
/// hands-free mic covers the lens with the call screen and is reported to end the Display session,
/// so the phone listens (a wired headset's mic, plugged in, is the phone's input). With no glasses,
/// the phone.
enum TalkThroughMicPlan {

    static func route(glassesConnected: Bool, glassesHaveDisplay: Bool) -> MicRoute {
        glassesConnected && !glassesHaveDisplay ? .glasses : .phone
    }

    /// The step screen's line saying which mic listens.
    static func line(route: MicRoute, glassesHaveDisplay: Bool) -> String {
        switch route {
        case .glasses:
            return String(localized: "Listening on the glasses' microphone. Playback drops to call quality while it runs.",
                          comment: "Talk-through: the glasses' mic hears the technician; music and speech play at phone-call quality.")
        case .phone, .headset:
            return glassesHaveDisplay
                ? String(localized: "Listening on the phone's microphone, so the lens stays clear.",
                         comment: "Talk-through on glasses with a display: the phone's mic hears the technician so the lens is not covered.")
                : String(localized: "Listening on the phone's microphone.",
                         comment: "Talk-through: the phone's mic hears the technician.")
        }
    }
}

/// When the narration must be recognised on the phone (§7a, "The phone is forced"): a job sealed to
/// its vault, Medical Compliance mode, Medical Local Only and a Private Conversation. With signal and
/// none of these, the recogniser may use the server, which is better on trade words; without signal
/// it is on the phone either way. Where the wearer is and the hints are worked out on the phone in
/// every case.
enum TalkThroughRecognitionPolicy {
    static func requiresOnDevice(vaultOnly: Bool, medicalCompliance: Bool, medicalLocalOnly: Bool,
                                 privateConversation: Bool) -> Bool {
        vaultOnly || medicalCompliance || medicalLocalOnly || privateConversation
    }
}

/// The words of talk-through. English for now; the catalog sync translates them.
enum TalkThroughCopy {
    static let switchLabel = String(localized: "Talk me through it", comment: "Procedure step screen: the switch that turns talk-through on for this run.")
    static let switchHint = String(localized: "Say what you're doing as you work. The app works out your step and shows that step's own hints. It moves on only when you say yes.",
                                   comment: "Procedure step screen: what the talk-through switch does.")
    static let started = String(localized: "Talking you through it. Say what you're doing as you go.",
                                comment: "Said when talk-through starts on a procedure.")
    static let stopped = String(localized: "Stopped talking you through it.", comment: "Said when talk-through stops.")
    static let alreadyRunning = String(localized: "I'm already talking you through it.", comment: "Talk-through is already on.")
    static let justGo = String(localized: "OK, I'll move you on as you go.",
                               comment: "Talk-through: after 'just go', a step it hears you on is taken without asking.")
    static let liveHintsStopped = String(localized: "Live hints stopped; talking you through the job.",
                                         comment: "Said when talk-through starts and stops a running live hints session.")
    static let talkThroughStoppedForLiveHints = String(localized: "Stopped talking you through the job; live hints are on.",
                                                       comment: "Said when live hints starts and stops talk-through.")
    static let proposalPrompt = String(localized: "Tap once or say yes.",
                                       comment: "Talk-through lens line under a proposed step: how to accept it.")
    static let proposalYes = String(localized: "Yes, move on", comment: "Talk-through phone button: accept the proposed step.")
    static let proposalNo = String(localized: "Not yet", comment: "Talk-through phone button: stay on the current step.")
    static let lensTitle = String(localized: "Talk-through", comment: "Talk-through lens card title over a proposal.")
    static let justGoButton = String(localized: "Move on without asking", comment: "Talk-through phone button: take each step it hears you on, without a yes.")
    static let justGoHint = String(localized: "For the rest of this run, a step it hears you on is taken and said aloud, as if you said next.",
                                   comment: "Talk-through: what 'Move on without asking' does.")

    static func proposal(_ title: String) -> String {
        String(localized: "Sounds like you're on \(title)?", comment: "Talk-through: the step the technician seems to be on, asked, never assumed.")
    }

    static func moved(_ title: String) -> String {
        String(localized: "On \(title).", comment: "Talk-through after 'just go': the step it moved to.")
    }

    static func offOrder(target: String, open: String) -> String {
        String(localized: "Sounds like \(target). \(open) isn't done: skipped it, or did it differently?",
               comment: "Talk-through: the technician seems to have moved past a step that asks for something. Never blocks.")
    }
}
