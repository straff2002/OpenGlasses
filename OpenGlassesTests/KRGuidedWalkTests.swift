import XCTest
@testable import OpenGlasses

/// Plan KR P4 — guided work in the trade's words. Every chain name, table and request here is
/// invented.
final class KRGuidedWalkTests: XCTestCase {

    private let sizing = "Size a conductor for a load"
    private let aluminumSizing = "Size an aluminum feeder"
    private let fill = "Conduit fill for widgets"
    private let drop = "Voltage drop on a run"
    private let check = "Check an installed conductor"

    private func asks(_ said: String, _ chain: String) -> Bool {
        TechnicianRequest.asksToRunChain(said, chain: chain)
    }

    func testAWalkThroughRequestSharingTheChainsTaskAsksForIt() {
        XCTAssertTrue(asks("what size wire do I need for a 40 amp load, walk me through it", sizing))
        XCTAssertTrue(asks("talk me through sizing it", sizing))
        XCTAssertTrue(asks("step by step, what size cable for this load", sizing))
        XCTAssertTrue(asks("how many widgets fit in this conduit? take me through it", fill))
        XCTAssertTrue(asks("let's work it out, how much fill have I got", fill))
        XCTAssertTrue(asks("guide me through the drop in voltage on this run", drop))
        XCTAssertTrue(asks("step me through checking this one", check))
        XCTAssertTrue(asks("walk me through sizing the aluminum feeder", aluminumSizing))
    }

    func testAPlainQuestionStaysAQuestion() {
        XCTAssertFalse(asks("what size wire do I need for a 40 amp load", sizing))
        XCTAssertFalse(asks("how many widgets can I fit in this conduit?", fill))
        XCTAssertFalse(asks("what's the voltage drop on 30 metres", drop))
    }

    func testTheWalkThroughMustBeAboutTheChainsTaskAndMaterial() {
        XCTAssertFalse(asks("walk me through how this furnace lights", sizing), "no task word of the chain's")
        XCTAssertFalse(asks("walk me through the drop test on the widget", drop), "voltage drop is both words")
        XCTAssertFalse(asks("walk me through sizing the copper feeder", aluminumSizing), "the chain's material is not the turn's")
        XCTAssertFalse(asks("walk me through sizing it", aluminumSizing), "a chain with a material needs it said")
        XCTAssertFalse(asks("walk me through checking the breaker", "Conductor sizing check"),
                       "check alone is any work's word when the chain has another task")
        XCTAssertTrue(asks("walk me through sizing it", "Conductor sizing check"))
    }

    func testWithoutAChainTheOldRuleStands() {
        XCTAssertFalse(TechnicianRequest.asksToRunChain("walk me through sizing it"))
        XCTAssertTrue(TechnicianRequest.asksToRunChain("run the chain"))
        XCTAssertFalse(TechnicianRequest.asksAboutChains("walk me through sizing it"))
    }

    @MainActor
    func testTheStartGateTakesTheWalkThroughAndAYesToTheOffer() {
        XCTAssertNil(RuleChainTool.startRefusal(chain: sizing, said: "what size for 40 amps, walk me through it",
                                                previousReply: nil, proposed: nil))
        XCTAssertEqual(RuleChainTool.startRefusal(chain: sizing, said: "what size for 40 amps", previousReply: nil, proposed: nil),
                       RuleChainTool.notAskedRefusal)
        // The offer the refusal asks for, then a short yes: started (Plan KD P2).
        XCTAssertNil(RuleChainTool.startRefusal(chain: sizing, said: "yes",
                                                previousReply: "Size a conductor for a load works this out. Want me to run it with you?",
                                                proposed: nil))
        XCTAssertNil(RuleChainTool.startRefusal(chain: sizing, said: "yeah go ahead",
                                                previousReply: "Want me to take you through Size a conductor for a load?",
                                                proposed: nil))
    }

    @MainActor
    func testTheRefusalAsksForAYesOrNoOfferAndGivesNoWordsToSay() {
        let refusal = RuleChainTool.notAskedRefusal
        XCTAssertTrue(refusal.contains("offer the chain by its name as one yes-or-no question; a yes starts it"), refusal)
        XCTAssertTrue(refusal.contains("Never tell the technician what words to say"), refusal)
        XCTAssertFalse(refusal.contains("you may offer the chain by name."), refusal)
    }

    // MARK: - The list says a chain whose column cannot be settled can't start

    @MainActor
    func testTheListMarkNamesTheStepAndTheColumnProblem() throws {
        let markdown = """
        ## Read a banded factor
        Answers: an invented factor.

        ```chain
        ask ambient (°C) range 0..40: What is the ambient temperature?
        lookup factor = Table 98 row {ambient} column Band B rule at_least
        say "{factor}"
        ```
        """
        let chain = try XCTUnwrap(ChainParser.parse(markdown).chains.first)
        let problem = try XCTUnwrap(RuleChainTool.columnProblems(chain, tables: RuleChainFixtures.tables()).first)
        XCTAssertEqual(RuleChainTool.listMark(problem), "step 2 (factor) names a column of Table 98 printed under more than one heading")
    }
}
