import Foundation

/// How the check-in was reached: at its time, or asked for ("what's waiting on me?").
enum OpenLoopChannel: Equatable, Sendable {
    case scheduled
    case asked
}

/// The check-in as speech.
struct OpenLoopPhrase: Equatable, Sendable {
    let text: String
    /// How many loops the text names; the rest are on the phone.
    let spokenCount: Int
    /// The text ends by asking "Want to deal with the first one now?" — the first loop is an
    /// approval, and a yes runs that loop's own confirmation (§6). Nothing is approved by the
    /// check-in itself.
    let offersFirst: Bool
}

/// Plan LE §6 and §10 — the check-in in words. Templates only (decision 8), in the style of
/// `ActivityPhraser` and `GoalPhraser`; pure.
///
/// - The count comes first and is exact, whatever is spoken after it.
/// - At most four loops are named (decision 6), fewer when `MyDaySpeechPolicy`'s ceiling needs it;
///   then "The rest are on your phone."
/// - Empty: the scheduled check-in says nothing (decision 4); asked for, "Nothing is waiting on you."
/// - "before you finish" with Field Assist on, "still waiting on you" otherwise.
/// - After the list, one question, only when the first loop is an approval.
enum OpenLoopPhraser {
    static let maximumSpoken = 4

    static func phrase(_ collection: OpenLoopCollection, channel: OpenLoopChannel,
                       fieldAssist: Bool) -> OpenLoopPhrase? {
        let loops = collection.loops
        guard !loops.isEmpty else {
            guard channel == .asked else { return nil }
            let text = collection.unavailable.isEmpty
                ? String(localized: "Nothing is waiting on you.",
                         comment: "Spoken: the evening check-in, asked for, found nothing waiting on the wearer.")
                : String(localized: "I couldn't check everything, and nothing I could check is waiting on you.",
                         comment: "Spoken: the evening check-in found nothing, but some of its sources could not be read.")
            return OpenLoopPhrase(text: text, spokenCount: 0, offersFirst: false)
        }

        let opening = opening(count: loops.count, fieldAssist: fieldAssist)
        let offersFirst = loops[0].source == .approval
        let offer = String(localized: "Want to deal with the first one now?",
                           comment: "Spoken: after the evening check-in's list, when the first item is an approval.")
        let rest = String(localized: "The rest are on your phone.",
                          comment: "Spoken: the evening check-in named some of its items; the others are on the phone.")

        var shown = min(maximumSpoken, loops.count)
        while true {
            let clauses = loops.prefix(shown).map(clause)
            var sentences = [opening + " " + SpokenPhrasing.joined(clauses) + "."]
            if shown < loops.count { sentences.append(rest) }
            if offersFirst { sentences.append(offer) }
            let text = sentences.joined(separator: " ")
            if MyDaySpeechPolicy.estimatedDuration(for: text) <= MyDaySpeechPolicy.maximumDuration {
                return OpenLoopPhrase(text: text, spokenCount: shown, offersFirst: offersFirst)
            }
            if shown == 1 {
                return OpenLoopPhrase(text: MyDaySpeechPolicy.bounded(text), spokenCount: shown,
                                      offersFirst: offersFirst)
            }
            shown -= 1
        }
    }

    /// "Three things are still waiting on you:" / "Two things before you finish:".
    static func opening(count: Int, fieldAssist: Bool) -> String {
        let number = SpokenPhrasing.capitalisedFirst(SpokenPhrasing.number(count))
        switch (fieldAssist, count == 1) {
        case (false, true):
            return String(localized: "\(number) thing is still waiting on you:",
                          comment: "Spoken: the evening check-in's opening for one item; the number is a word, e.g. One.")
        case (false, false):
            return String(localized: "\(number) things are still waiting on you:",
                          comment: "Spoken: the evening check-in's opening; the number is a word, e.g. Three.")
        case (true, true):
            return String(localized: "\(number) thing before you finish:",
                          comment: "Spoken: the end-of-shift check-in's opening for one item; the number is a word.")
        case (true, false):
            return String(localized: "\(number) things before you finish:",
                          comment: "Spoken: the end-of-shift check-in's opening; the number is a word, e.g. Two.")
        }
    }

    /// One loop as a clause inside the list.
    static func clause(_ loop: OpenLoop) -> String {
        let title = loop.title
        let lowered = SpokenPhrasing.listCased(title)
        switch loop.source {
        case .approval:
            return lowered
        case .reminder:
            return String(localized: "the '\(title)' reminder",
                          comment: "Spoken list item: an open reminder, by its text.")
        case .goalStep:
            if let goal = loop.subject {
                return String(localized: "the next step of '\(goal)'",
                              comment: "Spoken list item: a goal's next step, by the goal's title.")
            }
            return String(localized: "the step '\(title)'", comment: "Spoken list item: a goal step, by its title.")
        case .digest:
            return String(localized: "the '\(title)' update", comment: "Spoken list item: an update not yet heard.")
        case .agentResult:
            return String(localized: "the result of '\(title)'",
                          comment: "Spoken list item: a result the assistant has not delivered yet.")
        case .draft:
            if let person = loop.subject {
                return String(localized: "the message to \(person) you haven't sent",
                              comment: "Spoken list item: a prepared draft, by its recipient.")
            }
            return String(localized: "the '\(title)' draft you haven't sent",
                          comment: "Spoken list item: a prepared draft not yet sent.")
        case .waitingOnOthers:
            return String(localized: "no reply yet from \(loop.subject ?? title)",
                          comment: "Spoken list item: someone has not replied for days.")
        case .watcherFinding:
            return String(localized: "what '\(title)' found", comment: "Spoken list item: a watcher's finding not yet heard.")
        case .askAgain:
            return String(localized: "the '\(title)' reminder you haven't confirmed",
                          comment: "Spoken list item: a keep-asking reminder still not confirmed.")
        case .jobReport:
            let job = jobNoun(loop.job)
            return loop.failed
                ? String(localized: "the report for \(job) didn't send",
                         comment: "Spoken list item: a job report whose send failed; the job is e.g. the Smith job.")
                : String(localized: "the report for \(job) isn't sent",
                         comment: "Spoken list item: a job report not yet sent; the job is e.g. the Smith job.")
        case .jobCloseHeld:
            let job = jobNoun(loop.job)
            return title.isEmpty
                ? String(localized: "\(job) isn't closed",
                         comment: "Spoken list item: a job whose close is held; the job is e.g. the Smith job.")
                : String(localized: "\(job) still needs \(lowered)",
                         comment: "Spoken list item: what a held job close waits on, e.g. the Smith job still needs the customer's sign-off.")
        case .partsRequest:
            let job = jobBare(loop.job)
            return String(localized: "the \(lowered) for \(job) is still not ordered",
                          comment: "Spoken list item: a part asked for and not sent, e.g. the filter for Jones.")
        case .deferredTask:
            let job = jobNoun(loop.job)
            return String(localized: "you put off \(lowered) on \(job)",
                          comment: "Spoken list item: a job task the technician deferred.")
        case .expertOrEscalation:
            let job = jobNoun(loop.job)
            if let expert = loop.subject {
                return String(localized: "no answer yet from \(expert) on \(job)",
                              comment: "Spoken list item: an expert hand-off still unanswered.")
            }
            return String(localized: "the escalation on \(job) has no answer yet",
                          comment: "Spoken list item: an escalation still unanswered.")
        }
    }

    /// "the Smith job", "job 1005", or "one of today's jobs".
    static func jobNoun(_ job: OpenLoopJobName?) -> String {
        switch job {
        case .customer(let name):
            return String(localized: "the \(name) job", comment: "Spoken: a job named by its customer, e.g. the Smith job.")
        case .reference(let reference):
            return String(localized: "job \(reference)", comment: "Spoken: a job named by its number, e.g. job 1005.")
        case nil:
            return String(localized: "one of today's jobs", comment: "Spoken: a job the record gives no name.")
        }
    }

    /// "Jones", "job 1005", or "one of today's jobs" — after "for".
    static func jobBare(_ job: OpenLoopJobName?) -> String {
        if case .customer(let name) = job { return name }
        return jobNoun(job)
    }
}
