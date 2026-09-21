import Foundation

/// What the app still needs to know about the job number, and how it gets there.
///
/// The job number is the one thing a work record cannot be reconstructed without, and it is also
/// the thing a technician standing on a roof is least likely to volunteer. So the app asks — the
/// app, not the model, because a prompt the model may ignore is not a guarantee and this is the
/// state the whole record is filed under.
///
/// Two facts drive the shape of this machine:
///
///  1. **Speech-recognised digits are unreliable.** "Ten oh five" comes back as "10 or 5" often
///     enough that recording what was heard without reading it back would file work under a number
///     nobody used. So there is a `confirming` state between hearing and recording.
///  2. **A technician who has no job number must be able to say so and be left alone.** `declined`
///     is a real answer, written into the audit log, and it never blocks delivery — the record is
///     flagged, the work still goes out (owner decision, 2026-09-21).
///
/// The number itself is recorded **exactly as it was given**: no case folding, no digit grouping,
/// no inference from a work order or a nearby asset id. The only text removed is a leading carrier
/// phrase the technician spoke around it ("it's job 1005" → "1005"), and the read-back shows the
/// result before it is written down.
enum JobIntakeState: Equatable, Codable {
    /// A number was supplied when the job started; nothing to ask.
    case notRequired
    /// No number yet and the question has not been put.
    case needsReference
    /// The question has been asked `attempts` times and an answer is expected.
    case asked(attempts: Int)
    /// Something reference-shaped was heard and is being read back for confirmation.
    case confirming(candidate: String, attempts: Int)
    /// Recorded, exactly as given.
    case recorded(reference: String)
    /// "I don't have one." A valid answer, logged, never nagged about again.
    case declined
    /// Asked, corrected, still not right. The app stops asking; the number can be typed later.
    case outstanding

    /// How many times the app will put the question by voice before it gives up and offers typing.
    static let maximumAsks = 2

    /// Whether the job still owes a number — what the Job tab badges and the prompt context says.
    var isOutstanding: Bool {
        switch self {
        case .notRequired, .recorded, .declined: return false
        case .needsReference, .asked, .confirming, .outstanding: return true
        }
    }

    /// The recorded number, when there is one.
    var reference: String? {
        if case .recorded(let reference) = self { return reference }
        return nil
    }

    /// Whether the next utterance should be inspected as a possible answer.
    var awaitsAnswer: Bool {
        switch self {
        case .asked, .confirming: return true
        default: return false
        }
    }

    /// Whether the app has a question to speak right now.
    var hasQuestionDue: Bool {
        switch self {
        case .needsReference: return true
        case .asked(let attempts): return attempts < Self.maximumAsks
        default: return false
        }
    }
}

// MARK: - Events and outcomes

/// Everything that can move the intake along. Deliberately small: a job starting, the app asking,
/// something being heard, and the two out-of-band routes (a number typed or declined on a screen).
enum JobIntakeEvent: Equatable {
    /// A job started, with the number the caller already had (or none).
    case jobStarted(reference: String?)
    /// The app has just spoken the question.
    case questionAsked
    /// The technician said something while a question was outstanding.
    case heard(String)
    /// A number arrived by a route that needs no confirmation — typed, or passed to the tool.
    case referenceSupplied(String)
    /// "I don't have one", said through a control rather than out loud.
    case declinedExplicitly
}

/// What the app should say when an intake transition happens. Held as a case rather than a string
/// so the tests assert the decision and the wording stays in one place.
enum JobIntakePrompt: Equatable {
    case ask
    case askAgain
    case readBack(String)
    case confirmed(String)
    case acknowledgeDeclined
    case offerTyping

    /// The line the app speaks. Plain sentences — a technician with the phone in a pocket hears
    /// these, so they name the number and end in a question only when an answer is wanted.
    var spoken: String {
        switch self {
        case .ask:
            return "What's the job number for this one?"
        case .askAgain:
            return "Sorry — what's the job number?"
        case .readBack(let candidate):
            return "Job \(candidate) — right?"
        case .confirmed(let reference):
            return "Job \(reference), noted."
        case .acknowledgeDeclined:
            return "No job number, then. I've noted that on the record."
        case .offerTyping:
            return "I'll leave the job number for now — you can type it in later."
        }
    }
}

/// The result of one transition: the new state, what to say, whether the utterance was used up,
/// and what the audit log should record.
struct JobIntakeOutcome: Equatable {
    var state: JobIntakeState
    var prompt: JobIntakePrompt?
    /// True when the utterance answered the app's question and must not reach the model.
    var consumesUtterance: Bool = false
    /// Set on the transition that records a number, so the caller writes it to the session once.
    var recordedReference: String?
    var audit: Audit?

    /// What goes in the session's audit log. The question and its answer are both evidence.
    enum Audit: Equatable {
        case asked(attempt: Int)
        case candidateHeard(String)
        case recorded(String)
        case corrected(from: String)
        case declined
        case gaveUp
    }
}

// MARK: - Transitions

extension JobIntakeState {

    /// Advance the machine. Pure: the caller performs the speech, the write and the logging.
    func advance(_ event: JobIntakeEvent) -> JobIntakeOutcome {
        switch event {
        case .jobStarted(let reference):
            if let trimmed = Self.cleaned(reference) {
                return JobIntakeOutcome(state: .recorded(reference: trimmed),
                                        recordedReference: trimmed,
                                        audit: .recorded(trimmed))
            }
            return JobIntakeOutcome(state: .needsReference)

        case .questionAsked:
            switch self {
            case .needsReference:
                return JobIntakeOutcome(state: .asked(attempts: 1), audit: .asked(attempt: 1))
            case .asked(let attempts) where attempts < Self.maximumAsks:
                return JobIntakeOutcome(state: .asked(attempts: attempts + 1),
                                        audit: .asked(attempt: attempts + 1))
            default:
                // Nothing was due. Saying so again would be the nag this machine exists to avoid.
                return JobIntakeOutcome(state: self)
            }

        case .referenceSupplied(let supplied):
            guard let trimmed = Self.cleaned(supplied) else { return JobIntakeOutcome(state: self) }
            return JobIntakeOutcome(state: .recorded(reference: trimmed),
                                    prompt: .confirmed(trimmed),
                                    recordedReference: trimmed,
                                    audit: .recorded(trimmed))

        case .declinedExplicitly:
            return JobIntakeOutcome(state: .declined, audit: .declined)

        case .heard(let text):
            return heard(text)
        }
    }

    private func heard(_ text: String) -> JobIntakeOutcome {
        switch self {
        case .asked(let attempts):
            switch JobReferenceClassifier.classify(text) {
            case .reference(let candidate):
                return JobIntakeOutcome(state: .confirming(candidate: candidate, attempts: attempts),
                                        prompt: .readBack(candidate),
                                        consumesUtterance: true,
                                        audit: .candidateHeard(candidate))
            case .decline:
                return JobIntakeOutcome(state: .declined,
                                        prompt: .acknowledgeDeclined,
                                        consumesUtterance: true,
                                        audit: .declined)
            case .affirmative, .negative, .unrelated:
                // "What's this error code?" is not an answer. It goes to the model untouched and
                // the question stays outstanding — swallowing it would lose the technician's turn.
                return JobIntakeOutcome(state: self)
            }

        case .confirming(let candidate, let attempts):
            switch JobReferenceClassifier.classify(text) {
            case .affirmative:
                return JobIntakeOutcome(state: .recorded(reference: candidate),
                                        prompt: .confirmed(candidate),
                                        consumesUtterance: true,
                                        recordedReference: candidate,
                                        audit: .recorded(candidate))
            case .reference(let corrected) where corrected != candidate:
                // "No, it's 1006" — the correction and the negative arrive together.
                return JobIntakeOutcome(state: .confirming(candidate: corrected, attempts: attempts),
                                        prompt: .readBack(corrected),
                                        consumesUtterance: true,
                                        audit: .corrected(from: candidate))
            case .reference:
                // Repeating the same number is agreement.
                return JobIntakeOutcome(state: .recorded(reference: candidate),
                                        prompt: .confirmed(candidate),
                                        consumesUtterance: true,
                                        recordedReference: candidate,
                                        audit: .recorded(candidate))
            case .negative:
                // One correction loop, then the app stops asking and offers typing instead. A
                // second misheard reading is a microphone problem, not a question problem.
                if attempts < Self.maximumAsks {
                    return JobIntakeOutcome(state: .asked(attempts: attempts + 1),
                                            prompt: .askAgain,
                                            consumesUtterance: true,
                                            audit: .asked(attempt: attempts + 1))
                }
                return JobIntakeOutcome(state: .outstanding,
                                        prompt: .offerTyping,
                                        consumesUtterance: true,
                                        audit: .gaveUp)
            case .decline:
                return JobIntakeOutcome(state: .declined,
                                        prompt: .acknowledgeDeclined,
                                        consumesUtterance: true,
                                        audit: .declined)
            case .unrelated:
                return JobIntakeOutcome(state: self)
            }

        default:
            return JobIntakeOutcome(state: self)
        }
    }

    /// Trim and reject empty. The only cleaning a supplied reference gets.
    static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
