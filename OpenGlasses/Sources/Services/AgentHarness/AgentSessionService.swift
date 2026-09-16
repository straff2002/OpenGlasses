import Foundation
import Combine

/// Drives a remote agent run (Plan N): dispatches to the active `AgentHarness`, aggregates its
/// normalized event stream into an `AgentRunResult`, narrates key moments and the final summary via
/// TTS, and gates `awaitingInput` confirmations. Harness-agnostic — it works entirely in
/// `AgentEvent`/`AgentRunResult`, so swapping harnesses changes nothing here.
///
/// `speak` is injected (AppState wires TTS; tests capture), and the event-handling state machine is
/// exposed as `handle(_:)` so transitions are unit-testable without a live stream.
@MainActor
final class AgentSessionService: ObservableObject {
    static let shared = AgentSessionService()

    @Published private(set) var activeRun: AgentRun?
    @Published private(set) var result = AgentRunResult()
    @Published private(set) var lastSummary: String?

    /// The question the run is waiting on, with its identity (Plan FE P1). Replaces a bare prompt
    /// string, which could neither recognise a repeat nor tell two identically-worded questions
    /// apart.
    @Published private(set) var pendingQuestion: AgentQuestion?
    /// The reply the wearer authorised but we have not confirmed delivery of. Held so a retry
    /// re-sends the *same* reply — same id, same body — rather than asking again.
    @Published private(set) var pendingReply: AgentReply?
    /// How the last reply attempt ended. `nil` once a reply is confirmed delivered.
    @Published private(set) var lastReplyOutcome: AgentReplyOutcome?
    /// A decline we relayed and the endpoint has not yet acted on. The run is not ours to call
    /// stopped: we know only that we said no.
    @Published private(set) var declineAwaitingEndpoint = false

    /// The pending question's text, for callers that only want the words.
    var awaitingInputPrompt: String? { pendingQuestion?.prompt }
    /// Everything spoken this session, in order — for the debug panel and tests.
    @Published private(set) var spokenLog: [String] = []

    /// Whether we can still *observe* the run (Plan FE P0). Separate from `activeRun.status` on
    /// purpose: losing the endpoint tells us nothing about the run, so it changes this and leaves
    /// the run's last known status exactly where it was.
    @Published private(set) var connectionState: AgentConnectionState = .idle
    /// When contact was lost, for the "agent status" answer.
    @Published private(set) var contactLostAt: Date?

    /// How each report of this run's outcome reached the wearer (Plan FE P4), newest last. One
    /// record per result revision; a repeated identical terminal report adds none.
    @Published private(set) var deliveries: [AgentResultDelivery] = []

    /// The most recent delivery record — what "agent status" and a replay act on.
    ///
    /// Falls back to the persisted store, which is the whole point of the crash window: after a
    /// relaunch there is nothing in memory, and "no record" would read as "nothing was ever
    /// delivered". Scoped to the active run when there is one, so a previous run's record can
    /// never describe the current one.
    var latestDelivery: AgentResultDelivery? {
        if let last = deliveries.last { return last }
        guard let runID = activeRun?.id else { return deliveryStore?.mostRecent }
        return deliveryStore?.latest(forRun: runID)
    }

    /// Injected clock so the contact-lost timestamp is deterministic in tests.
    var now: () -> Date = Date.init

    /// Injected sleeper for acknowledgement backoff, so a retry test does not wait out the ladder.
    var sleeper: (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// Bounded retry/backoff for the acknowledgement, shared with polling (Plan FE P0/P4).
    var policy: AgentPollingPolicy = .default

    /// A directly-set harness (tests/back-compat). When a `registry` is present it takes precedence,
    /// so a default-harness change in Settings applies without re-dispatching.
    private(set) var harness: AgentHarness?

    /// The harness registry (Phase 2). When set, `dispatch` uses its `active` harness.
    private(set) var registry: AgentHarnessRegistry?

    /// Injected speaker for narration — progress lines, questions, reply outcomes. Fire and
    /// forget, which is the right shape for a line whose delivery nobody is going to act on.
    var speak: (String) -> Void = { _ in }

    /// Injected speaker that **reports how playback ended** (Plan FE P4). AppState wires
    /// `TextToSpeechService.speakReporting`; tests script an outcome.
    ///
    /// Only the final result summary goes through it, because the result is the one thing a wearer
    /// dispatched work to hear. When it is `nil` the summary is spoken through `speak` exactly as
    /// before and **no delivery record is written**: a record saying `completed` on the strength of
    /// a closure that returns `Void` would be the same false claim in a new place.
    var speakResult: ((String) async -> SpeechDeliveryOutcome)?

    /// Where delivery records survive a relaunch. `nil` keeps them in memory only (tests that do
    /// not exercise the crash window); AppState wires the shared store.
    var deliveryStore: AgentDeliveryRecordStore?

    /// User-distinct consent seam (BN P1): wired by AppState to the shared consent surface
    /// (`ToolConfirmationCoordinator`); tests inject grants/denials. When nil, a tool-called
    /// confirm fails CLOSED — approval must come from a real user prompt, never from tool-call
    /// output (the prompt-injection → self-approved-push hole).
    var requestUserConsent: ((RemoteActionConsentRequest) async -> Bool)?

    /// The free-text half of the same user-originated boundary (Plan FE P1): shows the answer the
    /// wearer is about to send and hands back what they confirmed — edited if they edited it, or
    /// `nil` if they decided not to send. Wired by AppState to the consent card's text field.
    /// Nil seam ⇒ nothing is sent, and the wearer is told why.
    var requestUserText: ((RemoteActionConsentRequest, String) async -> String?)?

    /// The harness a run was dispatched to, held for the life of that run (Plan FE P1).
    ///
    /// Settings can change the default backend, the endpoint URL or the selected agent at any
    /// moment. A reply or a cancellation belongs to the backend that started the run — sending it
    /// to whatever is configured *now* would answer a question a different endpoint never asked.
    private(set) var boundHarness: AgentHarness?

    /// Which backend the active run is bound to.
    var boundHarnessKind: AgentHarnessKind? { boundHarness?.kind }

    /// The harness this run's follow-up traffic must use.
    var runHarness: AgentHarness? { boundHarness ?? activeHarness }

    /// Questions already surfaced, by `(id, revision)`.
    private var announcedQuestions: Set<AgentQuestion.Identity> = []

    /// A fingerprint per delivered result revision, in order. Its `count` is the next revision
    /// number, and its last entry is what a repeated terminal report is compared against.
    private var deliveredFingerprints: [String] = []

    private var eventTask: Task<Void, Never>?
    /// The in-flight delivery (speak, then acknowledge). Awaited by `awaitDelivery()`.
    private var deliveryTask: Task<Void, Never>?

    /// Wait for the current result delivery — playback and acknowledgement — to settle.
    /// Exists for tests and for a caller that needs the record before acting on it.
    func awaitDelivery() async { await deliveryTask?.value }

    init() {}

    // MARK: - Configuration

    func configure(harness: AgentHarness, speak: @escaping (String) -> Void) {
        self.harness = harness
        self.speak = speak
    }

    /// Configure with a registry (Phase 2): the active harness is resolved per dispatch from the
    /// user's default, so adding/removing a Custom endpoint or switching the default takes effect live.
    func configure(registry: AgentHarnessRegistry, speak: @escaping (String) -> Void) {
        self.registry = registry
        self.speak = speak
    }

    func setHarness(_ harness: AgentHarness) { self.harness = harness }

    /// Swap the registry (e.g. after the user edits the Custom endpoint in Settings).
    func setRegistry(_ registry: AgentHarnessRegistry) { self.registry = registry }

    /// The harness a dispatch would use right now (registry default wins).
    var activeHarness: AgentHarness? { registry?.active ?? harness }

    // MARK: - Dispatch

    /// Plan CN: resolves the frame to attach, or nil. Wired by AppState to the pinned-or-live
    /// path (already privacy-filtered); tests inject. Nil seam ⇒ never attach.
    var resolveAttachment: ((AgentAttachmentPolicy.Decision) -> AgentTaskAttachment?)?

    /// Plan CN: the policy inputs AppState alone can answer (pin state, camera state).
    var attachmentContext: (() -> (pinHeld: Bool, pinAge: TimeInterval?, cameraStreaming: Bool))?

    @discardableResult
    func dispatch(prompt: String,
                  project: String?,
                  explicitAttach: Bool? = nil) async -> Result<AgentRun, AgentHarnessError> {
        // BK P0: dispatching a remote agent run is an autonomous action — gate it at the service
        // layer, not only at the tool layer (`AgentControlTool`). Latent today (its only caller is
        // tool-gated), but this is the gate-at-the-service-layer lesson the phase codifies.
        guard Config.agentModeEnabled else { return .failure(.agentModeOff) }
        guard let harness = activeHarness else { return .failure(.notConfigured(Config.defaultAgentHarness)) }
        guard harness.isConfigured else { return .failure(.notConfigured(harness.kind)) }

        // Plan CN: decide whether the wearer's view rides along, and tell the agent what it is
        // looking at. A skip is never an error — the task still goes, just without the picture.
        let context = attachmentContext?() ?? (pinHeld: false, pinAge: nil, cameraStreaming: false)
        let decision = AgentAttachmentPolicy.decide(
            settingEnabled: Config.agentVisionAttachmentEnabled,
            agentModeEnabled: Config.agentModeEnabled,
            hipaaMode: Config.hipaaMode,
            pinHeld: context.pinHeld,
            pinAge: context.pinAge,
            cameraStreaming: context.cameraStreaming,
            prompt: prompt,
            explicitAttach: explicitAttach,
            maxPinAge: Config.agentVisionAttachmentMaxPinAge)

        let attachment = resolveAttachment?(decision)
        let dispatchedPrompt = AgentAttachmentPhrasing.prompt(prompt, attaching: attachment?.source)
        if case .skip(let reason) = decision {
            PrivacyLog.agent(.session, .dispatchedWithoutFrame,
                             reason: PrivacyToken(reason.rawValue))
        }

        do {
            var run = try await harness.start(prompt: dispatchedPrompt, project: project,
                                              attachment: attachment)
            if run.status == .queued { run.status = .running }
            activeRun = run
            result = AgentRunResult()
            resetQuestionState()
            resetDeliveryState()
            lastSummary = nil
            connectionState = .connected
            contactLostAt = nil
            // Bind the backend to the run before anything can be asked of it.
            boundHarness = harness
            subscribe(to: run, on: harness)
            return .success(run)
        } catch let error as AgentHarnessError {
            return .failure(error)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    private func subscribe(to run: AgentRun, on harness: AgentHarness) {
        eventTask?.cancel()
        let stream = harness.events(for: run)
        eventTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    // MARK: - State machine (unit-tested directly)

    /// Fold one event into state: update the result tally, narrate if worthwhile, and advance the
    /// run's status (terminal events speak the final summary).
    func handle(_ event: AgentEvent) {
        result.apply(event)
        // A question decides for itself whether it is worth saying out loud, so it is handled
        // before the generic narration — which would announce every repeat.
        if case .awaitingInput(let question) = event {
            handleQuestion(question)
            return
        }
        if let line = AgentSummarizer.narration(for: event) {
            emit(line)
        }
        switch event {
        case .started(let run):
            // Establish (or refresh) the active run — authoritative start from the adapter. In the
            // normal flow `dispatch` already set it; this keeps the state machine self-contained.
            activeRun = run
        case .awaitingInput:
            break   // handled above
        case .completed:
            finish(status: .completed)
        case .failed:
            finish(status: .failed)
        case .cancelled:
            // A cancellation at the far end. It is not success, and it is not ours to claim.
            finish(status: .cancelled, cancellation: .remote)
        case .error:
            finish(status: .failed)
        case .connection(let state):
            handleConnection(state)
        case .progress, .fileCreated, .fileModified, .commandRun, .prOpened, .pushed, .assistantText:
            break
        }
    }

    /// Surface a question **once per identity** (Plan FE P1).
    ///
    /// The same question arriving on every poll is one question. A revision bump is the same
    /// question on changed terms, and is asked again. A new id is a new question even when it is
    /// worded exactly like the one before it — which is why text equality was never the right test.
    private func handleQuestion(_ question: AgentQuestion) {
        activeRun?.status = .awaitingInput
        let isNew = !announcedQuestions.contains(question.identity)
        if isNew {
            // A different question replaces the pending one: any reply still in hand was for the
            // old one and must not be sent against the new.
            if pendingQuestion?.identity != question.identity {
                pendingReply = nil
                lastReplyOutcome = nil
                declineAwaitingEndpoint = false
            }
            announcedQuestions.insert(question.identity)
            pendingQuestion = question
            emit(AgentSummarizer.cap(question.prompt))
        } else if pendingQuestion == nil {
            // Already announced, but we had cleared it (e.g. a delivered reply the endpoint has
            // not caught up with). Track it again without saying it twice.
            pendingQuestion = question
        }
    }

    private func resetQuestionState() {
        pendingQuestion = nil
        pendingReply = nil
        lastReplyOutcome = nil
        declineAwaitingEndpoint = false
        announcedQuestions.removeAll()
    }

    /// Connection changes never touch `activeRun.status`: whether the agent is working is the
    /// endpoint's fact to report, and once it stops answering we simply stop knowing.
    private func handleConnection(_ state: AgentConnectionState) {
        connectionState = state
        guard case .lost(let loss) = state else { return }
        contactLostAt = now()
        PrivacyLog.agent(.session, .contactLost, reason: PrivacyToken(loss.tokenName))
        emit(AgentSummarizer.line(for: loss))
        eventTask?.cancel()
        eventTask = nil
    }

    /// Reach a terminal state, and deliver the result **once per distinct result** (Plan FE P4).
    ///
    /// The dedupe is the reason this is not simply "speak the summary". An endpoint that keeps
    /// answering `completed` on every poll is reporting the same outcome repeatedly, not finishing
    /// repeatedly; before this, each repeat was a fresh narration. A report whose *fields* differ
    /// is a genuinely revised result and gets its own revision, its own delivery record and its own
    /// acknowledgement — even when the summary happens to come out word for word the same, because
    /// the acknowledgement names a revision and must not be allowed to stand in for another's
    /// contents.
    private func finish(status: AgentRunStatus,
                        cancellation: AgentSummarizer.CancellationOrigin = .remote) {
        activeRun?.status = status
        resetQuestionState()
        connectionState = .connected
        eventTask?.cancel()
        eventTask = nil

        let fingerprint = Self.fingerprint(result, status: status, cancellation: cancellation)
        if deliveredFingerprints.last == fingerprint {
            PrivacyLog.agent(.session, .resultDelivered, reason: PrivacyToken("duplicateSuppressed"),
                             count: deliveredFingerprints.count - 1)
            return
        }
        let summary = AgentSummarizer.summarize(result, status: status, cancellation: cancellation)
        lastSummary = summary
        let revision = deliveredFingerprints.count
        deliveredFingerprints.append(fingerprint)
        beginDelivery(of: summary, revision: revision)
    }

    /// The terminal report's identity: what was reported, plus how the run ended and who ended it.
    /// Cancellation origin is in it because "you cancelled this" and "the endpoint cancelled this"
    /// are different results even when the tallies match.
    private static func fingerprint(_ result: AgentRunResult, status: AgentRunStatus,
                                    cancellation: AgentSummarizer.CancellationOrigin) -> String {
        "\(status.rawValue)\u{1}\(cancellation)\u{1}\(result.deliveryFingerprint)"
    }

    private func resetDeliveryState() {
        deliveryTask?.cancel()
        deliveryTask = nil
        deliveries = []
        deliveredFingerprints = []
    }

    // MARK: - Result delivery (Plan FE P4)

    /// Hand one result revision to the speech service and record what becomes of it.
    ///
    /// The record is written **before** the utterance is requested, so a crash between the two
    /// leaves a `pending` record rather than no record — which is the difference between "we don't
    /// know whether you heard it" and "as far as this app is concerned it never happened".
    private func beginDelivery(of summary: String, revision: Int) {
        guard let runID = activeRun?.id, speakResult != nil else {
            // No reporting speaker (or no run to attribute it to): behave exactly as before and
            // write no record, rather than record a completion nothing observed.
            emit(summary)
            return
        }
        let record = AgentResultDelivery(runID: runID, resultRevision: revision,
                                         state: .pending, ackState: .pending, at: now())
        store(record)
        spokenLog.append(summary)
        deliveryTask = Task { @MainActor [weak self] in
            await self?.performDelivery(summary, record: record)
        }
    }

    private func performDelivery(_ line: String, record: AgentResultDelivery) async {
        var record = record
        record.state = .playing
        record.at = now()
        store(record)

        let outcome = await speakResult?(line) ?? .failed(reason: "no speaker")
        record.state = Self.state(for: outcome)
        record.at = now()
        PrivacyLog.agent(.session, .resultDelivered, reason: PrivacyToken(outcome.token),
                         count: record.resultRevision)
        store(record)
        await acknowledge(record)
    }

    private static func state(for outcome: SpeechDeliveryOutcome) -> AgentResultDelivery.State {
        switch outcome {
        case .completed:   return .completed
        case .interrupted: return .interrupted
        case .suppressed:  return .suppressed
        case .failed:      return .failed
        }
    }

    /// Record a delivery in memory and, when a store is wired, on disk.
    private func store(_ record: AgentResultDelivery) {
        if let index = deliveries.firstIndex(where: { $0.identity == record.identity }) {
            deliveries[index] = record
        } else {
            deliveries.append(record)
        }
        deliveryStore?.save(record)
    }

    // MARK: - Acknowledging a delivered result (Plan FE P4)

    /// Tell the run's **own** endpoint that this revision finished playing.
    ///
    /// Three rules hold this together, and each of them closes a way of lying:
    ///
    ///  * Only `completed` playback is acknowledged. A queued, suppressed or interrupted result
    ///    acknowledged as delivered would let an endpoint suppress re-delivery of something the
    ///    wearer never heard.
    ///  * The `ackID` is derived from `(run, revision)`, so every retry carries the same id and a
    ///    repeat is recognisable as one. Nothing else makes re-sending safe.
    ///  * **An acknowledgement failure never fails the task.** The delivery stays `completed`
    ///    locally and the record says why the endpoint was not told. Nothing is spoken about it:
    ///    the wearer heard their result, and the bookkeeping between two machines is not their
    ///    problem.
    private func acknowledge(_ record: AgentResultDelivery) async {
        var record = record
        guard !record.ackState.isAcknowledged else { return }
        guard let ack = AgentDeliveryAck.for(record) else {
            record.ackState = .unacknowledged(reason: .notCompleted)
            store(record)
            return
        }
        // The run's own backend, bound at dispatch — never whatever Settings points at now.
        guard let harness = runHarness, let run = activeRun else {
            record.ackState = .unacknowledged(reason: .unsupported)
            store(record)
            return
        }

        var failures = 0
        while true {
            guard isNewestRevision(record) else {
                // A newer result arrived while we were trying. Abandon this one rather than
                // acknowledge it late against a revision the endpoint has already moved past.
                record.ackState = .unacknowledged(reason: .superseded)
                store(record)
                return
            }
            do {
                try await harness.acknowledgeDelivery(run, ack: ack)
                record.ackState = .acknowledged
                PrivacyLog.agent(.session, .resultAcknowledged, count: record.resultRevision)
                store(record)
                return
            } catch AgentHarnessError.ackUnsupported {
                // Nobody asked to be told. Not a failure, and nothing to retry.
                record.ackState = .unacknowledged(reason: .unsupported)
                store(record)
                return
            } catch AgentHarnessError.http(let code) where !AgentPollingPolicy.isRetryable(httpStatus: code) {
                record.ackState = .unacknowledged(reason: .endpointRefused)
                PrivacyLog.agent(.session, .resultAckFailed, reason: PrivacyToken("endpointRefused"),
                                 error: .http(status: code))
                store(record)
                return
            } catch {
                failures += 1
                switch policy.decideAck(afterFailureCount: failures) {
                case .giveUp:
                    record.ackState = .unacknowledged(reason: .transport)
                    PrivacyLog.agent(.session, .resultAckFailed, reason: PrivacyToken("transport"),
                                     count: failures)
                    store(record)
                    return
                case .retry(_, let after):
                    await sleeper(after)
                }
            }
        }
    }

    private func isNewestRevision(_ record: AgentResultDelivery) -> Bool {
        record.resultRevision == max(0, deliveredFingerprints.count - 1)
    }

    // MARK: - Replay (Plan FE P4)

    /// Read the retained result out again.
    ///
    /// The point is the wearer who was talked over, or whose glasses were off, or who walked back
    /// in after a relaunch: the result still exists, and the only thing that changes is how
    /// honestly it is introduced. A delivery that was cut short or withheld is offered as one they
    /// missed; one already read in full is offered as a repeat; one whose fate the record cannot
    /// vouch for is hedged in both directions and never claimed either way.
    @discardableResult
    func replayLastResult() async -> String {
        guard let summary = lastSummary else {
            // A relaunch keeps the record and not the words — deliberately (see the store).
            if let reloaded = deliveryStore?.mostRecent, reloaded.deliveryIsAmbiguous {
                let line = AgentDeliveryPhrasing.ambiguousWithoutWords
                emit(line)
                return line
            }
            return AgentDeliveryPhrasing.nothingToReplay
        }
        guard var record = latestDelivery, speakResult != nil else {
            // No record kept (no reporting speaker wired): still replay the words, claim nothing.
            let line = AgentDeliveryPhrasing.againPrefix + summary
            emit(line)
            return line
        }

        let prefix: String
        if record.deliveryIsAmbiguous {
            prefix = AgentDeliveryPhrasing.ambiguousPrefix
        } else if record.owesReplay || record.state == .failed {
            prefix = AgentDeliveryPhrasing.missedPrefix
        } else {
            prefix = AgentDeliveryPhrasing.againPrefix
        }

        let line = prefix + summary
        spokenLog.append(line)
        PrivacyLog.agent(.session, .resultReplayed, reason: PrivacyToken(record.state.rawValue),
                         count: record.resultRevision)
        let outcome = await speakResult?(line) ?? .failed(reason: "no speaker")
        record.state = Self.state(for: outcome)
        record.at = now()
        record.reloaded = false     // we watched this one; it is no longer a guess off the disk
        store(record)
        await acknowledge(record)
        return line
    }

    /// Whether there is a retained result the wearer could ask to hear again.
    var canReplayResult: Bool {
        lastSummary != nil || deliveryStore?.mostRecent?.deliveryIsAmbiguous == true
    }

    // MARK: - Controls

    func cancel() async {
        // The run's own backend, never whatever Settings points at now.
        guard let harness = runHarness, let run = activeRun else { return }
        try? await harness.cancel(run)
        finish(status: .cancelled, cancellation: .local)
    }

    // MARK: - Answering the pending question (Plan FE P1)

    /// Entry for the `code_agent confirm` tool call (BN P1). The model's call is only a REQUEST
    /// to show the user-distinct consent prompt — a prompt-injected turn (web result, OCR'd sign,
    /// ambient caption) can raise the question, but never answer it.
    func confirmPendingActionViaUserPrompt() async -> String {
        guard let question = pendingQuestion, activeRun?.status == .awaitingInput else {
            return "There's nothing waiting for confirmation."
        }
        guard let requestUserConsent else {
            return "Approval needs the on-screen confirm prompt, which isn't available right now — nothing was approved."
        }
        let request = RemoteActionConsentRequest(source: .codingAgent, summary: question.actionSummary)
        let granted = await requestUserConsent(request)
        return await answer(granted ? .approve : .deny, to: question)
    }

    /// Entry for the `code_agent answer` tool call: the wearer's words, for a question that wants
    /// words rather than permission.
    ///
    /// It goes through the **same user-originated boundary** as an approval. The model proposing
    /// text does not make the text the wearer's, so the prompt shows what is about to be sent and
    /// forwards only what comes back from it — in full, edits included.
    func answerPendingQuestionViaUserPrompt(text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let question = pendingQuestion, activeRun?.status == .awaitingInput else {
            return "There's nothing waiting for an answer."
        }
        guard !question.kind.isApproval else {
            // An approval question is answered by approving it, at the consent prompt. Letting
            // arbitrary words stand in for a yes is precisely what must not happen.
            return "That one's a confirmation, not a question — say confirm or deny."
        }
        guard !trimmed.isEmpty else { return "What should I tell the agent?" }
        guard let requestUserText else {
            return "Sending an answer needs the on-screen prompt, which isn't available right now — nothing was sent."
        }
        let request = RemoteActionConsentRequest(
            source: .codingAgent,
            summary: "send this answer to the agent: “\(AgentSummarizer.cap(trimmed))”")
        guard let confirmed = await requestUserText(request, trimmed)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !confirmed.isEmpty else {
            return "Okay, I didn't send an answer."
        }
        return await answer(.text(confirmed), to: question)
    }

    /// Re-send the reply the wearer already authorised, after a failed or unconfirmed delivery.
    ///
    /// The same `AgentReply` goes back out — same id, same body — so an endpoint that already
    /// applied it can recognise the repeat. It is not a fresh authorisation and does not ask for
    /// one: the wearer approved this exact answer, and re-asking after every dropped packet would
    /// train them to approve without reading.
    func retryPendingReply() async -> String {
        guard let reply = pendingReply, let question = pendingQuestion, let run = activeRun else {
            return "There's no answer waiting to be re-sent."
        }
        guard reply.answers(question) else {
            pendingReply = nil
            return "That answer was for an earlier question, so I didn't re-send it."
        }
        return await deliver(reply, question: question, run: run)
    }

    /// Answer an `awaitingInput` confirmation. Kept for the boolean callers that predate the typed
    /// reply; approve/deny only.
    ///
    /// The grant must be user-originated: reach here via `confirmPendingActionViaUserPrompt`
    /// (tool path, coordinator-prompted) or a direct UI control — never straight from a model turn.
    @discardableResult
    func respondToConfirmation(approved: Bool) async -> String {
        guard let question = pendingQuestion, activeRun?.status == .awaitingInput else {
            return "There's nothing waiting for confirmation."
        }
        return await answer(approved ? .approve : .deny, to: question)
    }

    /// Answer a question named **explicitly** — the path a UI control takes, where the card was
    /// raised for one question and may be resolved after the run has moved on to another.
    ///
    /// An answer whose identity no longer matches the pending question is refused outright. It is
    /// not forwarded "just in case": approving a question that has been replaced approves whatever
    /// took its place.
    @discardableResult
    func answer(_ body: AgentReply.Body, questionID: AgentQuestion.ID, revision: Int) async -> String {
        guard let question = pendingQuestion, activeRun?.status == .awaitingInput else {
            lastReplyOutcome = .stale
            return Self.staleLine
        }
        guard question.id == questionID, question.revision == revision else {
            lastReplyOutcome = .stale
            return Self.staleLine
        }
        return await answer(body, to: question)
    }

    /// Build the reply for `body` and send it. The reply id is minted once here and reused by
    /// every retry, so re-delivery is idempotent at the endpoint.
    private func answer(_ body: AgentReply.Body, to question: AgentQuestion) async -> String {
        guard let run = activeRun else { return "There's nothing waiting for an answer." }
        guard let pending = pendingQuestion, pending.identity == question.identity else {
            // The question moved on between the prompt being raised and the wearer answering it.
            lastReplyOutcome = .stale
            return Self.staleLine
        }
        let reply = AgentReply(answering: question, body: body)
        pendingReply = reply
        return await deliver(reply, question: question, run: run)
    }

    /// Send one reply and report **what actually happened to it**.
    ///
    /// The bug this closes: the old path did `try? await harness.respondToInput(…)` and then said
    /// "Okay, proceeding" — identical words whether the endpoint had accepted the approval, thrown
    /// a transport error, or had no reply channel at all.
    private func deliver(_ reply: AgentReply, question: AgentQuestion, run: AgentRun) async -> String {
        guard let harness = runHarness else {
            lastReplyOutcome = .failed
            return "I've no agent backend to send that to."
        }
        do {
            try await harness.respondToInput(run, reply: reply)
            return accept(reply, question: question)
        } catch AgentHarnessError.uncertainDelivery {
            // Reconcile by asking the endpoint where the run stands. Never a second POST: the
            // first may already have been applied.
            if let status = try? await harness.status(run), status != .awaitingInput {
                return accept(reply, question: question)
            }
            lastReplyOutcome = .uncertain
            let line = "I couldn't tell whether the agent got your answer, and it's still waiting — say retry to send it again."
            emit(line)
            return line
        } catch let error as AgentHarnessError {
            return refuse(error, reply: reply)
        } catch {
            lastReplyOutcome = .failed
            let line = "I couldn't get your answer to the agent — say retry to try again."
            emit(line)
            return line
        }
    }

    /// The endpoint took the reply. Only now is anything claimed about the run.
    private func accept(_ reply: AgentReply, question: AgentQuestion) -> String {
        pendingQuestion = nil
        pendingReply = nil
        lastReplyOutcome = .delivered
        let line: String
        switch reply.body {
        case .approve:
            activeRun?.status = .running
            declineAwaitingEndpoint = false
            line = "Okay, proceeding."
        case .text:
            activeRun?.status = .running
            declineAwaitingEndpoint = false
            line = "Sent your answer to the agent."
        case .deny:
            // The run is no longer waiting on us — we answered — but what it *does* with the no is
            // the endpoint's to report. `.running` says only that the far end has the ball; the
            // flag keeps the status line honest until the endpoint says what became of it. Marking
            // it `.cancelled` here would assert a remote stop nothing confirmed.
            activeRun?.status = .running
            declineAwaitingEndpoint = true
            line = "I've told the agent not to proceed."
        }
        emit(line)
        return line
    }

    /// The reply did not get there. The question stays pending, and nothing is claimed.
    private func refuse(_ error: AgentHarnessError, reply: AgentReply) -> String {
        let line: String
        switch error {
        case .replyUnsupported(let body):
            lastReplyOutcome = .unsupported
            pendingReply = nil          // no channel — a retry would fail identically
            switch body {
            case .text:
                line = "This agent can't take a typed answer, so I didn't send it."
            case .approve:
                line = "This agent has no way to relay an approval, so nothing was sent and it's still waiting."
            case .deny:
                // Explicitly NOT "cancelled": we could not tell it, so the run is whatever the
                // endpoint last said it was.
                line = "This agent has no way to relay a decline, so I couldn't tell it to stop."
            }
        case .http(let code):
            lastReplyOutcome = .failed
            line = "The agent endpoint refused your answer (HTTP \(code)) — say retry to try again."
        default:
            lastReplyOutcome = .failed
            line = "I couldn't get your answer to the agent — say retry to try again."
        }
        _ = reply
        emit(line)
        return line
    }

    /// What is said to an answer whose question has been replaced, cancelled or has expired.
    static let staleLine = "That answer was for an earlier question, so I didn't send it."

    /// One spoken line describing the current state (for "agent status").
    ///
    /// Contact comes first: once we have stopped following a run, every other answer here would be
    /// a stale guess dressed as the present.
    func currentStatusLine() -> String {
        guard let run = activeRun else {
            // Nothing running, but a result may have been read out in a process that is gone.
            if let record = deliveryStore?.mostRecent, record.deliveryIsAmbiguous {
                return "No agent run is active." + AgentDeliveryPhrasing.ambiguousTail
            }
            return "No agent run is active."
        }
        if case .lost(let loss) = connectionState, !run.status.isTerminal {
            return AgentSummarizer.statusLine(afterContactLost: loss,
                                              at: Self.timeFormatter.string(from: contactLostAt ?? now()),
                                              lastKnown: run.status)
        }
        switch run.status {
        case .queued:        return "The agent run is queued."
        case .running:
            if declineAwaitingEndpoint {
                return "I've told the agent not to proceed; it hasn't reported stopping yet."
            }
            return "The agent is working on \(run.project ?? "your task")."
        case .awaitingInput: return pendingQuestion?.prompt ?? "The agent is waiting for your confirmation."
        case .completed:     return (lastSummary ?? "The agent run is complete.") + deliveryTail()
        case .failed:        return (lastSummary ?? "The agent run failed.") + deliveryTail()
        case .cancelled:     return "The agent run was cancelled." + deliveryTail()
        }
    }

    /// What the status line adds about **whether the wearer actually got** the result (Plan FE P4).
    ///
    /// Nothing at all when playback completed: repeating "and you heard it" would be a claim this
    /// app cannot make. The tail appears only when the record says they did not get it, or when it
    /// cannot say — and in the second case it hedges rather than picking the comfortable reading.
    private func deliveryTail() -> String {
        guard let record = latestDelivery else { return "" }
        if record.deliveryIsAmbiguous { return AgentDeliveryPhrasing.ambiguousTail }
        return AgentDeliveryPhrasing.statusTail(for: record.state) ?? ""
    }

    /// Short local time ("3:42 PM" / "15:42"), for the contact-lost answer.
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private func emit(_ line: String) {
        spokenLog.append(line)
        speak(line)
    }
}
