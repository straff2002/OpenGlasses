import XCTest
@testable import OpenGlasses

/// Plan KP P2 — a follow-ups tail is taken off a reply before anything else sees it: never in the
/// history the model is sent on later turns, never in what a turn accepts (the transcript, the
/// memory loop, the job's log) or speaks, whichever brain answered; its questions go only to the
/// card. A malformed or missing tail leaves the answer as `FollowUpTail` leaves it, and HIPAA mode
/// changes none of this.
@MainActor
final class FollowUpStrippingTests: XCTestCase {

    private let tailed = "The fuse is in the panel by the door.\n<next>Where is the panel?|How do I test it?</next>"
    private let answer = "The fuse is in the panel by the door."
    private let questions = ["Where is the panel?", "How do I test it?"]

    // MARK: - LLMService: the reply and its history

    func testTheReplyAndItsHistoryEntryLoseTheTail() {
        let llm = LLMService()
        llm.resetConversationHistoryForTesting([(role: "user", content: "where's the fuse"),
                                                (role: "assistant", content: tailed)])
        XCTAssertEqual(llm.takingFollowUpTail(tailed), answer)
        XCTAssertEqual(llm.replyFollowUps, questions)
        XCTAssertEqual(llm.conversationHistoryForTesting().last?.content, answer)
        XCTAssertFalse(llm.conversationHistoryForTesting().contains { $0.content.contains("<next>") })
    }

    func testABlockShapedHistoryEntryLosesTheTailToo() {
        let history: [[String: Any]] = [
            ["role": "user", "content": "q"],
            ["role": "assistant", "parts": [["text": tailed]]],
        ]
        let cleaned = LLMService.removingFollowUpTailFromLastAssistant(history)
        XCTAssertEqual((cleaned[1]["parts"] as? [[String: Any]])?.first?["text"] as? String, answer)

        let blocks: [[String: Any]] = [
            ["role": "assistant", "content": [["type": "text", "text": "Earlier."]]],
            ["role": "user", "content": "q"],
            ["role": "assistant", "content": [["type": "text", "text": tailed]]],
        ]
        let cleanedBlocks = LLMService.removingFollowUpTailFromLastAssistant(blocks)
        XCTAssertEqual((cleanedBlocks[2]["content"] as? [[String: Any]])?.first?["text"] as? String, answer)
        XCTAssertEqual((cleanedBlocks[0]["content"] as? [[String: Any]])?.first?["text"] as? String, "Earlier.")
    }

    func testAReplyWithoutATailIsUntouchedAndClearsTheLastFollowUps() {
        let llm = LLMService()
        _ = llm.takingFollowUpTail(tailed)
        llm.resetConversationHistoryForTesting([(role: "assistant", content: "It's twelve degrees.")])
        XCTAssertEqual(llm.takingFollowUpTail("It's twelve degrees."), "It's twelve degrees.")
        XCTAssertEqual(llm.replyFollowUps, [], "a reply without a tail offers none")
        XCTAssertEqual(llm.conversationHistoryForTesting().last?.content, "It's twelve degrees.")
    }

    func testAMalformedTailLeavesTheAnswerUntouched() {
        let llm = LLMService()
        // Cut short: only the tag text goes, never the answer.
        XCTAssertEqual(llm.takingFollowUpTail("Check the fuse.\n<next>Where is"), "Check the fuse.")
        XCTAssertEqual(llm.replyFollowUps, [])
        // Not at the end: the reply is left as written, with no follow-ups.
        let middle = "Check <next>this|that</next> first, then the breaker."
        XCTAssertEqual(llm.takingFollowUpTail(middle), middle)
        XCTAssertEqual(llm.replyFollowUps, [])
        // A stray close tag is left alone.
        XCTAssertEqual(llm.takingFollowUpTail("Done.</next>"), "Done.</next>")
        // Questions too long for a button are dropped, not cut; the answer is the same.
        XCTAssertEqual(llm.takingFollowUpTail("Done.\n<next>What is the very long way to say this question?|Why?</next>"), "Done.")
        XCTAssertEqual(llm.replyFollowUps, ["Why?"])
    }

    // MARK: - The turn spine, whichever brain answered

    private func deps(send: String, log: Box<[String]>, followUps: Box<[[String]]>,
                      postProcess: @escaping @MainActor (String) -> String = { $0 }) -> ConversationTurnRunner.Deps {
        ConversationTurnRunner.Deps(
            send: { send },
            postProcess: { raw in log.value.append("postProcess:\(raw)"); return postProcess(raw) },
            accept: { log.value.append("accept:\($0)") },
            speak: { log.value.append("speak:\($0)") },
            onCancelled: {},
            onError: { _ in },
            finish: {},
            onFollowUps: { followUps.value.append($0) })
    }

    func testNoStageAfterSendSeesTheTail() async {
        // A bridge's reply that didn't come through `LLMService` (which takes its own off first).
        let log = Box<[String]>([])
        let followUps = Box<[[String]]>([])
        await ConversationTurnRunner.run(deps(send: tailed, log: log, followUps: followUps))
        XCTAssertEqual(log.value, ["postProcess:\(answer)", "accept:\(answer)", "speak:\(answer)"],
                       "memory, the transcript and speech get the answer alone")
        XCTAssertEqual(followUps.value, [questions], "the questions go only to the card")
    }

    func testATailAMemoryTagKeptFromTheEndIsStillTakenOff() async {
        // The model put a memory tag after the tail. Memory parsing removes the tag; the tail is
        // then at the end, and comes off before anything is accepted or said.
        let log = Box<[String]>([])
        let followUps = Box<[[String]]>([])
        let reply = tailed + "\n[REMEMBER: fuse = panel by the door]"
        await ConversationTurnRunner.run(deps(send: reply, log: log, followUps: followUps, postProcess: {
            $0.replacingOccurrences(of: "\n[REMEMBER: fuse = panel by the door]", with: "")
        }))
        XCTAssertEqual(log.value.dropFirst(), ["accept:\(answer)", "speak:\(answer)"])
        XCTAssertEqual(followUps.value, [questions])
    }

    func testAReplyWithoutATailOffersNothing() async {
        let log = Box<[String]>([])
        let followUps = Box<[[String]]>([])
        await ConversationTurnRunner.run(deps(send: answer, log: log, followUps: followUps))
        XCTAssertEqual(log.value, ["postProcess:\(answer)", "accept:\(answer)", "speak:\(answer)"])
        XCTAssertEqual(followUps.value, [])
    }

    // MARK: - HIPAA

    func testUnderHIPAANoFollowUpReachesTheTranscriptOrTheHistory() async {
        let saved = Config.hipaaMode
        Config.hipaaMode = true
        defer { Config.hipaaMode = saved }

        let llm = LLMService()
        llm.resetConversationHistoryForTesting([(role: "user", content: "where's the fuse"),
                                                (role: "assistant", content: tailed)])
        let reply = llm.takingFollowUpTail(tailed)
        let history = llm.conversationHistoryForTesting().map(\.content).joined(separator: "\n")
        for question in questions { XCTAssertFalse(history.contains(question), question) }

        let accepted = Box<[String]>([])
        await ConversationTurnRunner.run(.init(
            send: { reply }, postProcess: { $0 }, accept: { accepted.value.append($0) },
            speak: { _ in }, onCancelled: {}, onError: { _ in }, finish: {}))
        XCTAssertEqual(accepted.value, [answer], "what the transcript is written from")
        for question in questions { XCTAssertFalse(accepted.value.joined().contains(question), question) }
    }
}
