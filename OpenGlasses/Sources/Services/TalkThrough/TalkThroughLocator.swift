import Foundation

/// What one finished sentence of narration means for where the technician is (Plan JI §7a, P6b).
enum TalkThroughDecision: Equatable, Sendable {
    /// Hold the position, and why.
    case stay(TalkThroughStayReason)
    /// "Sounds like you're on …?": the step two finished sentences in a row pointed at. `path` is
    /// the steps from the current one to it, the target last (one hop, or two when the narration
    /// skipped a step that asks for nothing). Nothing moves until the technician says yes.
    case propose(stepId: String, path: [String])
    /// The narration points past `openStepId`, a step that asks for a confirmation or a reading and
    /// was never done: the deviation phrase is offered. It never blocks and never moves the runner.
    case offOrder(stepId: String, openStepId: String)
}

/// Why the locator held the position. For the log only, never recorded with the job.
enum TalkThroughStayReason: String, Equatable, Sendable {
    /// An interim caption: the recogniser may still revise it.
    case notFinal
    /// Too few words of substance to say anything about the work ("okay, right").
    case nothingToGoOn
    /// Talk about something else: no candidate step fits.
    case offTopic
    /// Two steps fit about equally well.
    case ambiguous
    /// The narration fits the step the runner is on.
    case onCurrentStep
    /// The narration fits the step just finished: backward jumps are resisted.
    case onPreviousStep
    /// One sentence points at a later step; a second in a row must agree.
    case waitingForAgreement
    /// The step was already proposed and declined, or already offered as off order, on this step.
    case alreadyAsked
    /// No procedure step to work from.
    case noProcedure
}

/// A step the narration may point at: never the whole procedure, so a word that recurs across
/// steps cannot jump the technician forward.
struct TalkThroughCandidate: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case previous
        case current
        /// One or two hops along `default_next` and the branches.
        case ahead
    }

    let stepId: String
    let role: Role
    /// For a step ahead: the steps from the current one to it, the target last.
    let path: [String]
}

/// Where the technician is, from the finished sentences of their narration (Plan JI §7a). Pure.
///
/// The rules, `ScriptAligner`'s pattern for a step rather than a script:
/// - **finished sentences only**: an interim caption never moves anything;
/// - **candidates**: the previous step, the current one, and the next two along `default_next`
///   and the branches (`candidates(procedure:visited:)`);
/// - **score**: overlap of the sentence's words with the step's own (its title counts double;
///   the instruction, `expected_input` and the names in `calc_ref` once each), plus sentence
///   similarity when an embedder is there (`similarity` returns nil without one, and overlap alone
///   still works);
/// - **agreement**: a later step is proposed only after two finished sentences in a row point at
///   it. Silence, talk about something else, and talk about the current or previous step hold;
/// - **out of order**: a later step reached past a skipped step that asks for a confirmation, a
///   reading or a required answer is `.offOrder`, never `.propose`;
/// - **asked once**: a step declined, or offered as off order, is not asked again until the runner
///   is on another step.
///
/// It decides; it never moves the runner. Moving is the session's, on a yes.
struct TalkThroughLocator: Equatable, Sendable {

    /// A step's score must reach this: one title word, or two words of its instruction.
    static let minimumScore = 2.0
    /// The best step must beat the next best by this much.
    static let minimumMargin = 0.75
    /// Sentence similarity below this adds nothing; above it, up to `similarityWeight`.
    static let similarityFloor = 0.45
    static let similarityWeight = 2.0
    /// A sentence needs this many words of substance to point anywhere.
    static let minimumWords = 1

    private(set) var streakStepId: String?
    private(set) var streakCount = 0
    /// The step the runner was on at the last sentence: a move clears what was asked.
    private(set) var onStepId: String?
    private(set) var declined: Set<String> = []
    private(set) var offeredOffOrder: Set<String> = []

    init() {}

    /// The technician said no to a proposal: it is not asked again on this step.
    mutating func noteDeclined(_ stepId: String) {
        declined.insert(stepId)
        clearStreak()
    }

    /// Forget the streak (the runner moved, or the session restarted).
    mutating func clearStreak() {
        streakStepId = nil
        streakCount = 0
    }

    /// Read one caption. `similarity(sentence, stepText)` is in 0…1, or nil with no embedder.
    mutating func read(_ caption: HintCaption, procedure: Procedure?, visited: [String],
                       similarity: (String, String) -> Double? = { _, _ in nil }) -> TalkThroughDecision {
        guard caption.isFinal else { return .stay(.notFinal) }
        guard let procedure, let current = Self.currentStepId(procedure: procedure, visited: visited) else {
            return .stay(.noProcedure)
        }
        if onStepId != current {
            onStepId = current
            declined = []
            offeredOffOrder = []
            clearStreak()
        }
        let words = Self.stems(caption.text)
        guard words.count >= Self.minimumWords else { return .stay(.nothingToGoOn) }

        let candidates = Self.candidates(procedure: procedure, visited: visited)
        var scored: [(candidate: TalkThroughCandidate, score: Double)] = []
        for candidate in candidates {
            guard let step = procedure.step(id: candidate.stepId) else { continue }
            scored.append((candidate, Self.score(caption.text, words: words, step: step, similarity: similarity)))
        }
        scored.sort { $0.score > $1.score }
        guard let best = scored.first, best.score >= Self.minimumScore - 0.000_001 else {
            clearStreak()
            return .stay(.offTopic)
        }
        if scored.count > 1, best.score - scored[1].score < Self.minimumMargin - 0.000_001 {
            clearStreak()
            return .stay(.ambiguous)
        }
        switch best.candidate.role {
        case .current:
            clearStreak()
            return .stay(.onCurrentStep)
        case .previous:
            clearStreak()
            return .stay(.onPreviousStep)
        case .ahead:
            break
        }
        let target = best.candidate.stepId
        if declined.contains(target) || offeredOffOrder.contains(target) {
            clearStreak()
            return .stay(.alreadyAsked)
        }
        if streakStepId == target {
            streakCount += 1
        } else {
            streakStepId = target
            streakCount = 1
        }
        guard streakCount >= 2 else { return .stay(.waitingForAgreement) }
        clearStreak()

        let path = best.candidate.path
        if path.count > 1, let skipped = path.dropLast().first(where: { id in
            procedure.step(id: id).map(Self.asksForSomething) ?? false
        }) {
            offeredOffOrder.insert(target)
            return .offOrder(stepId: target, openStepId: skipped)
        }
        return .propose(stepId: target, path: path)
    }

    // MARK: - Candidates

    /// The step the runner is on: the last visited, or the entry before the first move.
    static func currentStepId(procedure: Procedure, visited: [String]) -> String? {
        let id = visited.last ?? procedure.entry?.id
        guard let id, procedure.step(id: id) != nil else { return nil }
        return id
    }

    /// The current step, the next two along `default_next` and the branches, and the previous one.
    /// A step reachable both ways keeps its nearest role: current, then one hop, then two, then
    /// previous, so a retest loop's way back counts as the procedure's own route forward.
    static func candidates(procedure: Procedure, visited: [String]) -> [TalkThroughCandidate] {
        guard let current = currentStepId(procedure: procedure, visited: visited) else { return [] }
        var result = [TalkThroughCandidate(stepId: current, role: .current, path: [])]
        var seen: Set<String> = [current]
        let firstHop = successors(of: current, in: procedure)
        for next in firstHop where seen.insert(next).inserted {
            result.append(TalkThroughCandidate(stepId: next, role: .ahead, path: [next]))
        }
        for next in firstHop {
            for after in successors(of: next, in: procedure) where seen.insert(after).inserted {
                result.append(TalkThroughCandidate(stepId: after, role: .ahead, path: [next, after]))
            }
        }
        if visited.count > 1 {
            let previous = visited[visited.count - 2]
            if seen.insert(previous).inserted, procedure.step(id: previous) != nil {
                result.append(TalkThroughCandidate(stepId: previous, role: .previous, path: []))
            }
        }
        return result
    }

    /// The steps one hop from `stepId`: its `default_next`, then its branches' targets, in order.
    static func successors(of stepId: String, in procedure: Procedure) -> [String] {
        guard let step = procedure.step(id: stepId), !step.terminal else { return [] }
        var ids: [String] = []
        if let next = step.defaultNext { ids.append(next) }
        ids += step.branches.map(\.next)
        var seen: Set<String> = []
        return ids.filter { procedure.step(id: $0) != nil && seen.insert($0).inserted }
    }

    /// A step that is not done until something is given: a confirmation, a reading in words, or a
    /// required typed answer. Skipping one is out of order.
    static func asksForSomething(_ step: Procedure.Step) -> Bool {
        if step.requiresConfirmation == true { return true }
        if let expected = step.expectedInput, !expected.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if let answer = step.answer, answer.isRequired { return true }
        return false
    }

    // MARK: - Score

    /// Words that say nothing about which step: fillers of running speech, on top of the hint
    /// core's stop words.
    static let narrationFillers: Set<String> = [
        "now", "right", "alright", "yeah", "yes", "no", "not", "then", "going", "gonna", "go", "get",
        "got", "getting", "doing", "done", "do", "put", "putting", "let", "lets", "check", "checking",
        "step", "next", "here", "one", "bit", "little", "make", "sure", "think", "see", "look",
        "looking", "want", "need", "should", "thing", "things", "back", "again", "first",
    ]

    /// The sentence's words of substance, folded and stemmed.
    static func stems(_ text: String) -> Set<String> {
        Set(HintText.words(text)
            .filter { $0.count > 1 && !HintText.stopWords.contains($0) && !narrationFillers.contains($0) }
            .map(stem))
    }

    /// A word without the endings running speech adds: "isolating" and "isolate" meet at "isolat",
    /// "gauges" and "gauge" at "gaug". Kept at four letters at least.
    static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s", "e"] where word.hasSuffix(suffix) && word.count - suffix.count >= 4 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    /// The step's own words: its title, and the rest it carries (instruction, the reading to
    /// expect, the names in its calculation).
    static func stepWords(_ step: Procedure.Step) -> (title: Set<String>, body: Set<String>) {
        var body = [step.instruction, step.expectedInput ?? ""]
        if let calc = step.calcRef {
            body.append(calc.op.replacingOccurrences(of: "_", with: " "))
            body.append(calc.hint ?? "")
        }
        return (stems(step.title), stems(body.joined(separator: " ")))
    }

    /// The step's text for sentence similarity.
    static func similarityText(_ step: Procedure.Step) -> String {
        [step.title, step.instruction, step.expectedInput ?? ""].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    static func score(_ sentence: String, words: Set<String>, step: Procedure.Step,
                      similarity: (String, String) -> Double?) -> Double {
        let own = stepWords(step)
        var score = 0.0
        for word in words {
            if own.title.contains(word) { score += 2 } else if own.body.contains(word) { score += 1 }
        }
        if let similar = similarity(sentence, similarityText(step)), similar > similarityFloor {
            score += similarityWeight * min(1, (similar - similarityFloor) / (1 - similarityFloor))
        }
        return score
    }
}
