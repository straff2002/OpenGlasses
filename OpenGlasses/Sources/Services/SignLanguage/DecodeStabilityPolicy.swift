import Foundation

/// Turns a noisy per-frame letter-classifier stream into displayed / committed / spoken text
/// (Plan CK P0) — the same noisy-classifier-to-action shape as the wake-word and frame-gate
/// work, reusable by any future streaming classifier.
///
/// Layered gates, each a rule in `Rules`:
/// - **confidence floor** — sub-floor frames are treated as blanks, never as letters;
/// - **out-of-vocabulary rejection** — characters outside the allowed set are discarded;
/// - **N-frame majority vote** — the candidate letter is the majority of the recent window,
///   so a single flickered frame can't act;
/// - **streak to display** — a candidate must persist `displayStreak` consecutive votes before
///   it is appended to the provisional word (double letters need an intervening gap);
/// - **gap + dictionary check to commit** — a sustained blank gap ends the word; it commits
///   (→ spoken) only if the injected validator accepts it, otherwise it is rejected.
///
/// Pure and clockless — tests drive it with synthetic streams.
struct DecodeStabilityPolicy {

    struct Rules {
        /// Below this confidence a frame counts as blank.
        var confidenceFloor: Double = 0.5
        /// Majority-vote window over recent frames.
        var voteWindow: Int = 5
        /// Consecutive winning votes before a letter is appended (displayed).
        var displayStreak: Int = 3
        /// Consecutive blank votes that end the word and trigger the commit decision.
        var commitGapFrames: Int = 8
        /// Hard cap — a runaway stream must not accumulate unbounded text.
        var maxWordLength: Int = 24
        /// The letter vocabulary; anything else is rejected outright.
        var allowedLetters: Set<Character> = Set("abcdefghijklmnopqrstuvwxyz0123456789'-")
        /// Word-level acceptance at commit time (e.g. a dictionary + proper-noun heuristics).
        /// nil accepts everything — fingerspelling exists for out-of-dictionary names, so the
        /// default must not eat them.
        var validateWord: ((String) -> Bool)?

        init() {}
    }

    /// What the caller should do after feeding one frame.
    enum Event: Equatable {
        /// Nothing changed.
        case none
        /// The provisional word changed — update the caption/HUD.
        case display(String)
        /// A word finished and passed validation — speak it.
        case commit(String)
        /// A word finished but failed validation — cleared without speech.
        case rejected(String)
    }

    let rules: Rules

    private var votes: [Character?] = []          // recent per-frame observations (nil = blank)
    private var streakLetter: Character?
    private var streakCount = 0
    private var gapCount = 0
    private(set) var currentWord = ""
    /// A gap since the last append allows the same letter to repeat (double letters).
    private var gapSinceLastAppend = true

    init(rules: Rules = Rules()) {
        self.rules = rules
    }

    /// Feed one classifier frame: the top letter (nil for blank/no hand) and its confidence.
    mutating func observe(letter: Character?, confidence: Double) -> Event {
        // Floor + vocabulary gates: what survives is either a valid letter or a blank.
        let observed: Character? = {
            guard let raw = letter, confidence >= rules.confidenceFloor else { return nil }
            let lowered = String(raw).lowercased()
            guard lowered.count == 1, let candidate = lowered.first,
                  rules.allowedLetters.contains(candidate) else { return nil }
            return candidate
        }()

        votes.append(observed)
        if votes.count > max(rules.voteWindow, 1) { votes.removeFirst() }

        guard let winner = majority() else { return .none }

        switch winner {
        case .blank:
            streakLetter = nil
            streakCount = 0
            gapCount += 1
            gapSinceLastAppend = true
            if gapCount == rules.commitGapFrames, !currentWord.isEmpty {
                return finishWord()
            }
            return .none

        case .letter(let letter):
            gapCount = 0
            if letter == streakLetter {
                streakCount += 1
            } else {
                streakLetter = letter
                streakCount = 1
            }
            guard streakCount == rules.displayStreak else { return .none }
            // Append once per streak; the same letter re-appends only after a gap.
            guard gapSinceLastAppend || letter != currentWord.last else { return .none }
            guard currentWord.count < rules.maxWordLength else { return .none }
            currentWord.append(letter)
            gapSinceLastAppend = false
            return .display(currentWord)
        }
    }

    /// Force-finish the pending word (e.g. the user stopped the feature mid-word).
    mutating func flush() -> Event {
        guard !currentWord.isEmpty else { return .none }
        return finishWord()
    }

    /// Reset all stream state (word, votes, streaks).
    mutating func reset() {
        votes.removeAll()
        streakLetter = nil
        streakCount = 0
        gapCount = 0
        currentWord = ""
        gapSinceLastAppend = true
    }

    // MARK: - Private

    private enum Vote: Equatable {
        case blank
        case letter(Character)
    }

    /// Strict majority of the current vote window; nil when the window is empty or tied.
    private func majority() -> Vote? {
        guard !votes.isEmpty else { return nil }
        var counts: [Character?: Int] = [:]
        for vote in votes { counts[vote, default: 0] += 1 }
        let best = counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : (lhs.key == nil && rhs.key != nil)
        }
        guard let best, best.value * 2 > votes.count else { return nil }
        return best.key.map(Vote.letter) ?? .blank
    }

    private mutating func finishWord() -> Event {
        let word = currentWord
        currentWord = ""
        streakLetter = nil
        streakCount = 0
        gapSinceLastAppend = true
        if rules.validateWord?(word) ?? true {
            return .commit(word)
        }
        return .rejected(word)
    }
}
