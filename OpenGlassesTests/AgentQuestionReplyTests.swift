import XCTest
@testable import OpenGlasses

/// Plan FE P1 — questions, answers and explicit backend selection.
///
/// Like the P0 suite, every test here drives the **whole chain**: `CustomAgentHarness` against a
/// fixture endpoint through the shared `URLProtocol` stub → `AgentSessionService` → the spoken
/// line, plus the `code_agent` tool and the consent boundary where the wearer's answer actually
/// originates. The defects being closed all lived between those parts: a prompt with no identity,
/// a boolean where words were needed, and a reply whose transport outcome was thrown away before
/// anything was announced.
@MainActor
final class AgentQuestionReplyTests: XCTestCase {

    private let policy = AgentPollingPolicy(interval: 5, maxRetries: 2, baseBackoff: 1,
                                            maxBackoff: 4, maxUnknownStatusTicks: 3)
    private let fixedNow = Date(timeIntervalSince1970: 1_757_000_000)

    private var savedAgentMode = false

    override func setUp() {
        super.setUp()
        savedAgentMode = Config.agentModeEnabled
        Config.setAgentModeEnabled(true)
        MockURLProtocol.reset()
    }

    override func tearDown() {
        // The `code_agent` tool drives `AgentSessionService.shared`, so leave it inert for whatever
        // runs next.
        let shared = AgentSessionService.shared
        shared.speak = { _ in }
        shared.requestUserConsent = nil
        shared.requestUserText = nil
        shared.handle(.completed(AgentRunResult()))
        shared.speak = { _ in }
        Config.setAgentModeEnabled(savedAgentMode)
        MockURLProtocol.reset()
        super.tearDown()
    }

    /// Let a dispatched run's event stream drain before the test drives the session by hand, so a
    /// late `.started` cannot land on top of a question we just seeded.
    private func drainEvents(_ service: AgentSessionService) async {
        for _ in 0..<200 where !service.connectionState.isLost {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: - Fixtures

    /// An endpoint that reports questions with explicit identity and accepts answers.
    private func askingConfig(host: String = "https://agent.test") -> CustomHarnessConfig {
        var config = CustomHarnessConfig()
        config.startURL = "\(host)/start"
        config.statusURLTemplate = "\(host)/runs/{id}"
        config.cancelURLTemplate = "\(host)/runs/{id}/cancel"
        config.inputURLTemplate = "\(host)/runs/{id}/input"
        config.authHeader = "Authorization"
        config.authValue = "Bearer tok"
        config.questionPromptPath = "question.prompt"
        config.questionIDPath = "question.id"
        config.questionRevisionPath = "question.revision"
        config.questionKindPath = "question.kind"
        return config
    }

    /// The legacy shape: a status and a prompt, no question identity and nowhere to answer.
    private func legacyConfig() -> CustomHarnessConfig {
        var config = CustomHarnessConfig()
        config.startURL = "https://agent.test/start"
        config.statusURLTemplate = "https://agent.test/runs/{id}"
        config.questionPromptPath = "prompt"
        return config
    }

    private func harness(_ config: CustomHarnessConfig) -> CustomAgentHarness {
        var harness = CustomAgentHarness(config: config, session: MockURLProtocol.session())
        harness.policy = policy
        harness.sleeper = { _ in }
        return harness
    }

    private struct Drive {
        let service: AgentSessionService
        let spoken: [String]
        let questions: [AgentQuestion]
    }

    /// Run the endpoint's event stream to completion, recording every spoken line and every
    /// question the session actually surfaced.
    private func drive(_ config: CustomHarnessConfig,
                       script: [MockURLProtocol.Scripted]) async -> Drive {
        MockURLProtocol.reset()
        MockURLProtocol.script = script
        let adapter = harness(config)
        let service = AgentSessionService()
        var spoken: [String] = []
        var questions: [AgentQuestion] = []
        service.speak = { spoken.append($0) }
        service.now = { self.fixedNow }
        service.setHarness(adapter)

        let run = AgentRun(id: "r1", harness: .custom, prompt: "add a toggle", project: "my-app",
                           status: .running, startedAt: fixedNow)
        for await event in adapter.events(for: run) {
            let before = service.pendingQuestion
            service.handle(event)
            if let now = service.pendingQuestion, now != before { questions.append(now) }
        }
        return Drive(service: service, spoken: spoken, questions: questions)
    }

    private func awaiting(_ prompt: String, id: String, revision: Int = 0,
                          kind: String = "approval") -> MockURLProtocol.Scripted {
        .json("""
        {"status":"awaiting_input","question":{"id":"\(id)","revision":\(revision),
         "kind":"\(kind)","prompt":"\(prompt)"}}
        """)
    }

    /// A session with a live run already waiting on `question`, bound to `config`'s endpoint.
    private func waitingSession(_ config: CustomHarnessConfig,
                                question: AgentQuestion) -> AgentSessionService {
        let service = AgentSessionService()
        service.speak = { _ in }
        service.setHarness(harness(config))
        service.handle(.started(AgentRun(id: question.runID, harness: .custom, prompt: "p",
                                         project: "my-app", status: .running, startedAt: fixedNow)))
        service.handle(.awaitingInput(question))
        return service
    }

    private func body(of index: Int) throws -> [String: Any] {
        let entry = MockURLProtocol.requests[index]
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(entry.body))
                                as? [String: Any])
    }

    // MARK: - Question identity

    func testTheSameQuestionPolledRepeatedlyIsAnnouncedOnce() async {
        let drive = await drive(askingConfig(), script: [
            awaiting("Push to main?", id: "q1"),
            awaiting("Push to main?", id: "q1"),
            awaiting("Push to main?", id: "q1"),
            .json(#"{"status":"completed"}"#),
        ])

        XCTAssertEqual(drive.spoken.filter { $0 == "Push to main?" }.count, 1,
                       "polling a pending question every tick is not the agent asking again")
        XCTAssertEqual(drive.questions.map(\.id), ["q1"])
    }

    func testARevisionBumpIsAskedAgain() async {
        let drive = await drive(askingConfig(), script: [
            awaiting("Push to main?", id: "q1", revision: 0),
            awaiting("Push to main, force?", id: "q1", revision: 1),
            .json(#"{"status":"completed"}"#),
        ])

        XCTAssertEqual(drive.spoken.filter { $0.hasPrefix("Push to main") }.count, 2)
        XCTAssertEqual(drive.questions.map(\.revision), [0, 1])
        XCTAssertEqual(drive.questions.map(\.id), ["q1", "q1"])
    }

    /// The case text equality can never get right: two different questions, worded identically.
    func testTwoQuestionsWithIdenticalWordingAndDifferentIDsAreBothSurfaced() async {
        let drive = await drive(askingConfig(), script: [
            awaiting("Continue?", id: "q1"),
            awaiting("Continue?", id: "q2"),
            .json(#"{"status":"completed"}"#),
        ])

        XCTAssertEqual(drive.questions.map(\.id), ["q1", "q2"], "in arrival order")
        XCTAssertEqual(drive.spoken.filter { $0 == "Continue?" }.count, 2,
                       "a new question is a new ask however familiar its wording")
    }

    /// An endpoint that names no question: the identity is derived from run, wording and arrival
    /// order. A repeat while still waiting is the same question; leaving and re-entering the
    /// waiting state is a new one. That is the whole of what arrival order can tell us, and the
    /// limit is documented rather than hidden.
    func testDerivedIdentityDistinguishesByArrivalOrderOnly() async {
        let drive = await drive(legacyConfig(), script: [
            .json(#"{"status":"awaiting_input","prompt":"Continue?"}"#),
            .json(#"{"status":"awaiting_input","prompt":"Continue?"}"#),
            .json(#"{"status":"running"}"#),
            .json(#"{"status":"awaiting_input","prompt":"Continue?"}"#),
            .json(#"{"status":"completed"}"#),
        ])

        XCTAssertEqual(drive.questions.count, 2, "polled repeat suppressed; re-entry surfaced")
        XCTAssertNotEqual(drive.questions[0].id, drive.questions[1].id)
        XCTAssertTrue(drive.questions.allSatisfy { $0.id.hasPrefix("derived-") })
        XCTAssertEqual(drive.spoken.filter { $0 == "Continue?" }.count, 2)
    }

    func testDerivedIDIsDeterministicAndSurvivesRelaunch() {
        let first = AgentQuestion.derivedID(runID: "r1", prompt: "Continue?", sequence: 1)
        XCTAssertEqual(first, AgentQuestion.derivedID(runID: "r1", prompt: "Continue?", sequence: 1))
        XCTAssertNotEqual(first, AgentQuestion.derivedID(runID: "r1", prompt: "Continue?", sequence: 2))
        XCTAssertNotEqual(first, AgentQuestion.derivedID(runID: "r2", prompt: "Continue?", sequence: 1))
        XCTAssertNotEqual(first, AgentQuestion.derivedID(runID: "r1", prompt: "Stop?", sequence: 1))
    }

    func testAnUnlabelledQuestionIsTreatedAsAnApproval() {
        XCTAssertTrue(AgentQuestion.kind(fromLabel: nil, prompt: "p").isApproval)
        XCTAssertTrue(AgentQuestion.kind(fromLabel: "", prompt: "p").isApproval)
        XCTAssertTrue(AgentQuestion.kind(fromLabel: "gibberish", prompt: "p").isApproval)
        XCTAssertEqual(AgentQuestion.kind(fromLabel: "free_text", prompt: "p"), .freeText)
        XCTAssertEqual(AgentQuestion.kind(fromLabel: " TEXT ", prompt: "p"), .freeText)
    }

    /// The session's own half of the rule, driven directly.
    func testSessionSuppressesARepeatedIdentityAndReAsksANewOne() {
        let service = AgentSessionService()
        var spoken: [String] = []
        service.speak = { spoken.append($0) }
        service.handle(.started(AgentRun(id: "r", harness: .custom, prompt: "p", project: nil,
                                         status: .running, startedAt: fixedNow)))
        let question = AgentQuestion(id: "q1", revision: 0, kind: .freeText,
                                     prompt: "Which files?", runID: "r")
        service.handle(.awaitingInput(question))
        service.handle(.awaitingInput(question))
        XCTAssertEqual(spoken.filter { $0 == "Which files?" }.count, 1)

        let revised = AgentQuestion(id: "q1", revision: 1, kind: .freeText,
                                    prompt: "Which files?", runID: "r")
        service.handle(.awaitingInput(revised))
        XCTAssertEqual(spoken.filter { $0 == "Which files?" }.count, 2)
        XCTAssertEqual(service.pendingQuestion?.revision, 1)
    }

    // MARK: - Free text vs approval

    func testArbitraryTextIsForwardedVerbatimWithTheQuestionIdentity() async throws {
        let question = AgentQuestion(id: "q7", revision: 3, kind: .freeText,
                                     prompt: "Which files should I touch?", runID: "r1")
        let service = waitingSession(askingConfig(), question: question)
        MockURLProtocol.reset()
        var shown: String?
        service.requestUserText = { request, draft in
            shown = request.attributedSummary
            return draft                       // the wearer sends it as heard
        }

        let line = await service.answerPendingQuestionViaUserPrompt(text: "only change the tests")

        XCTAssertEqual(line, "Sent your answer to the agent.")
        XCTAssertEqual(service.lastReplyOutcome, .delivered)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(MockURLProtocol.requests[0].request.url?.absoluteString,
                       "https://agent.test/runs/r1/input")
        XCTAssertEqual(MockURLProtocol.requests[0].request.value(forHTTPHeaderField: "Authorization"),
                       "Bearer tok")
        let sent = try body(of: 0)
        XCTAssertEqual(sent["reply"] as? String, "only change the tests",
                       "the wearer's full text, not a boolean")
        XCTAssertEqual(sent["decision"] as? String, "text")
        XCTAssertEqual(sent["questionId"] as? String, "q7")
        XCTAssertEqual(sent["questionRevision"] as? Int, 3)
        XCTAssertNotNil(sent["replyId"] as? String)
        XCTAssertEqual(shown, "The coding agent wants: send this answer to the agent: “only change the tests”",
                       "the wearer sees what is about to leave the device, attributed")
        XCTAssertNil(service.pendingQuestion)
    }

    /// The boundary, not the wording: a model-proposed answer only leaves the device if it comes
    /// back out of the user-originated prompt — and what comes back is what is sent.
    func testAnEditedAnswerIsTheOneThatIsSent() async throws {
        let question = AgentQuestion(id: "q7", revision: 0, kind: .freeText,
                                     prompt: "Which files?", runID: "r1")
        let service = waitingSession(askingConfig(), question: question)
        MockURLProtocol.reset()
        service.requestUserText = { _, _ in "only the tests, not the README" }

        _ = await service.answerPendingQuestionViaUserPrompt(text: "change everything")
        XCTAssertEqual(try body(of: 0)["reply"] as? String, "only the tests, not the README")
    }

    func testDecliningTheTextPromptSendsNothing() async {
        let question = AgentQuestion(id: "q7", revision: 0, kind: .freeText,
                                     prompt: "Which files?", runID: "r1")
        let service = waitingSession(askingConfig(), question: question)
        MockURLProtocol.reset()
        service.requestUserText = { _, _ in nil }

        let line = await service.answerPendingQuestionViaUserPrompt(text: "whatever you like")
        XCTAssertEqual(line, "Okay, I didn't send an answer.")
        XCTAssertEqual(MockURLProtocol.requests.count, 0)
        XCTAssertNotNil(service.pendingQuestion, "unanswered means still pending")
    }

    /// Ordinary speech must never stand in for permission.
    func testAnApprovalQuestionRefusesAFreeTextAnswer() async {
        let question = AgentQuestion(id: "q1", revision: 0,
                                     kind: .approval(actionSummary: "push to main"),
                                     prompt: "Push to main?", runID: "r1")
        let service = waitingSession(askingConfig(), question: question)
        MockURLProtocol.reset()
        var asked = false
        service.requestUserText = { _, _ in asked = true; return "go on then" }

        let line = await service.answerPendingQuestionViaUserPrompt(text: "go on then")
        XCTAssertEqual(line, "That one's a confirmation, not a question — say confirm or deny.")
        XCTAssertFalse(asked)
        XCTAssertEqual(MockURLProtocol.requests.count, 0)
        XCTAssertNotNil(service.pendingQuestion)
    }

    func testFreeTextWithoutTheUserPromptSeamSendsNothing() async {
        let question = AgentQuestion(id: "q7", revision: 0, kind: .freeText,
                                     prompt: "Which files?", runID: "r1")
        let service = waitingSession(askingConfig(), question: question)
        MockURLProtocol.reset()
        service.requestUserText = nil

        let line = await service.answerPendingQuestionViaUserPrompt(text: "the tests")
        XCTAssertTrue(line.contains("nothing was sent"), "got: \(line)")
        XCTAssertEqual(MockURLProtocol.requests.count, 0)
    }

    func testApprovalAndDenialCarryTheirOwnDecisions() async throws {
        let question = AgentQuestion(id: "q1", revision: 0,
                                     kind: .approval(actionSummary: "push to main"),
                                     prompt: "Push to main?", runID: "r1")

        let approving = waitingSession(askingConfig(), question: question)
        MockURLProtocol.reset()
        approving.requestUserConsent = { _ in true }
        let approvedLine = await approving.confirmPendingActionViaUserPrompt()
        XCTAssertEqual(approvedLine, "Okay, proceeding.")
        XCTAssertEqual(try body(of: 0)["decision"] as? String, "approve")
        XCTAssertNil(try body(of: 0)["reply"], "an approval carries no words")
        XCTAssertEqual(approving.activeRun?.status, .running)

        let denying = waitingSession(askingConfig(), question: question)
        MockURLProtocol.reset()
        denying.requestUserConsent = { _ in false }
        let deniedLine = await denying.confirmPendingActionViaUserPrompt()
        XCTAssertEqual(deniedLine, "I've told the agent not to proceed.")
        XCTAssertEqual(try body(of: 0)["decision"] as? String, "deny")
        XCTAssertNotEqual(denying.activeRun?.status, .cancelled,
                          "the endpoint reports whether the run stopped; we don't")
    }

    /// The consent prompt is the only thing that can say yes. Without it, nothing is approved.
    func testApprovalWithoutTheConsentSeamApprovesNothing() async {
        let question = AgentQuestion(id: "q1", revision: 0,
                                     kind: .approval(actionSummary: "push"),
                                     prompt: "Push?", runID: "r1")
        let service = waitingSession(askingConfig(), question: question)
        MockURLProtocol.reset()
        service.requestUserConsent = nil

        let line = await service.confirmPendingActionViaUserPrompt()
        XCTAssertTrue(line.contains("nothing was approved"), "got: \(line)")
        XCTAssertEqual(MockURLProtocol.requests.count, 0)
    }

    // MARK: - Unsupported replies

    func testAnEndpointWithNoAnswerAddressSaysSoAndSendsNothing() async {
        let question = AgentQuestion(id: "q1", revision: 0, kind: .freeText,
                                     prompt: "Which files?", runID: "r1")
        let service = waitingSession(legacyConfig(), question: question)
        MockURLProtocol.reset()
        service.requestUserText = { _, draft in draft }

        let line = await service.answerPendingQuestionViaUserPrompt(text: "only the tests")
        XCTAssertEqual(line, "This agent can't take a typed answer, so I didn't send it.")
        XCTAssertEqual(service.lastReplyOutcome, .unsupported)
        XCTAssertEqual(MockURLProtocol.requests.count, 0, "nothing is sent when nothing can be")
        XCTAssertNotNil(service.pendingQuestion, "the question is still unanswered")
        XCTAssertNil(service.pendingReply, "a retry could only fail the same way")
    }

    func testAnUnrelayableDeclineDoesNotClaimTheRunStopped() async {
        let question = AgentQuestion(id: "q1", revision: 0,
                                     kind: .approval(actionSummary: "push"),
                                     prompt: "Push?", runID: "r1")
        let service = waitingSession(legacyConfig(), question: question)
        MockURLProtocol.reset()
        service.requestUserConsent = { _ in false }

        let line = await service.confirmPendingActionViaUserPrompt()
        XCTAssertEqual(line, "This agent has no way to relay a decline, so I couldn't tell it to stop.")
        XCTAssertEqual(service.activeRun?.status, .awaitingInput,
                       "the status stays whatever the endpoint last reported")
        XCTAssertFalse(service.declineAwaitingEndpoint)
    }

    /// The gateway answers approvals on its own surface, which is owned by another plan. Until it
    /// is wired, saying so is the correct behaviour — not accepting the answer silently.
    func testTheGatewayHarnessReportsRepliesAsUnsupported() async {
        let gateway = OpenClawAgentHarness(send: { _, _ in [:] }, configured: { true })
        let run = AgentRun(id: "r", harness: .openclaw, prompt: "p", project: nil,
                           status: .awaitingInput, startedAt: fixedNow)
        do {
            try await gateway.respondToInput(run, reply: AgentReply(questionID: "q", revision: 0,
                                                                    body: .approve, runID: "r"))
            XCTFail("expected a throw")
        } catch let error as AgentHarnessError {
            XCTAssertEqual(error, .replyUnsupported(.approve))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// The protocol's own default: a harness that says nothing about replies relays nothing, and
    /// says so. It used to be a no-op, which looked exactly like success.
    func testTheDefaultHarnessImplementationRefusesRatherThanNoOp() async {
        let stub = SilentHarness()
        do {
            try await stub.respondToInput(
                AgentRun(id: "r", harness: .custom, prompt: "p", project: nil, startedAt: fixedNow),
                reply: AgentReply(questionID: "q", revision: 0, body: .text("hi"), runID: "r"))
            XCTFail("expected a throw")
        } catch let error as AgentHarnessError {
            XCTAssertEqual(error, .replyUnsupported(.text("hi")))
            XCTAssertEqual(error.errorDescription, "This agent can't take a typed answer.")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Transport truth

    func testAFailedReplyKeepsTheQuestionPendingAndRetriesTheSameReply() async throws {
        let question = AgentQuestion(id: "q1", revision: 0,
                                     kind: .approval(actionSummary: "push"),
                                     prompt: "Push?", runID: "r1")
        let service = waitingSession(askingConfig(), question: question)
        MockURLProtocol.reset()
        MockURLProtocol.script = [.http(503)]
        service.requestUserConsent = { _ in true }

        let failed = await service.confirmPendingActionViaUserPrompt()
        XCTAssertEqual(failed, "The agent endpoint refused your answer (HTTP 503) — say retry to try again.")
        XCTAssertEqual(service.lastReplyOutcome, .failed)
        XCTAssertNotNil(service.pendingQuestion, "the question is still unanswered")
        XCTAssertEqual(service.activeRun?.status, .awaitingInput)
        XCTAssertFalse(service.spokenLog.contains("Okay, proceeding."),
                       "a reply that never arrived must not be announced as success")
        let firstReplyID = try XCTUnwrap(try body(of: 0)["replyId"] as? String)

        MockURLProtocol.script = [.json("{}")]
        let retried = await service.retryPendingReply()
        XCTAssertEqual(retried, "Okay, proceeding.")
        XCTAssertEqual(service.lastReplyOutcome, .delivered)
        XCTAssertEqual(try body(of: 1)["replyId"] as? String, firstReplyID,
                       "the same answer, so an endpoint that already applied it can say so")
        XCTAssertNil(service.pendingQuestion)
    }

    func testUncertainDeliveryIsReconciledByPollingStatusNotByPostingAgain() async {
        let question = AgentQuestion(id: "q1", revision: 0,
                                     kind: .approval(actionSummary: "push"),
                                     prompt: "Push?", runID: "r1")
        let service = waitingSession(askingConfig(), question: question)
        MockURLProtocol.reset()
        // The POST times out; the status GET that follows shows the run has moved on.
        MockURLProtocol.script = [.timeout, .json(#"{"status":"running"}"#)]
        service.requestUserConsent = { _ in true }

        let line = await service.confirmPendingActionViaUserPrompt()

        XCTAssertEqual(line, "Okay, proceeding.")
        XCTAssertEqual(service.lastReplyOutcome, .delivered)
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
        XCTAssertEqual(MockURLProtocol.requests[0].request.httpMethod, "POST")
        XCTAssertEqual(MockURLProtocol.requests[1].request.httpMethod, "GET",
                       "reconcile by asking where the run stands — never by applying the effect twice")
        XCTAssertEqual(MockURLProtocol.requests[1].request.url?.absoluteString,
                       "https://agent.test/runs/r1")
    }

    func testUncertainDeliveryThatStaysUnresolvedKeepsTheQuestion() async {
        let question = AgentQuestion(id: "q1", revision: 0,
                                     kind: .approval(actionSummary: "push"),
                                     prompt: "Push?", runID: "r1")
        let service = waitingSession(askingConfig(), question: question)
        MockURLProtocol.reset()
        MockURLProtocol.script = [.timeout, .json(#"{"status":"awaiting_input"}"#)]
        service.requestUserConsent = { _ in true }

        let line = await service.confirmPendingActionViaUserPrompt()

        XCTAssertEqual(line, "I couldn't tell whether the agent got your answer, and it's still waiting — say retry to send it again.")
        XCTAssertEqual(service.lastReplyOutcome, .uncertain)
        XCTAssertTrue(service.lastReplyOutcome?.isRetryable ?? false)
        XCTAssertNotNil(service.pendingQuestion)
        XCTAssertEqual(MockURLProtocol.requests.filter { $0.request.httpMethod == "POST" }.count, 1,
                       "exactly one send: a blind resend could apply the same answer twice")
    }

    // MARK: - Stale answers

    func testAnAnswerToAReplacedQuestionIsRefusedAndNeverForwarded() async {
        let service = waitingSession(askingConfig(),
                                     question: AgentQuestion(id: "q1", revision: 0,
                                                             kind: .approval(actionSummary: "push"),
                                                             prompt: "Push?", runID: "r1"))
        service.handle(.awaitingInput(AgentQuestion(id: "q2", revision: 0,
                                                    kind: .approval(actionSummary: "tag"),
                                                    prompt: "Tag the release?", runID: "r1")))
        MockURLProtocol.reset()

        let line = await service.answer(.approve, questionID: "q1", revision: 0)
        XCTAssertEqual(line, AgentSessionService.staleLine)
        XCTAssertEqual(service.lastReplyOutcome, .stale)
        XCTAssertEqual(MockURLProtocol.requests.count, 0)
        XCTAssertEqual(service.pendingQuestion?.id, "q2", "the live question is untouched")
    }

    func testAnAnswerToAnEarlierRevisionIsAlsoStale() async {
        let service = waitingSession(askingConfig(),
                                     question: AgentQuestion(id: "q1", revision: 2, kind: .freeText,
                                                             prompt: "Which files?", runID: "r1"))
        MockURLProtocol.reset()
        let line = await service.answer(.text("the tests"), questionID: "q1", revision: 1)
        XCTAssertEqual(line, AgentSessionService.staleLine)
        XCTAssertEqual(MockURLProtocol.requests.count, 0)
    }

    func testAnswersAfterTheRunEndsAreRefused() async {
        let service = waitingSession(askingConfig(),
                                     question: AgentQuestion(id: "q1", revision: 0,
                                                             kind: .approval(actionSummary: "push"),
                                                             prompt: "Push?", runID: "r1"))
        service.handle(.completed(AgentRunResult()))
        MockURLProtocol.reset()

        service.requestUserConsent = { _ in true }
        let line = await service.confirmPendingActionViaUserPrompt()
        XCTAssertEqual(line, "There's nothing waiting for confirmation.")
        XCTAssertEqual(MockURLProtocol.requests.count, 0)
        XCTAssertNil(service.pendingQuestion)
    }

    func testCancellingWhileAQuestionIsPendingClearsItAndCancelsAtTheEndpoint() async {
        let service = waitingSession(askingConfig(),
                                     question: AgentQuestion(id: "q1", revision: 0,
                                                             kind: .freeText, prompt: "Which files?",
                                                             runID: "r1"))
        MockURLProtocol.reset()
        await service.cancel()

        XCTAssertEqual(service.activeRun?.status, .cancelled)
        XCTAssertNil(service.pendingQuestion)
        XCTAssertNil(service.pendingReply)
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(MockURLProtocol.requests[0].request.url?.absoluteString,
                       "https://agent.test/runs/r1/cancel")
    }

    // MARK: - Backend binding and explicit agent selection

    func testTheAgentFieldRidesTheStartBodyOnlyWhenBothHalvesAreSet() throws {
        var config = askingConfig()
        config.agentField = "agent"
        config.agentValue = "reviewer"
        let request = try XCTUnwrap(config.startRequest(prompt: "p", project: "repo"))
        let sent = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                                    as? [String: Any])
        XCTAssertEqual(sent["agent"] as? String, "reviewer")

        var halfSet = askingConfig()
        halfSet.agentField = "agent"
        let plain = try XCTUnwrap(halfSet.startRequest(prompt: "p", project: nil))
        let plainBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(plain.httpBody))
                                        as? [String: Any])
        XCTAssertNil(plainBody["agent"], "a field with no value names nothing")
    }

    /// Settings can be edited at any moment. A reply belongs to the endpoint that asked the
    /// question, not to whatever is configured by the time the wearer answers.
    func testAReplyGoesToTheBackendTheRunWasDispatchedTo() async throws {
        var bound = askingConfig(host: "https://first.test")
        bound.statusURLTemplate = ""        // no polling: this test is about where the reply goes
        MockURLProtocol.reset()
        MockURLProtocol.script = [.json(#"{"id":"r1","status":"running"}"#)]

        let service = AgentSessionService()
        service.speak = { _ in }
        service.configure(registry: AgentHarnessRegistry([harness(bound)]), speak: { _ in })
        guard case .success = await service.dispatch(prompt: "p", project: nil) else {
            return XCTFail("dispatch should succeed")
        }
        XCTAssertEqual(service.boundHarnessKind, .custom)
        await drainEvents(service)

        // The wearer edits the endpoint in Settings mid-run.
        service.setRegistry(AgentHarnessRegistry([harness(askingConfig(host: "https://second.test"))]))

        service.handle(.awaitingInput(AgentQuestion(id: "q1", revision: 0, kind: .freeText,
                                                    prompt: "Which files?", runID: "r1")))
        service.requestUserText = { _, draft in draft }
        _ = await service.answerPendingQuestionViaUserPrompt(text: "the tests")

        let replies = MockURLProtocol.requests.filter { $0.request.httpMethod == "POST"
            && $0.request.url?.path.hasSuffix("/input") == true }
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].request.url?.absoluteString, "https://first.test/runs/r1/input",
                       "a settings change must not redirect an answer to another backend")
    }

    // MARK: - Field collisions

    func testCollidingBodyKeysAreReportedAndTheRequestIsRefused() {
        var config = askingConfig()
        config.projectField = "prompt"          // same key as the prompt
        let issue = config.fieldCollisionIssue
        XCTAssertNotNil(issue)
        XCTAssertTrue(issue?.contains("prompt") ?? false, "got: \(issue ?? "nil")")
        XCTAssertNil(config.startRequest(prompt: "p", project: "repo"),
                     "a body with a silently-overwritten field is not sent")
        XCTAssertNil(config.inputRequest(runID: "r1",
                                         reply: AgentReply(questionID: "q", revision: 0,
                                                           body: .approve, runID: "r1")))
    }

    func testTheAgentFieldIsCheckedForCollisionsToo() {
        var config = askingConfig()
        config.agentField = "project"
        config.agentValue = "reviewer"
        XCTAssertNotNil(config.fieldCollisionIssue)

        config.agentField = "agent"
        XCTAssertNil(config.fieldCollisionIssue)
    }

    func testTheAnswerFieldMayNotTakeAReservedReplyKey() {
        var config = askingConfig()
        for reserved in CustomHarnessConfig.reservedReplyKeys {
            config.inputField = reserved
            XCTAssertNotNil(config.fieldCollisionIssue, "“\(reserved)” must be refused")
        }
        config.inputField = ""
        XCTAssertNotNil(config.fieldCollisionIssue, "a reply needs a key to ride in")
        config.inputField = "answer"
        XCTAssertNil(config.fieldCollisionIssue)
        XCTAssertTrue(config.acceptsReplies)
    }

    func testAnEmptyAnswerFieldOnlyMattersWhenThereIsAnAnswerAddress() {
        var config = legacyConfig()
        config.inputField = ""
        XCTAssertNil(config.fieldCollisionIssue, "nothing to answer, nothing to validate")
        XCTAssertFalse(config.acceptsReplies)
    }

    // MARK: - Config migration (actual saved JSON)

    func testLegacySavedConfigJSONDecodesWithTheNewDefaults() throws {
        // Exactly what a build before Plan FE P1 wrote to the Keychain: P0's result paths, and no
        // agent-selection or question/answer keys at all.
        let legacy = """
        {"name":"My Agent","startURL":"https://agent.test/start",
         "statusURLTemplate":"https://agent.test/runs/{id}","cancelURLTemplate":"",
         "authHeader":"Authorization","authValue":"Bearer tok","promptField":"prompt",
         "projectField":"project","imageField":"","idPath":"data.id","statusPath":"data.state",
         "finalTextPath":"result.summary","filesCreatedPath":"result.filesCreated",
         "filesModifiedPath":"","commandsRunPath":"","pushedPath":"","prURLPath":"",
         "errorPath":"result.error"}
        """
        let config = try JSONDecoder().decode(CustomHarnessConfig.self, from: Data(legacy.utf8))

        XCTAssertEqual(config.authValue, "Bearer tok", "the token must survive the migration")
        XCTAssertEqual(config.finalTextPath, "result.summary", "P0's mapping is untouched")
        XCTAssertEqual(config.agentField, "")
        XCTAssertEqual(config.agentValue, "")
        XCTAssertEqual(config.inputURLTemplate, "")
        XCTAssertEqual(config.inputField, "reply", "a usable default, not an empty one")
        XCTAssertEqual(config.questionPromptPath, "")
        XCTAssertEqual(config.questionIDPath, "")
        XCTAssertEqual(config.questionRevisionPath, "")
        XCTAssertEqual(config.questionKindPath, "")
        XCTAssertFalse(config.acceptsReplies)
        XCTAssertFalse(config.mapsAnyQuestionField)
        XCTAssertNil(config.fieldCollisionIssue)
        XCTAssertTrue(config.isConfigured, "a decoding change must never disable a working endpoint")
    }

    func testANewConfigRoundTripsWithItsQuestionMapping() throws {
        var original = askingConfig()
        original.agentField = "agent"
        original.agentValue = "reviewer"
        let decoded = try JSONDecoder().decode(CustomHarnessConfig.self,
                                               from: try JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.acceptsReplies)
        XCTAssertTrue(decoded.mapsAnyQuestionField)
    }

    func testThePresetsStillDecodeAndCarryNoAnswerAddress() {
        for config in [AgentHarnessPreset.codexCloud(token: "tok"),
                       AgentHarnessPreset.claudeRemote(token: "tok")] {
            XCTAssertTrue(config.isConfigured)
            XCTAssertNil(config.fieldCollisionIssue)
            XCTAssertFalse(config.acceptsReplies, "the presets gained no reply channel")
            XCTAssertEqual(config.agentField, "")
        }
    }

    // MARK: - The voice/UI reply actually reaching the adapter

    func testTheToolsAnswerActionReachesTheAdapterThroughTheUserPrompt() async throws {
        let shared = AgentSessionService.shared
        let savedRegistry = shared.registry
        defer { if let savedRegistry { shared.setRegistry(savedRegistry) } }

        MockURLProtocol.reset()
        shared.setRegistry(AgentHarnessRegistry([harness(askingConfig())]))
        shared.setHarness(harness(askingConfig()))
        shared.speak = { _ in }
        shared.handle(.started(AgentRun(id: "r1", harness: .custom, prompt: "p", project: "repo",
                                        status: .running, startedAt: fixedNow)))
        shared.handle(.awaitingInput(AgentQuestion(id: "q9", revision: 1, kind: .freeText,
                                                   prompt: "Which files?", runID: "r1")))
        var prompted = false
        shared.requestUserText = { _, draft in prompted = true; return draft }

        let out = try await AgentControlTool().execute(
            args: ["action": "answer", "text": "only change the tests"])

        XCTAssertEqual(out, "Sent your answer to the agent.")
        XCTAssertTrue(prompted, "a model-issued answer still goes through the wearer's own prompt")
        XCTAssertEqual(MockURLProtocol.requests.count, 1)
        XCTAssertEqual(MockURLProtocol.requests[0].request.url?.absoluteString,
                       "https://agent.test/runs/r1/input")
        XCTAssertEqual(try body(of: 0)["reply"] as? String, "only change the tests")
        XCTAssertEqual(try body(of: 0)["questionId"] as? String, "q9")
        shared.handle(.completed(AgentRunResult()))
    }

    func testTheToolsConfirmActionCannotApproveWithoutTheWearer() async throws {
        let shared = AgentSessionService.shared
        let savedRegistry = shared.registry
        defer { if let savedRegistry { shared.setRegistry(savedRegistry) } }

        MockURLProtocol.reset()
        shared.setHarness(harness(askingConfig()))
        shared.speak = { _ in }
        shared.handle(.started(AgentRun(id: "r1", harness: .custom, prompt: "p", project: "repo",
                                        status: .running, startedAt: fixedNow)))
        shared.handle(.awaitingInput(AgentQuestion(id: "q1", revision: 0,
                                                   kind: .approval(actionSummary: "push to main"),
                                                   prompt: "Push?", runID: "r1")))
        var askedSummary: String?
        shared.requestUserConsent = { request in
            askedSummary = request.attributedSummary
            return false                                  // the wearer says no at the card
        }

        let out = try await AgentControlTool().execute(args: ["action": "confirm"])

        XCTAssertEqual(out, "I've told the agent not to proceed.")
        XCTAssertEqual(askedSummary, "The coding agent wants: push to main")
        XCTAssertEqual(try body(of: 0)["decision"] as? String, "deny",
                       "the tool call raised the prompt; the wearer's answer is what was sent")
        shared.handle(.completed(AgentRunResult()))
        shared.requestUserConsent = nil
    }

    func testTheToolsRetryActionResendsTheSameAnswer() async throws {
        let shared = AgentSessionService.shared
        MockURLProtocol.reset()
        MockURLProtocol.script = [.networkFailure, .json("{}")]
        shared.setHarness(harness(askingConfig()))
        shared.speak = { _ in }
        shared.handle(.started(AgentRun(id: "r1", harness: .custom, prompt: "p", project: "repo",
                                        status: .running, startedAt: fixedNow)))
        shared.handle(.awaitingInput(AgentQuestion(id: "q1", revision: 0,
                                                   kind: .approval(actionSummary: "push"),
                                                   prompt: "Push?", runID: "r1")))
        shared.requestUserConsent = { _ in true }

        let failed = try await AgentControlTool().execute(args: ["action": "confirm"])
        XCTAssertTrue(failed.contains("retry"), "got: \(failed)")

        let retried = try await AgentControlTool().execute(args: ["action": "retry"])
        XCTAssertEqual(retried, "Okay, proceeding.")
        XCTAssertEqual(try body(of: 0)["replyId"] as? String, try body(of: 1)["replyId"] as? String)
        shared.handle(.completed(AgentRunResult()))
        shared.requestUserConsent = nil
    }

    func testTheToolReportsThereIsNothingToAnswerOrRetry() async throws {
        let shared = AgentSessionService.shared
        shared.speak = { _ in }
        shared.handle(.completed(AgentRunResult()))

        let noText = try await AgentControlTool().execute(args: ["action": "answer"])
        XCTAssertEqual(noText, "What should I tell the agent?")
        let nothing = try await AgentControlTool().execute(args: ["action": "answer", "text": "hi"])
        XCTAssertEqual(nothing, "There's nothing waiting for an answer.")
        let noRetry = try await AgentControlTool().execute(args: ["action": "retry"])
        XCTAssertEqual(noRetry, "There's no answer waiting to be re-sent.")
    }

    /// Answering and retrying raise the wearer's own prompt themselves, so they are not in the
    /// high-impact set — gating them would put two prompts in front of one answer.
    func testAnsweringIsNotItselfAConfirmationGatedAction() {
        for action in ["answer", "retry"] {
            XCTAssertFalse(PromptInjectionPolicy.isHighImpact(toolName: "code_agent",
                                                             args: ["action": action]))
        }
        XCTAssertTrue(PromptInjectionPolicy.isHighImpact(toolName: "code_agent",
                                                        args: ["action": "start", "prompt": "x"]))
    }

    // MARK: - The touch alternative

    func testTheConsentCardCollectsATypedAnswerWhenVoiceIsUnavailable() async {
        let coordinator = ToolConfirmationCoordinator()
        async let answer = coordinator.requestTextAnswer(
            toolName: "code_agent", summary: "send this answer to the agent: “the tests”",
            source: .codingAgent, prefill: "the tests")

        await waitForPending(coordinator)
        XCTAssertEqual(coordinator.pending?.reply, .text(prefill: "the tests"))
        // Voice is unavailable, so the wearer edits and taps Send.
        XCTAssertFalse(coordinator.resolveByVoice("yes"),
                       "“yes” is not an answer to a question that wants words")
        coordinator.resolveText("only the tests")

        let result = await answer
        XCTAssertEqual(result, "only the tests")
        XCTAssertNil(coordinator.pending)
    }

    func testDecliningTheTextCardReturnsNothing() async {
        let coordinator = ToolConfirmationCoordinator()
        async let answer = coordinator.requestTextAnswer(
            toolName: "code_agent", summary: "send this", source: .codingAgent, prefill: "x")
        await waitForPending(coordinator)
        coordinator.resolve(false)
        let result = await answer
        XCTAssertNil(result)
    }

    /// The approve/deny card is unchanged: a typed string cannot stand in for a yes.
    func testAnApprovalCardIgnoresTypedText() async {
        let coordinator = ToolConfirmationCoordinator()
        async let approved = coordinator.requestConfirmation(
            toolName: "code_agent", summary: "push to main", source: .codingAgent)
        await waitForPending(coordinator)
        XCTAssertEqual(coordinator.pending?.reply, .approval)
        coordinator.resolveText("yes please")
        XCTAssertNotNil(coordinator.pending, "a text resolution must not answer an approval")
        coordinator.resolve(true)
        let result = await approved
        XCTAssertTrue(result)
    }

    private func waitForPending(_ coordinator: ToolConfirmationCoordinator) async {
        for _ in 0..<200 where coordinator.pending == nil {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

/// A harness that declares no reply channel — it takes the protocol's default.
private struct SilentHarness: AgentHarness {
    let kind: AgentHarnessKind = .custom
    var displayName: String { "Silent" }
    var isConfigured: Bool { true }
    func start(prompt: String, project: String?) async throws -> AgentRun {
        AgentRun(id: "s", harness: kind, prompt: prompt, project: project, startedAt: Date())
    }
    func events(for run: AgentRun) -> AsyncStream<AgentEvent> { AsyncStream { $0.finish() } }
    func status(_ run: AgentRun) async throws -> AgentRunStatus { run.status }
    func cancel(_ run: AgentRun) async throws {}
}
