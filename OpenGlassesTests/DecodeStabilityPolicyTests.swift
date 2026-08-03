import XCTest
@testable import OpenGlasses

/// Synthetic-stream tests for the fingerspelling decode-stability policy (Plan CK P0):
/// confidence floor, OOV rejection, majority vote, display/commit streaks, double letters,
/// dictionary gate, flush/reset.
final class DecodeStabilityPolicyTests: XCTestCase {

    private func makePolicy(_ tweak: (inout DecodeStabilityPolicy.Rules) -> Void = { _ in }) -> DecodeStabilityPolicy {
        var rules = DecodeStabilityPolicy.Rules()
        rules.voteWindow = 3
        rules.displayStreak = 2
        rules.commitGapFrames = 3
        tweak(&rules)
        return DecodeStabilityPolicy(rules: rules)
    }

    /// Feed `letter` n times, returning the last event.
    @discardableResult
    private func feed(_ policy: inout DecodeStabilityPolicy, _ letter: Character?, times: Int,
                      confidence: Double = 0.9) -> DecodeStabilityPolicy.Event {
        var last = DecodeStabilityPolicy.Event.none
        for _ in 0..<times { last = policy.observe(letter: letter, confidence: confidence) }
        return last
    }

    // MARK: - Letter gates

    func testSteadyLetterDisplaysAfterStreak() {
        var policy = makePolicy()
        XCTAssertEqual(policy.observe(letter: "h", confidence: 0.9), .none)   // vote 1, streak 1
        XCTAssertEqual(policy.observe(letter: "h", confidence: 0.9), .display("h"))
    }

    func testLowConfidenceFramesActAsBlanks() {
        var policy = makePolicy()
        feed(&policy, "h", times: 6, confidence: 0.3)
        XCTAssertEqual(policy.currentWord, "")
    }

    func testOutOfVocabularySymbolsRejected() {
        var policy = makePolicy()
        feed(&policy, "!", times: 6)
        XCTAssertEqual(policy.currentWord, "")
    }

    func testSingleFlickerFrameCannotAct() {
        var policy = makePolicy()
        feed(&policy, "h", times: 4)
        // One stray 'x' inside a run of 'h': majority stays 'h', word untouched.
        XCTAssertEqual(policy.observe(letter: "x", confidence: 0.9), .none)
        feed(&policy, "h", times: 2)
        XCTAssertEqual(policy.currentWord, "h")
    }

    func testUppercaseNormalisedToLowercase() {
        var policy = makePolicy()
        feed(&policy, "H", times: 3)
        XCTAssertEqual(policy.currentWord, "h")
    }

    // MARK: - Words

    func testWordCommitsAfterGap() {
        var policy = makePolicy()
        feed(&policy, "h", times: 3)
        feed(&policy, "i", times: 3)
        XCTAssertEqual(policy.currentWord, "hi")
        // Sustained blank: one frame to swing the majority off the letter, then the gap streak
        // (3) — the commit fires exactly on the 4th blank frame.
        let event = feed(&policy, nil, times: 4)
        XCTAssertEqual(event, .commit("hi"))
        XCTAssertEqual(policy.currentWord, "")
    }

    func testDictionaryRejectionClearsWithoutSpeech() {
        var policy = makePolicy { $0.validateWord = { $0 == "hi" } }
        feed(&policy, "z", times: 3)
        let event = feed(&policy, nil, times: 4)
        XCTAssertEqual(event, .rejected("z"))
    }

    func testDoubleLetterNeedsGap() {
        var policy = makePolicy()
        feed(&policy, "l", times: 8)              // long steady run appends exactly one 'l'
        XCTAssertEqual(policy.currentWord, "l")
        feed(&policy, nil, times: 2)              // short gap (below commit threshold)
        feed(&policy, "l", times: 4)
        XCTAssertEqual(policy.currentWord, "ll")  // second 'l' allowed after the gap
    }

    func testMaxWordLengthCapped() {
        var policy = makePolicy { $0.maxWordLength = 2 }
        for letter in ["a", "b", "c"] {
            feed(&policy, Character(letter), times: 3)
            feed(&policy, nil, times: 1)
        }
        XCTAssertEqual(policy.currentWord, "ab")
    }

    func testFlushCommitsPendingWord() {
        var policy = makePolicy()
        feed(&policy, "o", times: 3)
        feed(&policy, "k", times: 3)
        XCTAssertEqual(policy.flush(), .commit("ok"))
        XCTAssertEqual(policy.flush(), .none)   // nothing left
    }

    func testResetDropsEverything() {
        var policy = makePolicy()
        feed(&policy, "a", times: 3)
        policy.reset()
        XCTAssertEqual(policy.currentWord, "")
        XCTAssertEqual(policy.flush(), .none)
    }

    func testCommitFiresExactlyOncePerGap() {
        var policy = makePolicy()
        feed(&policy, "a", times: 3)
        var commits = 0
        for _ in 0..<10 {
            if case .commit = policy.observe(letter: nil, confidence: 0) { commits += 1 }
        }
        XCTAssertEqual(commits, 1)
    }
}
