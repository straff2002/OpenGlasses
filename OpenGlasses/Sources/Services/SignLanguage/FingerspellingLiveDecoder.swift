import Foundation

/// Live fingerspelling decode engine (Plan CK P2): holistic landmark frames in, display /
/// commit / reject events out. Pure and clockless — the landmark source, the model, and the
/// tick cadence are all injected, so the whole engine runs headlessly in tests.
///
/// Per appended frame: all-NaN frames (nobody in view / hands down) never enter the model
/// window — each one is fed to the stability policy as blank time instead, which is what
/// accrues the end-of-word gap. Real frames enter a rolling window of at most 768 frames,
/// evicted from the front in pairs so the model's stride-2 output rows keep their alignment.
///
/// Per `tick(infer:)` (cadence is the caller's decision — P3 tunes it): the current window
/// is re-preprocessed (handedness re-voted, re-standardised — matching the training
/// pipeline's whole-window semantics), the model produces ⌈T/2⌉ valid logit rows, and rows
/// not yet consumed are fed to `DecodeStabilityPolicy` as (argmax letter, confidence)
/// observations. With the CTC-tuned rules below the policy *is* the greedy CTC collapse —
/// adjacent repeats fold into one letter (a letter re-appends only after a gap), blanks
/// accrue toward the word-gap commit — plus the word-level commit/reject gates the P0 work
/// established. Already-consumed rows are never re-fed; later re-decodes can refine earlier
/// rows and cadence tuning may exploit that in P3.
struct FingerspellingLiveDecoder {

    /// Runs the model over one fixed window. Returns all 384 logit rows (or at least the
    /// first ⌈frameCount/2⌉); throws on inference failure.
    typealias Inference = (HolisticWindower.ModelInput) throws -> [[Float]]

    /// Policy rules tuned for CTC output rows (≈ 15 rows/s at a 30 fps camera) rather than
    /// raw classifier frames: vote window and display streak of 1 make the policy a pure
    /// greedy-CTC collapser; a letter must clear `confidenceFloor`; ~8 blank rows (≈ 0.5 s)
    /// end a word. The charset drops the space — a decoded space is out-of-vocabulary, so
    /// it lands as blank time, i.e. a word boundary, which is exactly its meaning.
    static func ctcRules(validateWord: ((String) -> Bool)? = nil) -> DecodeStabilityPolicy.Rules {
        var rules = DecodeStabilityPolicy.Rules()
        rules.voteWindow = 1
        rules.displayStreak = 1
        rules.commitGapFrames = 8
        rules.confidenceFloor = 0.5
        rules.allowedLetters = Set(FingerspellingCTCDecoder.charset).subtracting([" "])
        rules.validateWord = validateWord
        return rules
    }

    private(set) var policy: DecodeStabilityPolicy
    private var window: [HolisticFrame] = []
    /// Frame pairs evicted from the front of the window since `reset()` — the number of
    /// model output rows that have scrolled out of reach.
    private var evictedPairs = 0
    /// Absolute output-row count (evicted + in-window) already fed to the policy.
    private var consumedRows = 0

    init(rules: DecodeStabilityPolicy.Rules = FingerspellingLiveDecoder.ctcRules()) {
        self.policy = DecodeStabilityPolicy(rules: rules)
    }

    /// The provisional word, for caption surfaces.
    var currentWord: String { policy.currentWord }

    /// Real frames currently in the model window.
    var windowedFrameCount: Int { window.count }

    /// Feed one landmark frame. All-NaN frames count as blank time immediately (events can
    /// fire from gap commits); real frames wait for the next `tick`.
    mutating func append(_ frame: HolisticFrame) -> [DecodeStabilityPolicy.Event] {
        guard frame.points.count == HolisticLayout.landmarkCount else { return [] }
        if frame.isAllNaN {
            let event = policy.observe(letter: nil, confidence: 1)
            return event == .none ? [] : [event]
        }
        window.append(frame)
        while window.count > HolisticWindower.windowLength {
            window.removeFirst(2)
            evictedPairs += 1
        }
        return []
    }

    /// Run the model over the current window and feed any new output rows to the policy.
    mutating func tick(infer: Inference) rethrows -> [DecodeStabilityPolicy.Event] {
        guard let input = HolisticWindower.modelInput(for: window) else { return [] }
        let validRows = (input.frameCount + 1) / 2

        let firstUnconsumed = consumedRows - evictedPairs
        guard firstUnconsumed < validRows else { return [] }

        let logitRows = try infer(input)
        guard logitRows.count >= validRows else { return [] }

        var events: [DecodeStabilityPolicy.Event] = []
        for row in max(firstUnconsumed, 0)..<validRows {
            let observation = FingerspellingCTCDecoder.observation(forRow: logitRows[row])
            let event = policy.observe(letter: observation.letter,
                                       confidence: observation.confidence)
            if event != .none { events.append(event) }
        }
        consumedRows = evictedPairs + validRows
        return events
    }

    /// Force-finish the pending word (feature stopped mid-word).
    mutating func flush() -> DecodeStabilityPolicy.Event {
        policy.flush()
    }

    /// Clear the window and all stream state.
    mutating func reset() {
        window.removeAll()
        evictedPairs = 0
        consumedRows = 0
        policy.reset()
    }
}
