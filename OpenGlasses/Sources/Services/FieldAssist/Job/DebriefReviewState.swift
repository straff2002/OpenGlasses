import Foundation

/// What the app says while a debrief is being captured, read back and settled (Plan FO P3b).
///
/// The wording lives here rather than inside the machine for the same reason `JobIntakePrompt`
/// does: a technician hears these with the phone in a pocket, and one copy of a sentence is one
/// thing to keep in step.
enum DebriefPrompt: Equatable {
    /// A debrief has begun on a named job.
    case started(job: String)
    /// The technician switched to another job mid-drive.
    case switched(job: String)
    /// "Let me put that together." — said before the model is asked, because the pause is long
    /// enough that silence reads as the app having stopped listening.
    case summarising
    /// The question that ends every read-back.
    case decision
    /// What was saved, and onto which job.
    case saved(job: String)
    case discarded
    /// Which item is being changed.
    case editing(String)
    /// The model call failed or its answer was refused.
    case failed(String)
    /// The technician kept the raw account instead.
    case keptRaw(job: String)

    var spoken: String {
        switch self {
        case .started(let job):
            return "\(job). Go ahead — I'm listening, and I'll write it up at the end."
        case .switched(let job):
            return "\(job). Go ahead."
        case .summarising:
            return "Let me put that together."
        case .decision:
            return "Save that to the job, change something, or scrap it?"
        case .saved(let job):
            return "Saved to \(job)."
        case .discarded:
            return "Scrapped — nothing went on the record."
        case .editing(let item):
            return "\(item) — what should it say?"
        case .failed(let reason):
            return reason
        case .keptRaw(let job):
            return "Kept on \(job) as you said it, not summarised."
        }
    }
}

/// The debrief's read-back and save, as a pure machine (Plan FO P3b — the shape `JobIntakeState`
/// already proved).
///
/// **Only a spoken or tapped save writes anything.** Every other path — a scrap, a back-out, an
/// app that was closed mid-drive — leaves the turns in the job's conversation marked unsaved and
/// nothing at all on the record. That asymmetry is the whole design: an account of a visit that
/// appeared on a customer's work order because a technician stopped talking is worse than one that
/// has to be confirmed.
///
/// An utterance the machine does not recognise **passes through**: it is more of the debrief, or a
/// question about something else, and swallowing it would lose the technician's turn.
enum DebriefReviewState: Equatable {
    /// Taking the account. Everything said is a debrief turn.
    case listening
    /// The model has been asked for the summary.
    case summarising
    /// The summary is being read back.
    case readBack(DebriefSummary)
    /// Read back, and waiting on save / change / scrap.
    case awaitingDecision(DebriefSummary)
    /// One item is being re-said.
    case editing(category: DebriefSummary.Category, index: Int, summary: DebriefSummary)
    /// The model call failed; retry or keep the raw account.
    case failed(reason: String)
    /// Settled. Both are terminal, and only the first writes.
    case saved
    case discarded

    var isSettled: Bool { self == .saved || self == .discarded }

    /// Whether the debrief is still collecting what the technician says.
    var isListening: Bool { self == .listening }

    /// The summary as it stands, wherever one exists.
    var summary: DebriefSummary? {
        switch self {
        case .readBack(let summary), .awaitingDecision(let summary): return summary
        case .editing(_, _, let summary): return summary
        case .listening, .summarising, .failed, .saved, .discarded: return nil
        }
    }
}

/// Everything that can move a debrief along.
enum DebriefReviewEvent: Equatable {
    /// The technician said they were done, or the app was told to wrap up.
    case finishRequested
    /// The model answered, and the decoder accepted it.
    case summaryReturned(DebriefSummary)
    /// …or it did not.
    case summaryFailed(String)
    /// The read-back has been spoken.
    case readBackSpoken
    /// Something was said while a decision was outstanding.
    case heard(String)
    /// The technician tapped Save / Scrap / Retry / Keep as said on the phone.
    case saveRequested
    case discardRequested
    case retryRequested
    case keepRawRequested
}

/// What the caller does about a transition. The machine performs nothing itself.
enum DebriefReviewAction: Equatable {
    case none
    /// Ask the model for the summary.
    case requestSummary
    /// Speak the read-back.
    case speakReadBack
    /// Write the summary onto the job's record.
    case save
    /// Write the turns onto the job's record, unsummarised and labelled.
    case saveRaw
    /// Write nothing.
    case discard
}

struct DebriefReviewOutcome: Equatable {
    var state: DebriefReviewState
    var prompt: DebriefPrompt?
    /// Whether the utterance answered the app and must not reach the model as an ordinary turn.
    var consumesUtterance: Bool = false
    /// Whether the utterance is another line of the debrief and should be recorded as a turn.
    var recordsTurn: Bool = false
    var action: DebriefReviewAction = .none
}

extension DebriefReviewState {

    /// Words that end the account. Kept narrow on purpose: "that's it for that one" ends a
    /// debrief, "that's the compressor" does not.
    static let finishPhrases = ["that's it", "thats it", "that's all", "thats all", "i'm done",
                                "im done", "that's me done", "all done", "wrap it up",
                                "write it up", "summarise that", "summarize that",
                                "that's the lot", "thats the lot"]
    static let savePhrases = ["save", "save it", "save that", "yes save", "put it on the job",
                              "save to the job", "keep it"]
    static let discardPhrases = ["scrap it", "scrap that", "bin it", "throw it away", "forget it",
                                 "don't save", "dont save", "no don't save", "delete that"]
    static let retryPhrases = ["try again", "have another go", "do it again", "retry"]
    static let keepRawPhrases = ["keep what i said", "keep it as i said", "keep it raw",
                                 "just keep it", "keep the recording", "save it as i said"]

    /// Advance. Pure: the caller speaks, records the turn, calls the model and writes the record.
    func advance(_ event: DebriefReviewEvent) -> DebriefReviewOutcome {
        switch event {
        case .finishRequested:
            guard self == .listening else { return DebriefReviewOutcome(state: self) }
            return DebriefReviewOutcome(state: .summarising, prompt: .summarising,
                                        consumesUtterance: true, action: .requestSummary)

        case .summaryReturned(let summary):
            guard self == .summarising else { return DebriefReviewOutcome(state: self) }
            return DebriefReviewOutcome(state: .readBack(summary), action: .speakReadBack)

        case .summaryFailed(let reason):
            guard self == .summarising else { return DebriefReviewOutcome(state: self) }
            return DebriefReviewOutcome(state: .failed(reason: reason), prompt: .failed(reason))

        case .readBackSpoken:
            guard case .readBack(let summary) = self else { return DebriefReviewOutcome(state: self) }
            return DebriefReviewOutcome(state: .awaitingDecision(summary))

        case .saveRequested:
            // Nothing summarised is nothing to save: a save cannot be what produces a record.
            guard summary != nil else { return DebriefReviewOutcome(state: self) }
            return DebriefReviewOutcome(state: .saved, consumesUtterance: true, action: .save)

        case .discardRequested:
            guard !isSettled else { return DebriefReviewOutcome(state: self) }
            return DebriefReviewOutcome(state: .discarded, prompt: .discarded,
                                        consumesUtterance: true, action: .discard)

        case .retryRequested:
            guard case .failed = self else { return DebriefReviewOutcome(state: self) }
            return DebriefReviewOutcome(state: .summarising, prompt: .summarising,
                                        consumesUtterance: true, action: .requestSummary)

        case .keepRawRequested:
            guard case .failed = self else { return DebriefReviewOutcome(state: self) }
            return DebriefReviewOutcome(state: .saved, consumesUtterance: true, action: .saveRaw)

        case .heard(let text):
            return heard(text)
        }
    }

    private func heard(_ text: String) -> DebriefReviewOutcome {
        let normalised = Self.normalise(text)
        switch self {
        case .listening:
            if Self.matches(normalised, Self.finishPhrases) { return advance(.finishRequested) }
            // Everything else is the account. It is recorded as a turn and it reaches the model as
            // an ordinary turn too, because the model is the one holding the conversation.
            return DebriefReviewOutcome(state: self, recordsTurn: true)

        case .readBack, .awaitingDecision:
            if Self.matches(normalised, Self.savePhrases) { return advance(.saveRequested) }
            if Self.matches(normalised, Self.discardPhrases) { return advance(.discardRequested) }
            if let target = editTarget(in: normalised) {
                return DebriefReviewOutcome(state: .editing(category: target.category,
                                                            index: target.index,
                                                            summary: target.summary),
                                            prompt: .editing(target.item.text),
                                            consumesUtterance: true)
            }
            // Not an answer. It passes through untouched, and the decision stays outstanding.
            return DebriefReviewOutcome(state: self)

        case .editing(let category, let index, let summary):
            if Self.matches(normalised, Self.discardPhrases) { return advance(.discardRequested) }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return DebriefReviewOutcome(state: self) }
            // The replacement keeps the item's citations: it is the same report, said again. An
            // edit is not a new claim with no source.
            guard let existing = summary.items(category).indices.contains(index)
                    ? summary.items(category)[index] : nil else {
                return DebriefReviewOutcome(state: .awaitingDecision(summary))
            }
            let replaced = summary.replacing(
                category: category, at: index,
                with: DebriefSummary.Item(text: String(trimmed.prefix(DebriefSummary.maximumItemCharacters)),
                                          sourceTurnIds: existing.sourceTurnIds,
                                          flag: DebriefSummaryDecoder.readsAsCompletedWork(trimmed)
                                                && (category == .findings || category == .partsOrMaterials)
                                                ? .reportedNotVerified : nil))
            return DebriefReviewOutcome(state: .readBack(replaced), consumesUtterance: true,
                                        action: .speakReadBack)

        case .failed:
            if Self.matches(normalised, Self.retryPhrases) { return advance(.retryRequested) }
            if Self.matches(normalised, Self.keepRawPhrases) { return advance(.keepRawRequested) }
            if Self.matches(normalised, Self.discardPhrases) { return advance(.discardRequested) }
            return DebriefReviewOutcome(state: self)

        case .summarising, .saved, .discarded:
            return DebriefReviewOutcome(state: self)
        }
    }

    /// "change the drier one", "change what was found". Returns the item being edited, or nil.
    private func editTarget(in normalised: String)
        -> (category: DebriefSummary.Category, index: Int, item: DebriefSummary.Item,
            summary: DebriefSummary)? {
        guard let summary, normalised.hasPrefix("change") || normalised.hasPrefix("fix")
                || normalised.hasPrefix("correct") else { return nil }
        let remainder = normalised
            .replacingOccurrences(of: "change", with: "")
            .replacingOccurrences(of: "correct", with: "")
            .replacingOccurrences(of: "fix", with: "")
            .replacingOccurrences(of: "the", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let words = remainder.split(separator: " ").map(String.init).filter { $0.count > 2 }
        for category in DebriefSummary.Category.allCases {
            for (index, item) in summary.items(category).enumerated() {
                let haystack = Self.normalise(item.text)
                if words.contains(where: { haystack.contains($0) }) {
                    return (category, index, item, summary)
                }
            }
        }
        // "change that" with nothing to go on takes the last item read out, which is the one the
        // technician just heard.
        guard let last = summary.allItems.last else { return nil }
        let index = summary.items(last.category).count - 1
        return (last.category, index, last.item, summary)
    }

    static func normalise(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(.whitespaces))
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ normalised: String, _ phrases: [String]) -> Bool {
        phrases.contains { normalised == $0 || normalised.hasPrefix($0 + " ")
            || normalised.hasSuffix(" " + $0) || normalised.contains(" " + $0 + " ") }
    }
}
