import Foundation

/// A step's hint while the technician talks a job through (Plan JI §7a, "The hints: authored,
/// never generated"). Pure.
///
/// Only what the procedure's author wrote for the step, in this order, and only what it carries:
/// 1. its safety note;
/// 2. what to expect, `expected_input`;
/// 3. the calculation: the result when its `calc_ref` resolves, else the author's own words for it
///    (`calc_ref.hint`). Nothing in the app resolves a `calc_ref` on its own today (the assistant
///    calls the calculator), so the session passes no result and the author's words stand.
///
/// The step's reason (`why`, JI P6) and its figure (Plan MI) join the list once those fields exist
/// on `Procedure.Step`; neither does yet. A step that carries none of these gets no hint at all.
/// **No model writes any of it**: there is no model anywhere in this type.
///
/// Delivered three ways from one value: the lens, two lines with the step's title dimmed above;
/// the ear, the first item in about five to seven words; the phone, the whole step.
struct TalkThroughHint: Equatable, Sendable {

    enum Item: Equatable, Sendable {
        case safety(String)
        case expect(String)
        case calculation(String)

        /// The item as the lens and the phone print it.
        var text: String {
            switch self {
            case .safety(let note): return String(localized: "Safety: \(note)", comment: "Talk-through hint: a procedure step's safety note.")
            case .expect(let reading): return String(localized: "Expect: \(reading)", comment: "Talk-through hint: the reading a procedure step expects.")
            case .calculation(let text): return String(localized: "Calculation: \(text)", comment: "Talk-through hint: a procedure step's calculation, as its author wrote it or its result.")
            }
        }

        /// The item as the ear says it, before the cut to a few words.
        var spokenText: String {
            switch self {
            case .safety(let note): return note
            case .expect(let reading): return String(localized: "Expect \(reading)", comment: "Talk-through hint said in the ear: the reading a step expects.")
            case .calculation(let text): return text
            }
        }
    }

    let stepId: String
    let stepTitle: String
    let items: [Item]

    /// The step's hint, or nil when its author wrote none of it.
    static func make(for step: Procedure.Step, calculationResult: String? = nil) -> TalkThroughHint? {
        var items: [Item] = []
        if let note = cleaned(step.safetyNote) { items.append(.safety(note)) }
        if let reading = cleaned(step.expectedInput) { items.append(.expect(reading)) }
        if let result = cleaned(calculationResult) {
            items.append(.calculation(result))
        } else if let authored = cleaned(step.calcRef?.hint) {
            items.append(.calculation(authored))
        }
        guard !items.isEmpty else { return nil }
        return TalkThroughHint(stepId: step.id, stepTitle: step.title, items: items)
    }

    /// The step's title, dimmed above the lens lines.
    var lensTitle: String { stepTitle }

    /// The lens's two lines: the items in order, cut to two lens lines at a word.
    var lensBody: String {
        let joined = items.map(\.text).joined(separator: " ")
        let (line, wasCut) = HintText.cut(joined, maxCharacters: HintLimits.passageCardMaxCharacters)
        return HintText.trimmingTrailingPunctuation(line, includingStops: wasCut) + (wasCut ? "…" : "")
    }

    /// The ear's few words: the first item, at most `HintLimits.spokenHintMaxWords` words.
    var spoken: String {
        guard let first = items.first else { return "" }
        return HintReply.cutSpoken(first.spokenText)
    }

    /// The phone's lines: every item, whole.
    var phoneLines: [String] { items.map(\.text) }

    /// The safety note, whole, for a caught phrase: said in full, at once.
    var safetyNote: String? {
        for item in items { if case .safety(let note) = item { return note } }
        return nil
    }

    private static func cleaned(_ text: String?) -> String? {
        guard let text = text.map(HintText.collapsingWhitespace), !text.isEmpty else { return nil }
        return text
    }
}

/// The author's words to catch (Plan JI §7a, "Words to catch"): a step's `caution_phrases`, found in
/// a finished sentence as whole words, case and accents ignored. **Only an author's phrase fires**:
/// nothing here, and nothing in talk-through, judges on its own that what someone says is
/// dangerous. Pure.
enum CautionPhraseMatcher {

    /// The first of `phrases` the sentence says, as written by the author; nil for none.
    static func firstMatch(in sentence: String, phrases: [String]?) -> String? {
        let heard = HintText.words(sentence)
        guard !heard.isEmpty else { return nil }
        for phrase in phrases ?? [] {
            let wanted = HintText.words(phrase)
            guard !wanted.isEmpty, wanted.count <= heard.count else { continue }
            for start in 0...(heard.count - wanted.count) where Array(heard[start..<(start + wanted.count)]) == wanted {
                return phrase
            }
        }
        return nil
    }

    /// The step a sentence's caught phrase belongs to, among the steps the technician may be on
    /// (the locator's candidates, current first), and the phrase. Only a step with a safety note to
    /// show counts: a phrase is the author's way to bring that note up.
    static func caught(in sentence: String, procedure: Procedure,
                       visited: [String]) -> (step: Procedure.Step, phrase: String)? {
        for candidate in TalkThroughLocator.candidates(procedure: procedure, visited: visited) {
            guard let step = procedure.step(id: candidate.stepId),
                  let note = step.safetyNote, !note.trimmingCharacters(in: .whitespaces).isEmpty,
                  let phrase = firstMatch(in: sentence, phrases: step.cautionPhrases) else { continue }
            return (step, phrase)
        }
        return nil
    }
}
