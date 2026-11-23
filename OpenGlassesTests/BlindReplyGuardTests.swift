import XCTest
@testable import OpenGlasses

/// Plan NA P0 — what the wearer hears when a sentence trips: each surface's action, hazard
/// sentences never withheld, one line per reply, the ambient loops' once-per-session line and
/// urgency rules; the screen that applies it to a whole reply; the tally's counts.
final class BlindReplyGuardTests: XCTestCase {

    private let safety = BlindReplyCheck.Finding(flag: .assertedSafety, basis: .phrase, exemption: nil)
    private let reading = BlindReplyCheck.Finding(flag: .ungroundedReadingNumber, basis: .reading, exemption: nil)
    private let visual = BlindReplyCheck.Finding(flag: .visualAssumption, basis: .phrase, exemption: nil)
    private let negated = BlindReplyCheck.Finding(flag: .assertedSafety, basis: .phrase, exemption: .negated)

    private func decide(_ surface: BlindReplyGuard.Surface, _ findings: [BlindReplyCheck.Finding],
                        hazard: Bool = false, urgency: AssistiveAdvice.Urgency? = nil,
                        corrected: Bool = false) -> BlindReplyGuard.Action {
        BlindReplyGuard.decide(surface: surface, findings: findings, namesHazard: hazard,
                               urgency: urgency, alreadyCorrected: corrected)
    }

    // MARK: - Each surface

    func testNothingActingIsSaidUnchanged() {
        for surface in BlindReplyGuard.Surface.allCases {
            XCTAssertEqual(decide(surface, []), .count)
            XCTAssertEqual(decide(surface, [visual]), .count)
            XCTAssertEqual(decide(surface, [negated]), .count)
        }
    }

    func testDirectReplacesAndLiveStops() {
        XCTAssertEqual(decide(.direct, [safety]), .replace(.safety))
        XCTAssertEqual(decide(.direct, [reading]), .replace(.readingNumber))
        XCTAssertEqual(decide(.live, [safety]), .stopAndCorrect(.safety))
        XCTAssertEqual(decide(.live, [reading]), .stopAndCorrect(.readingNumber))
        XCTAssertEqual(decide(.direct, [reading, safety]), .replace(.safety), "safety outranks a number")
    }

    func testHazardSentencesAreNeverWithheld() {
        XCTAssertEqual(decide(.direct, [safety], hazard: true), .speakThenCorrect(.safety))
        XCTAssertEqual(decide(.live, [safety], hazard: true), .speakThenCorrect(.safety))
        for surface in [BlindReplyGuard.Surface.navigation, .assistive, .narration] {
            XCTAssertEqual(decide(surface, [safety], hazard: true, urgency: .low), .speakThenCorrect(.safety))
            XCTAssertEqual(decide(surface, [safety], hazard: true, corrected: true), .count)
        }
        XCTAssertEqual(decide(.direct, [safety], hazard: true, corrected: true), .count)
    }

    func testOneLinePerReply() {
        XCTAssertEqual(decide(.direct, [safety], corrected: true), .drop)
        XCTAssertEqual(decide(.live, [safety], corrected: true), .drop)
    }

    func testAmbientUrgencyRules() {
        for surface in [BlindReplyGuard.Surface.navigation, .assistive] {
            XCTAssertEqual(decide(surface, [safety], urgency: .low), .drop)
            XCTAssertEqual(decide(surface, [safety], urgency: .medium), .speakThenCorrect(.safety))
            XCTAssertEqual(decide(surface, [safety], urgency: .high), .speakThenCorrect(.safety))
            XCTAssertEqual(decide(surface, [safety], urgency: .high, corrected: true), .drop)
        }
        XCTAssertEqual(decide(.narration, [safety]), .drop, "narration has no urgency: read as low")
    }

    // MARK: - Hazard lexicon

    func testHazardWordsAreReadUnnegated() {
        XCTAssertTrue(BlindReplyGuard.namesHazard("Kerb ahead, then it's clear."))
        XCTAssertTrue(BlindReplyGuard.namesHazard("A car is approaching from the left, but the way is clear."))
        XCTAssertFalse(BlindReplyGuard.namesHazard("No cars, it's clear."))
        XCTAssertFalse(BlindReplyGuard.namesHazard("There are no steps and the path is clear."))
        XCTAssertFalse(BlindReplyGuard.namesHazard("The path is clear."))
        XCTAssertFalse(BlindReplyGuard.namesHazard("It's safe to cross without any traffic."))
    }

    // MARK: - The lines

    func testTheLinesCarryNoAssurance() {
        for line in BlindReplyLine.allCases {
            for live in [false, true] {
                let text = line.text(live: live)
                XCTAssertFalse(text.isEmpty)
                XCTAssertEqual(text.hasPrefix("Correction:"), live)
                let result = BlindReplyCheck.check(.init(sentence: text))
                XCTAssertFalse(result.acts, "the line must not trip the check: \(text)")
            }
            XCTAssertFalse(BlindReplyCheck.check(.init(sentence: line.modelNote)).acts, line.modelNote)
        }
    }

    // MARK: - A whole reply

    func testAWholeReplyIsScreenedSentenceBySentence() {
        let reply = "There's a bench on your left. The path is clear, so you can walk on. Ask me again any time."
        let whole = BlindReplyScreen.screenWhole(reply, surface: .direct, scope: .init(phrases: true, numbers: true),
                                                 question: nil, evidence: nil, appLanguageIsEnglish: true)
        XCTAssertTrue(whole.changed)
        XCTAssertEqual(whole.text, "There's a bench on your left. \(BlindReplyLine.safety.text(live: false)) Ask me again any time.")
        XCTAssertEqual(whole.replacements.map(\.original), ["The path is clear, so you can walk on."])
    }

    func testAReplyWithNothingToChangeComesBackByteForByte() {
        let reply = "There's a bench on your left.\n\n- A door at two o'clock.\n- A ramp beyond it."
        let whole = BlindReplyScreen.screenWhole(reply, surface: .direct, scope: .init(phrases: true, numbers: true),
                                                 question: nil, evidence: nil, appLanguageIsEnglish: true)
        XCTAssertFalse(whole.changed)
        XCTAssertEqual(whole.text, reply)
    }

    func testASecondTripInTheSameReplyIsDropped() {
        let reply = "The way ahead is clear for now. It's all clear further along too. Mind how you go along there."
        let whole = BlindReplyScreen.screenWhole(reply, surface: .direct, scope: .init(phrases: true, numbers: false),
                                                 question: nil, evidence: nil, appLanguageIsEnglish: true)
        XCTAssertEqual(whole.screened.map(\.action), [.replace(.safety), .drop, .count])
    }

    func testOffScopeChangesNothing() {
        let reply = "The path is clear."
        let whole = BlindReplyScreen.screenWhole(reply, surface: .direct, scope: .off, question: nil,
                                                 evidence: nil, appLanguageIsEnglish: true)
        XCTAssertEqual(whole.text, reply)
        XCTAssertTrue(whole.screened.isEmpty)
    }

    func testTheAmbientLineIsSaidOncePerLoopSession() {
        var corrected = false
        let first = BlindReplyScreen.screenAmbient("Kerb at two o'clock, then the way is clear.", surface: .navigation,
                                                   urgency: .medium, enabled: true, alreadyCorrected: &corrected,
                                                   appLanguageIsEnglish: true)
        XCTAssertTrue(corrected)
        XCTAssertTrue(first.text.hasSuffix(BlindReplyLine.safety.text(live: false)))
        let second = BlindReplyScreen.screenAmbient("The way is clear.", surface: .navigation, urgency: .medium,
                                                    enabled: true, alreadyCorrected: &corrected,
                                                    appLanguageIsEnglish: true)
        XCTAssertEqual(second.text, "", "dropped: the line has been said this session")
        let low = BlindReplyScreen.screenAmbient("The way ahead is clear.", surface: .assistive, urgency: .low,
                                                 enabled: true, alreadyCorrected: &corrected, appLanguageIsEnglish: true)
        XCTAssertEqual(low.text, "")
    }

    func testTheKillSwitchTurnsTheAmbientCheckOff() {
        var corrected = false
        let whole = BlindReplyScreen.screenAmbient("The way is clear.", surface: .navigation, urgency: .low,
                                                   enabled: false, alreadyCorrected: &corrected,
                                                   appLanguageIsEnglish: true)
        XCTAssertEqual(whole.text, "The way is clear.")
        XCTAssertFalse(corrected)
    }

    // MARK: - Scope (decision 8)

    func testScope() {
        XCTAssertEqual(BlindReplyScreen.Scope.forTurn(activeModeId: BlindAssistanceContract.presetID, enabled: true),
                       .init(phrases: true, numbers: true))
        XCTAssertEqual(BlindReplyScreen.Scope.forTurn(activeModeId: "standard", enabled: true),
                       .init(phrases: false, numbers: true))
        XCTAssertEqual(BlindReplyScreen.Scope.forTurn(activeModeId: LiveAIMode.interpreterID, enabled: true), .off)
        XCTAssertEqual(BlindReplyScreen.Scope.forTurn(activeModeId: BlindAssistanceContract.presetID, enabled: false), .off)
        XCTAssertEqual(BlindReplyScreen.Scope.ambient(enabled: true), .init(phrases: true, numbers: false))
    }

    // MARK: - Tally

    func testTheTallyCountsByFlagOutcomeAndExemption() {
        var tally = BlindReplyCheckTally()
        XCTAssertEqual(tally.reportLines, [])
        var screen = BlindReplyScreen(surface: .direct, scope: .init(phrases: true, numbers: true))
        let items = [
            screen.screen("The path is clear.", evidence: nil),
            screen.screen("I can't tell whether it's safe to cross.", evidence: nil),
            screen.screen("As you can see, it's a door.", evidence: nil),
        ]
        for item in items { tally.record(item, surface: .direct) }
        tally.noteReplyNotEnglish()
        XCTAssertEqual(tally.sentencesChecked, 3)
        XCTAssertEqual(tally.reportLines,
                       ["Reply check: 3 sentences checked · assertedAbsenceOfHazard 1 (replaced 1) · visualAssumption 1 (counted 1) · negated 1 · trips by surface: direct 1 · not English 1 replies"])
    }
}
