import Foundation

/// Choosing the evidence without touching the phone (Plan FO P2a).
///
/// The review step arrives at exactly the moment a technician's hands are least free: gloves on,
/// standing in front of a machine they are about to walk away from. So the same three decisions the
/// grid offers — everything, nothing, or one at a time — can be spoken, and the read-out is driven
/// by app state rather than by a model that may or may not remember what it was asking about.
///
/// The same pattern as `JobIntakeState`, and for the same reason: a pure machine that the app
/// drives is a machine a test can drive, and a guided step that depends on model goodwill is not
/// guidance. **Anything that is not one of these answers passes straight through** — a technician
/// who says "actually, what was that part number?" in the middle of the review is asking a
/// question, not answering one, and the review is still there afterwards.
enum EvidenceReviewCommand: Equatable {
    /// "Include all", "send them all", "all of them".
    case includeAll
    /// "Skip photos", "no photos", "just the text".
    case skip
    /// "Yes", "keep it", "include it" — about the item being read out.
    case include
    /// "No", "leave it out", "skip that one".
    case exclude
    /// "That's it", "done", "send it".
    case finish
}

/// What a spoken phrase means here, or nothing at all.
///
/// Whole-phrase matching on a normalised string, not substring sniffing: "no" inside "no pressure
/// on the switch" is not an answer, and treating it as one would quietly drop a photograph.
enum EvidenceReviewClassifier {

    static func classify(_ utterance: String) -> EvidenceReviewCommand? {
        let text = normalise(utterance)
        guard !text.isEmpty else { return nil }
        if includeAllPhrases.contains(text) { return .includeAll }
        if skipPhrases.contains(text) { return .skip }
        if finishPhrases.contains(text) { return .finish }
        if includePhrases.contains(text) { return .include }
        if excludePhrases.contains(text) { return .exclude }
        return nil
    }

    /// Lowercased, punctuation dropped, runs of whitespace collapsed, and a leading filler word
    /// removed — "um, yes please" and "Yes." are the same answer.
    ///
    /// Apostrophes are **deleted** rather than turned into spaces: a recogniser writes "that's it"
    /// and a typist writes "thats it", and splitting the first into three words would make them
    /// different answers.
    static func normalise(_ raw: String) -> String {
        let withoutApostrophes = raw.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        let stripped = withoutApostrophes.map { character -> Character in
            character.isLetter || character.isNumber || character.isWhitespace ? character : " "
        }
        var words = String(stripped).split(separator: " ").map(String.init)
        while let first = words.first, fillers.contains(first) { words.removeFirst() }
        while let last = words.last, trailingFillers.contains(last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    private static let fillers: Set<String> = ["um", "uh", "er", "ok", "okay", "right", "so", "well"]
    private static let trailingFillers: Set<String> = ["please", "thanks", "thank", "you", "mate"]

    private static let includeAllPhrases: Set<String> = [
        "include all", "include them all", "include everything", "all of them", "send them all",
        "send all", "send all of them", "keep them all", "keep all", "all the photos",
        "include all the photos", "everything",
    ]
    private static let skipPhrases: Set<String> = [
        "skip photos", "skip the photos", "no photos", "skip photo", "skip them", "skip all",
        "leave the photos", "leave them all out", "just the text", "text only", "none of them",
        "no pictures",
    ]
    private static let finishPhrases: Set<String> = [
        "done", "thats it", "that is it", "finished", "send it", "send the report", "im done",
        "i am done", "that will do",
    ]
    private static let includePhrases: Set<String> = [
        "yes", "yeah", "yep", "yup", "include it", "include that", "keep it", "keep that",
        "send it too", "that one", "include this", "keep this one",
    ]
    private static let excludePhrases: Set<String> = [
        "no", "nope", "nah", "leave it out", "leave that out", "skip that", "skip that one",
        "not that one", "exclude it", "exclude that", "drop it", "drop that one",
    ]
}

/// Where the spoken review has got to.
///
/// Immutable: `advance` returns the next state, the way `JobIntakeState` does, so a view can hold
/// one value and a test can drive a whole conversation without a service.
struct EvidenceReviewVoiceState: Equatable {

    /// What the app does with the answer it just heard.
    struct Step: Equatable {
        let state: EvidenceReviewVoiceState
        /// The line to speak, if the answer earns one.
        let spoken: String?
        /// Whether the utterance was an answer. False means it never was one, and the turn should
        /// carry on to the model untouched with the review still open.
        let consumed: Bool
        /// True once the technician has said how the report should go out.
        var isSettled: Bool { state.isSettled }
    }

    /// The selection as it stands. The grid and the voice path edit the same value.
    private(set) var selection: EvidenceSelection
    /// The item being read out, as an index into the selection's own capture order. Nil before the
    /// first read-out and once the walk is over.
    private(set) var cursor: Int?
    /// True once "skip photos" was heard — the report goes out text-only.
    private(set) var skipped: Bool
    /// True once the technician has finished, by walking to the end or by saying so.
    private(set) var finished: Bool

    init(selection: EvidenceSelection) {
        self.selection = selection
        self.cursor = nil
        self.skipped = false
        self.finished = false
    }

    /// Whether the app has an answer it can act on.
    var isSettled: Bool { skipped || finished }

    /// What the selection amounts to now: confirmed, or the text-only record.
    var outcome: EvidenceSelection {
        skipped ? EvidenceSelection.skipped() : selection.confirmed()
    }

    /// The item the next yes/no refers to.
    func currentItemId(in items: [JobMediaItem]) -> String? {
        guard let cursor, cursor >= 0, cursor < selection.entries.count else { return nil }
        let id = selection.entries[cursor].itemId
        return items.contains { $0.id == id } ? id : nil
    }

    // MARK: - Driving it

    /// Hear an utterance. Not an answer → `consumed == false` and nothing changes.
    func hearing(_ utterance: String, items: [JobMediaItem]) -> Step {
        guard let command = EvidenceReviewClassifier.classify(utterance) else {
            return Step(state: self, spoken: nil, consumed: false)
        }
        return advance(command, items: items)
    }

    /// Start the one-at-a-time walk: read out the first item.
    func beginWalk(items: [JobMediaItem]) -> Step {
        var next = self
        next.cursor = -1
        return next.moveOn(items: items, saying: nil)
    }

    func advance(_ command: EvidenceReviewCommand, items: [JobMediaItem]) -> Step {
        var next = self
        switch command {
        case .includeAll:
            next.selection.includeAll()
            next.finished = true
            next.cursor = nil
            let count = next.selection.includedCount
            return Step(state: next, spoken: "All \(count) going with the report.", consumed: true)

        case .skip:
            next.skipped = true
            next.cursor = nil
            return Step(state: next, spoken: "No photos, then — just the record.", consumed: true)

        case .finish:
            next.finished = true
            next.cursor = nil
            return Step(state: next, spoken: Self.settledLine(next.selection), consumed: true)

        case .include, .exclude:
            // A yes or a no with nothing being read out is not an answer to this step. Passing it
            // through is the honest reading: the technician was answering something else.
            guard let id = currentItemId(in: items) else {
                return Step(state: self, spoken: nil, consumed: false)
            }
            next.selection.setIncluded(command == .include, for: id)
            return next.moveOn(items: items,
                               saying: command == .include ? "Keeping it." : "Leaving it out.")
        }
    }

    /// Step the cursor to the next item that still exists, and read it out.
    private func moveOn(items: [JobMediaItem], saying acknowledgement: String?) -> Step {
        var next = self
        var index = (next.cursor ?? -1) + 1
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        while index < next.selection.entries.count, byId[next.selection.entries[index].itemId] == nil {
            index += 1
        }
        guard index < next.selection.entries.count else {
            next.cursor = nil
            next.finished = true
            let closing = Self.settledLine(next.selection)
            return Step(state: next,
                        spoken: [acknowledgement, closing].compactMap { $0 }.joined(separator: " "),
                        consumed: true)
        }
        next.cursor = index
        let entry = next.selection.entries[index]
        let item = byId[entry.itemId]!
        let question = Self.question(for: item, number: index + 1,
                                     of: next.selection.entries.count)
        return Step(state: next,
                    spoken: [acknowledgement, question].compactMap { $0 }.joined(separator: " "),
                    consumed: true)
    }

    /// "Photo 2 of 5, suction gauge at 118. Include it?" — the caption is what the technician
    /// recognises a picture by, and the count is what tells them how much longer this goes on.
    static func question(for item: JobMediaItem, number: Int, of total: Int) -> String {
        let what = item.caption?.isEmpty == false ? item.caption! : "no caption"
        return "\(item.kind.noun.capitalized) \(number) of \(total), \(what). Include it?"
    }

    /// What the app says once the answer is settled.
    static func settledLine(_ selection: EvidenceSelection) -> String {
        let count = selection.includedCount
        guard count > 0 else { return "Nothing going with the report, then — just the record." }
        return count == 1 ? "One going with the report." : "\(count) going with the report."
    }
}
