import XCTest
@testable import OpenGlasses

/// Tests for the text gate a frame gate structurally cannot be (Plan CV P1). The fixtures are the
/// point: real rephrasing families (one scene described five ways, which `FrameGate` will never
/// see because the frame never changed) and genuine scene changes that must survive.
final class NarrationGateTests: XCTestCase {

    // MARK: - Fixtures

    /// One unchanged scene, described five ways — what a VLM actually returns across successive
    /// heartbeat re-sends of the same frame.
    private let deskFamily = [
        "A man is sitting at a desk in front of a computer.",
        "A person sitting at a desk working on a computer.",
        "Someone is working at a desk with a computer monitor.",
        "A man at a desk using a computer.",
        "The image shows a person at a desk in front of a computer screen.",
    ]

    /// Genuinely different scenes. Every one of these must get spoken.
    private let sceneChanges = [
        "A busy street with cars and pedestrians crossing at a traffic light.",
        "A kitchen counter with a kettle and two mugs beside the sink.",
        "A dog is lying on the floor next to the desk.",
        "A staircase leading up to a landing with a window.",
        "An empty conference room with a long table and chairs.",
    ]

    // MARK: - Similarity as data

    /// The asymmetry, stated as a measurement rather than a comment: every pair inside one
    /// rephrasing family scores at or above the threshold, every genuinely new scene scores below
    /// it, and there is a wide gap between the two — not a threshold tuned to sit on a boundary.
    func testRephrasingsAndSceneChangesSeparateWithMargin() {
        let threshold = NarrationGateRules().sameSceneSimilarity

        var worstRephrase = 1.0
        for (i, a) in deskFamily.enumerated() {
            for b in deskFamily[(i + 1)...] {
                worstRephrase = min(worstRephrase, NarrationGate.similarity(a, b))
            }
        }
        var bestChange = 0.0
        for change in sceneChanges {
            for described in deskFamily {
                bestChange = max(bestChange, NarrationGate.similarity(described, change))
            }
        }

        XCTAssertGreaterThanOrEqual(worstRephrase, threshold,
            "A rephrasing of the same scene scored as new — that is chatter in someone's ear.")
        XCTAssertLessThan(bestChange, threshold,
            "A genuinely new scene scored as the same — that is a missed announcement.")
        XCTAssertGreaterThan(worstRephrase - bestChange, 0.2,
            "The threshold is sitting on a boundary rather than in a gap.")
    }

    /// The exact family the plan names: without folding generic references to a person, *"a man at
    /// a desk"* and *"a person at a desk"* share no subject word at all and read as a new scene.
    func testGenericPersonReferencesFoldTogether() {
        for word in ["A man", "A woman", "Someone", "A person", "Two people"] {
            XCTAssertTrue(NarrationGate.contentWords(word).contains("person"), word)
        }
    }

    /// Vision-model boilerplate carries no scene information and would inflate the score between
    /// two genuinely different scenes.
    func testBoilerplateIsNotContent() {
        XCTAssertTrue(NarrationGate.contentWords("The image shows a scene.").isEmpty)
        XCTAssertEqual(NarrationGate.similarity("The photo shows a hallway.",
                                                "The image depicts a kitchen."), 0)
    }

    /// A terse description that happens to be a subset of a verbose one must not score 1.0 and
    /// vanish — that is the `minComparableWords` floor.
    func testTerseDescriptionIsNotSwallowedByAVerboseOne() {
        let score = NarrationGate.similarity("A desk.", deskFamily[0])
        XCTAssertLessThan(score, NarrationGateRules().sameSceneSimilarity)
    }

    // MARK: - Speech gate

    func testFirstDescriptionAlwaysSpeaks() {
        var gate = NarrationGate()
        XCTAssertEqual(gate.evaluateSpeech(deskFamily[0]), .speak)
        XCTAssertEqual(gate.spokenCount, 1)
    }

    func testEveryRephrasingOfASpokenSceneIsSuppressed() {
        var gate = NarrationGate()
        XCTAssertTrue(gate.evaluateSpeech(deskFamily[0]).isSpeak)
        for rephrase in deskFamily.dropFirst() {
            XCTAssertFalse(gate.evaluateSpeech(rephrase).isSpeak,
                           "Spoke a rephrase: \(rephrase)")
        }
        XCTAssertEqual(gate.spokenCount, 1)
        XCTAssertEqual(gate.suppressedRephraseCount, deskFamily.count - 1)
    }

    func testGenuineSceneChangesSurviveTheGate() {
        var gate = NarrationGate()
        XCTAssertTrue(gate.evaluateSpeech(deskFamily[0]).isSpeak)
        for change in sceneChanges {
            XCTAssertTrue(gate.evaluateSpeech(change).isSpeak,
                          "Suppressed a real change: \(change)")
        }
        XCTAssertEqual(gate.spokenCount, sceneChanges.count + 1)
    }

    /// The reason the comparison is against the last *spoken* description and not the last
    /// generated one. B is suppressed against A; C is a rephrase of A (0.8) but only 0.4 against
    /// B — so a baseline that drifted onto the silent B would let C through and announce the same
    /// desk twice.
    func testSuppressedRephraseDoesNotMoveTheBaseline() {
        let a = "A man is sitting at a desk in front of a computer."
        let b = "A person sitting at a desk working on a laptop."
        let c = "The image shows a person at a desk in front of a computer screen."
        XCTAssertGreaterThanOrEqual(NarrationGate.similarity(a, b), 0.5)
        XCTAssertGreaterThanOrEqual(NarrationGate.similarity(a, c), 0.5)
        XCTAssertLessThan(NarrationGate.similarity(b, c), 0.5, "Fixture no longer exercises the drift.")

        var gate = NarrationGate()
        XCTAssertTrue(gate.evaluateSpeech(a).isSpeak)
        let spokenBaseline = gate.lastSpokenContentWords
        XCTAssertFalse(gate.evaluateSpeech(b).isSpeak)
        XCTAssertEqual(gate.lastSpokenContentWords, spokenBaseline,
                       "A silent rephrase moved the baseline.")
        XCTAssertFalse(gate.evaluateSpeech(c).isSpeak,
                       "Compared against the last generated description instead of the last spoken one.")
    }

    func testEmptyOrContentlessDescriptionIsNotSpoken() {
        var gate = NarrationGate()
        XCTAssertEqual(gate.evaluateSpeech(""), .empty)
        XCTAssertEqual(gate.evaluateSpeech("   "), .empty)
        XCTAssertEqual(gate.evaluateSpeech("The image shows a scene."), .empty)
        XCTAssertEqual(gate.spokenCount, 0)
    }

    // MARK: - Generation gate

    func testNothingIsGeneratedWithoutASceneChange() {
        var gate = NarrationGate()
        XCTAssertEqual(gate.evaluateGeneration(at: 0), .idle)
        XCTAssertEqual(gate.evaluateGeneration(at: 100), .idle)
    }

    func testDwellDefersUntilTheViewSettles() {
        var gate = NarrationGate()
        gate.noteSceneChange(at: 0)
        XCTAssertEqual(gate.evaluateGeneration(at: 1.0), .settling(remaining: 0.5))
        XCTAssertEqual(gate.evaluateGeneration(at: 1.5), .generate)
    }

    /// One inference per scene change: a static scene is described once, not re-described on
    /// every tick until it moves.
    func testGeneratingConsumesThePendingSceneChange() {
        var gate = NarrationGate()
        gate.noteSceneChange(at: 0)
        XCTAssertEqual(gate.evaluateGeneration(at: 2), .generate)
        XCTAssertEqual(gate.evaluateGeneration(at: 20), .idle)
        gate.noteSceneChange(at: 21)
        XCTAssertEqual(gate.evaluateGeneration(at: 23), .generate)
    }

    /// The duty-cycle floor, which exists because VLM decode and Kokoro synthesis contend for
    /// Metal — not because of battery. It applies even to a settled, genuinely-new scene.
    func testDutyCycleFloorHoldsEvenWhenTheSceneIsSettledAndNew() {
        var rules = NarrationGateRules()
        rules.minInferenceInterval = 6
        var gate = NarrationGate(rules: rules)

        gate.noteSceneChange(at: 0)
        XCTAssertEqual(gate.evaluateGeneration(at: 2), .generate)

        gate.noteSceneChange(at: 3)
        XCTAssertEqual(gate.evaluateGeneration(at: 5), .dutyCycleFloor(remaining: 3))
        XCTAssertEqual(gate.evaluateGeneration(at: 8), .generate)
    }

    /// A wearer walking a corridor never settles. A dwell rule with no ceiling would describe
    /// nothing for the entire walk — which is the case this whole plan exists for.
    func testContinuousMotionIsDescribedAtTheDwellCeiling() {
        var rules = NarrationGateRules()
        rules.dwell = 1.5
        rules.dwellCeiling = 8
        var gate = NarrationGate(rules: rules)

        var decisions: [NarrationGate.GenerateDecision] = []
        for step in 0...20 {                       // 0…10 s, moving every half second
            let now = Double(step) * 0.5
            gate.noteSceneChange(at: now)
            decisions.append(gate.evaluateGeneration(at: now))
        }
        XCTAssertTrue(decisions.prefix(16).allSatisfy { !$0.isGenerate },
                      "Described a moving view before the ceiling.")
        XCTAssertTrue(decisions.contains(.generate),
                      "Never described anything during a continuous walk.")
    }

    func testResetClearsEverything() {
        var gate = NarrationGate()
        gate.noteSceneChange(at: 0)
        _ = gate.evaluateGeneration(at: 2)
        _ = gate.evaluateSpeech(deskFamily[0])
        gate.reset()
        XCTAssertEqual(gate.evaluateGeneration(at: 3), .idle)
        XCTAssertEqual(gate.spokenCount, 0)
        XCTAssertTrue(gate.lastSpokenContentWords.isEmpty)
        XCTAssertTrue(gate.evaluateSpeech(deskFamily[1]).isSpeak,
                      "The spoken baseline survived a reset.")
    }
}
