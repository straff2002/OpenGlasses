import Foundation

/// What one utterance means to a procedure running with no model (Plan MN §4): a step command,
/// the step's answer, a read-back's yes or no, a corrective note, or nothing this mode takes.
enum ProcedureVoiceIntent: Equatable {
    case next
    case back
    case repeatStep
    case confirmReadBack(Bool)
    /// The words to read as the step's answer, as said.
    case answer(String)
    /// The words to record as the corrective note an out-of-spec critical answer is owed.
    case note(String)
    /// Anything else: the one fixed line, never a guess.
    case fallback
}

/// Decides what an utterance means while a procedure runs with no model. Pure: the same words on
/// the same step always mean the same thing, and nothing here answers a question.
///
/// Order:
/// 1. A read-back waiting: yes or no answers it; a new number on a number step replaces it.
/// 2. Back, repeat and a plain "next" (`HUDVoiceCommand`'s words, plus "repeat").
/// 3. The step's answer, for kinds whose reading can't swallow a command — a number, a choice,
///    yes or no — so "done" on a yes/no step is its answer rather than "next"; then "done" and
///    "finished" as next.
/// 4. A corrective note owed: the words are the note.
/// 5. A text or code answer: the words, as said.
/// 6. A number step and words with a number in them that didn't read (implausible, two numbers):
///    the answer, so the runner says why and asks again.
/// 7. Otherwise the fixed line.
enum ProcedureVoiceDecider {

    /// The one line said to anything this mode doesn't take.
    static let fallbackLine = String(localized: "I can take the answer to this step, or next, back or repeat.")

    /// Said once where the locale has no on-device recognition: the phone screen is the way in.
    static let screenIsTheWayInLine = String(localized: "This phone can't recognise speech on the device in this language, so answer this procedure on the phone screen.")

    static let repeatPhrases: Set<String> = [
        "repeat", "repeat that", "repeat it", "repeat the step", "repeat step", "say again",
        "say that again", "say it again", "again", "what was that", "read it again",
    ]

    static func decide(_ utterance: String, on presentation: ProcedureStepPresentation,
                       locale: Locale = .current) -> ProcedureVoiceIntent {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .fallback }
        let answer = presentation.answer

        if presentation.pendingReadBack != nil {
            if case .accepted(let value) = AnswerReader.read(text, for: confirmation) {
                return .confirmReadBack(value.option == "yes")
            }
            if let answer, answer.kind == .number, case .number = AnswerReader.number(in: text, locale: locale) {
                return .answer(text)
            }
        }

        // "back", "repeat" and a plain "next" are always step words. "Done" and "finished" are
        // also a yes, so on a step that takes one they answer it.
        let command = command(text)
        if let command, command != .next || plainNextPhrases.contains(core(text)) { return command }

        if let answer, readsFirst(answer.kind), case .accepted = AnswerReader.read(text, for: answer, locale: locale) {
            return .answer(text)
        }

        if let command { return command }

        if presentation.needsCorrectiveNote { return .note(text) }

        guard let answer, let kind = answer.kind else { return .fallback }
        switch kind {
        case .text, .code:
            return .answer(text)
        case .number:
            if case .none = AnswerReader.number(in: text, locale: locale) { return .fallback }
            return .answer(text)
        case .choice, .yesNo, .photo:
            return .fallback
        }
    }

    /// next / back / repeat, matched strictly as whole short utterances.
    static func command(_ text: String) -> ProcedureVoiceIntent? {
        switch HUDVoiceCommand.parse(text) {
        case .complete?, .skip?: return .next
        case .back?: return .back
        case .briefing?, nil: break
        }
        let phrase = core(text)
        if repeatPhrases.contains(phrase) { return .repeatStep }
        if plainNextPhrases.contains(phrase) { return .next }
        return nil
    }

    /// "Next" in words that are never an answer.
    static let plainNextPhrases: Set<String> = ["next", "next step", "next one", "go on", "continue", "carry on"]

    /// The utterance lowercased, without punctuation, a leading filler or a trailing "please".
    static func core(_ text: String) -> String {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .split(separator: " ").map(String.init)
        let filler: Set<String> = ["ok", "okay", "hey", "please", "uh", "um", "now"]
        var core = Array(words.drop(while: { filler.contains($0) }))
        if core.last == "please" { core.removeLast() }
        return core.joined(separator: " ")
    }

    /// Kinds read before the step words: their readers take only numbers or listed words.
    private static func readsFirst(_ kind: StepAnswer.Kind?) -> Bool {
        switch kind {
        case .number?, .choice?, .yesNo?: return true
        default: return false
        }
    }

    /// A read-back is answered with the yes/no step's own words.
    private static let confirmation = StepAnswer(recordAs: "confirmation", kind: .yesNo, label: "confirmation")

    // MARK: - What is said

    /// The step as said aloud: position, title, safety, instruction and what the step asks for.
    static func stepLine(_ presentation: ProcedureStepPresentation) -> String {
        var parts: [String] = []
        let step = presentation.step
        parts.append("\(presentation.position.text). \(step.title).")
        if let safety = step.safetyNote, !safety.isEmpty {
            parts.append(String(localized: "Safety: \(safety)"))
        }
        parts.append(step.instruction)
        if let pending = presentation.pendingReadBack {
            parts.append(pending.prompt)
        } else if let recorded = presentation.recordedLine {
            parts.append(recorded + ".")
            if presentation.needsCorrectiveNote, let answer = presentation.recorded {
                parts.append(ProcedureRunner.notePrompt(answer))
            }
        } else if let answer = presentation.answer {
            parts.append(AnswerReader.prompt(for: answer))
            if let hint = presentation.specHint { parts.append(hint + ".") }
        }
        if step.terminal {
            parts.append(step.needsConfirmation
                         ? String(localized: "This is the last step. Finish it on the phone once the check has passed.")
                         : String(localized: "This is the last step. Say next to finish."))
        } else if !presentation.routeChoices.isEmpty, presentation.recorded != nil || presentation.answer == nil {
            parts.append(String(localized: "Choose the route on the phone or the lens."))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// What answering produced, as said.
    static func answerLine(_ result: ProcedureRunner.AnswerResult) -> String {
        switch result {
        case .recorded(let recorded):
            if recorded.note != nil, recorded.answer.isCritical, recorded.value.specStatus == .out {
                return String(localized: "Note added. Say next to go on.")
            }
            return String(localized: "Recorded: \(ProcedureStepPresentation.answerLine(recorded)). Say next to go on.")
        case .askAgain(let line), .readBack(let line), .needsNote(let line):
            return line
        case .notAccepted:
            return fallbackLine
        }
    }

    /// A refusal from the runner, as said. The runner's own lines speak to the assistant on a few
    /// cases; these speak to the person.
    static func refusalLine(_ error: Error, on presentation: ProcedureStepPresentation?) -> String {
        guard let runnerError = error as? ProcedureRunner.RunnerError else {
            return String(localized: "That didn't work. Use the phone screen for this step.")
        }
        switch runnerError {
        case .atStart:
            return String(localized: "This is the first step.")
        case .noNextStep:
            return String(localized: "Choose the route on the phone or the lens.")
        case .awaitingConfirmation:
            return String(localized: "This is the last step. Finish it on the phone once the check has passed.")
        case .noRuleMatched:
            let reason = presentation?.noRuleMatchedReason.map { $0 + ". " } ?? ""
            return reason + String(localized: "Choose the route on the phone or the lens.")
        case .answerRequired, .awaitingReadBack, .correctiveNoteRequired, .ruleDecides:
            return runnerError.errorDescription ?? fallbackLine
        case .emptyProcedure, .unknownStep, .overrideNeedsReason, .notRuleDecided, .unknownBranch:
            return String(localized: "That didn't work. Use the phone screen for this step.")
        }
    }
}

/// The slice of `FieldSessionService` the no-model voice and the lens drive a procedure through.
@MainActor
protocol ProcedureAnswering: AnyObject {
    var activeProcedurePresentation: ProcedureStepPresentation? { get }
    @discardableResult func advanceProcedure(choice: String?) throws -> ProcedureRunner.Transition
    @discardableResult func procedureBack() throws -> Procedure.Step
    func answerProcedure(value: String?, method: ProcedureAnswerMethod, note: String?,
                         confirmed: Bool, locale: Locale) throws -> ProcedureRunner.AnswerResult
    func confirmProcedureReadBack(_ correct: Bool) throws -> ProcedureRunner.AnswerResult
}

extension FieldSessionService: ProcedureAnswering {}

extension ProcedureAnswering {
    /// The person's "next": a photo step with no answer yet takes the photos taken on it first,
    /// then the procedure goes on as the rules or the step say.
    @discardableResult
    func advanceProcedureAttachingPhotos() throws -> ProcedureRunner.Transition {
        if let presentation = activeProcedurePresentation, presentation.awaitsAnswer,
           presentation.answer?.kind == .photo {
            let result = try answerProcedure(value: nil, method: .photo, note: nil, confirmed: false, locale: .current)
            if case .askAgain(let line) = result { throw ProcedureAnswerRefusal(line: line) }
        }
        return try advanceProcedure(choice: nil)
    }
}

/// A photo step asked to go on with too few photos: the reader's line, for the screen and voice.
struct ProcedureAnswerRefusal: LocalizedError, Equatable {
    let line: String
    var errorDescription: String? { line }
}

/// Plan MN §4: the voice loop for a procedure running with no model. The decisions are
/// `ProcedureVoiceDecider`'s; this carries one out on the session and returns the line to say,
/// which the app speaks with the on-device voice. It opens no microphone: utterances arrive from
/// the app's existing wake-word and transcription path.
@MainActor
final class ProcedureVoiceLoop {
    private let host: ProcedureAnswering
    private let supportsOnDeviceRecognition: () -> Bool
    /// The procedure the screen notice was said for, so it is said once a run.
    private var screenNoticeSaidFor: String?

    init(host: ProcedureAnswering, supportsOnDeviceRecognition: @escaping () -> Bool) {
        self.host = host
        self.supportsOnDeviceRecognition = supportsOnDeviceRecognition
    }

    /// Handle one utterance. Nil when no procedure is running, so the words go on as before.
    func handle(_ utterance: String, locale: Locale = .current) -> String? {
        guard let presentation = host.activeProcedurePresentation else { return nil }
        let line = carryOut(ProcedureVoiceDecider.decide(utterance, on: presentation, locale: locale),
                            on: presentation, locale: locale)
        guard !supportsOnDeviceRecognition(), screenNoticeSaidFor != presentation.procedureId else { return line }
        screenNoticeSaidFor = presentation.procedureId
        return ProcedureVoiceDecider.screenIsTheWayInLine + " " + line
    }

    /// The current step, as said — for "read it aloud" on the screen and after a move.
    func stepLine() -> String? {
        host.activeProcedurePresentation.map(ProcedureVoiceDecider.stepLine)
    }

    private func carryOut(_ intent: ProcedureVoiceIntent, on presentation: ProcedureStepPresentation,
                          locale: Locale) -> String {
        do {
            switch intent {
            case .fallback:
                return ProcedureVoiceDecider.fallbackLine
            case .repeatStep:
                return ProcedureVoiceDecider.stepLine(presentation)
            case .back:
                try host.procedureBack()
                return stepLine() ?? ProcedureVoiceDecider.fallbackLine
            case .next:
                switch try host.advanceProcedureAttachingPhotos() {
                case .completed:
                    return String(localized: "The procedure is finished.")
                case .moved, .arrivedAtTerminal:
                    return stepLine() ?? String(localized: "The procedure is finished.")
                }
            case .confirmReadBack(let correct):
                return ProcedureVoiceDecider.answerLine(try host.confirmProcedureReadBack(correct))
            case .answer(let words):
                return ProcedureVoiceDecider.answerLine(
                    try host.answerProcedure(value: words, method: .spoken, note: nil, confirmed: false, locale: locale))
            case .note(let words):
                return ProcedureVoiceDecider.answerLine(
                    try host.answerProcedure(value: nil, method: .spoken, note: words, confirmed: false, locale: locale))
            }
        } catch let refusal as ProcedureAnswerRefusal {
            return refusal.line
        } catch {
            return ProcedureVoiceDecider.refusalLine(error, on: host.activeProcedurePresentation ?? presentation)
        }
    }
}

/// Whether a procedure is running with no model, for the transcription service: its turns are
/// recognised on the phone where the locale can, and never by a cloud dictation vendor (Plan MN §4).
/// Set by the app; false everywhere else.
@MainActor
enum ProcedureVoiceGate {
    static var listensOnDevice: () -> Bool = { false }
}
