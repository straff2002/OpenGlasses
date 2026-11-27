import XCTest
@testable import OpenGlasses

/// A rule chain asked for over two turns: "help me size this cable", the assistant asks which case it
/// is, and the technician's answer settles it. A tester's report had the sizing chain refused at
/// both turns — the request named no material and the answer asked for nothing — so the model
/// worked the table itself and gave up. Every chain name and reply here is invented.
final class ChainTwoTurnRequestTests: XCTestCase {

    private let copperSizing = "Size a copper conductor for a load"
    private let fill = "Conduit fill for widgets"
    private let request = "Help me size this cable"
    private let question = "What's the load, and is it copper or aluminum?"
    private let answer = "OK it's about 15 amps, copper, three in the pipe, warm loft"

    @MainActor
    private func refusal(_ said: String, previousReply: String?, previousRequest: String?, chain: String? = nil) -> String? {
        RuleChainTool.startRefusal(chain: chain ?? copperSizing, said: said, previousReply: previousReply,
                                   proposed: nil, previousRequest: previousRequest)
    }

    @MainActor
    func testTheAnswerToTheAssistantsQuestionStartsTheChainAskedForLastTurn() {
        XCTAssertNil(refusal(answer, previousReply: question, previousRequest: request))
        XCTAssertNil(refusal("copper, two of them, normal room", previousReply: question,
                             previousRequest: "can you walk me through sizing this"))
    }

    @MainActor
    func testTheSameAnswerWithNoRequestBeforeItIsStillRefused() {
        XCTAssertEqual(refusal(answer, previousReply: question, previousRequest: nil), RuleChainTool.notAskedRefusal)
        XCTAssertEqual(refusal(answer, previousReply: nil, previousRequest: request), RuleChainTool.notAskedRefusal)
    }

    @MainActor
    func testTheAssistantMustHaveAskedSomething() {
        XCTAssertEqual(refusal(answer, previousReply: "Table 99 covers that.", previousRequest: request),
                       RuleChainTool.notAskedRefusal)
    }

    @MainActor
    func testAPlainQuestionLastTurnAsksForNoChain() {
        XCTAssertEqual(refusal(answer, previousReply: question, previousRequest: "what size cable for 15 amps"),
                       RuleChainTool.notAskedRefusal)
    }

    @MainActor
    func testAnAnswerThatTurnsItDownAsksForNothing() {
        XCTAssertEqual(refusal("no, forget it, it's copper anyway", previousReply: question, previousRequest: request),
                       RuleChainTool.notAskedRefusal)
        XCTAssertEqual(refusal("never mind, copper", previousReply: question, previousRequest: request),
                       RuleChainTool.notAskedRefusal)
    }

    @MainActor
    func testTheTwoTurnsMustCarryTheChainsTaskAndMaterial() {
        XCTAssertEqual(refusal("it's aluminum, three in the pipe", previousReply: question, previousRequest: request),
                       RuleChainTool.notAskedRefusal, "the chain's material is not the one said")
        XCTAssertEqual(refusal("copper", previousReply: "Which panel?", previousRequest: "help me find the panel"),
                       RuleChainTool.notAskedRefusal, "no task word of the chain's")
        XCTAssertEqual(refusal(answer, previousReply: question, previousRequest: request, chain: fill),
                       RuleChainTool.notAskedRefusal, "sizing is not the fill chain's task")
    }

    // MARK: - The Activity trail says whether the chain started

    func testARefusedStartIsNotRecordedAsStarted() {
        let started = "Started a rule chain"
        XCTAssertEqual(RuleChainTool.trailTitle(started, tool: "rule_chain", actionKey: "start",
                                                outcome: .completed(RuleChainTool.notAskedRefusal)),
                       RuleChainTool.notStartedTitle)
        XCTAssertEqual(RuleChainTool.trailTitle(started, tool: "rule_chain", actionKey: "start",
                                                outcome: .completed("Running now: \(copperSizing), step 1 of 6.\n"
                                                                    + RuleChainTool.startedMarker + copperSizing + "'.")),
                       started)
        XCTAssertEqual(RuleChainTool.trailTitle("Answered a rule chain's question", tool: "rule_chain", actionKey: "answer",
                                                outcome: .completed("Not taken: pass 'step'.")),
                       "Answered a rule chain's question", "only a start is retitled")
        XCTAssertEqual(RuleChainTool.trailTitle("Looked up a value", tool: "table_lookup", actionKey: "start",
                                                outcome: .completed("no")),
                       "Looked up a value")
    }

    func testHelpMeWithTheChainsTaskAndMaterialAsksInOneTurn() {
        XCTAssertTrue(TechnicianRequest.asksToRunChain("help me size a copper cable for 15 amps", chain: copperSizing))
        XCTAssertFalse(TechnicianRequest.asksToRunChain("help me size this cable", chain: copperSizing),
                       "a chain with a material needs it said")
        XCTAssertFalse(TechnicianRequest.asksToRunChain("what size copper cable for 15 amps", chain: copperSizing),
                       "a question stays a question")
    }
}
