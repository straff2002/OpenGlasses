import XCTest
@testable import OpenGlasses

// MARK: - Which thread a turn belongs to

/// A job's turns belong in one thread, and no surface may take the technician out of it without
/// saying so. These are the transitions `ConversationThreadContinuityPolicy` used to answer a
/// narrower version of (its four cases are the first four tests here) plus the ones it could not:
/// which thread the turn actually lands in, and what happens when that thread is deleted.
final class JobThreadPolicyTests: XCTestCase {

    private let bound = "thread-job"
    private let other = "thread-other"

    private func jobInputs(bound: String? = "thread-job",
                           exists: Bool = true,
                           detached: Bool = false,
                           active: String? = "thread-job",
                           reference: String? = "1005",
                           persistence: Bool = true) -> JobThreadPolicy.Inputs {
        JobThreadPolicy.Inputs(jobActive: true, jobReference: reference, boundThreadId: bound,
                               boundThreadExists: exists, boundThreadDetached: detached,
                               activeThreadId: active, persistenceEnabled: persistence)
    }

    private func noJob(active: String? = "thread-other",
                       persistence: Bool = true) -> JobThreadPolicy.Inputs {
        JobThreadPolicy.Inputs(jobActive: false, activeThreadId: active,
                               persistenceEnabled: persistence)
    }

    // MARK: The rule the narrow policy carried, in its new home

    func testAnOrdinaryTurnClosesItsThread() {
        XCTAssertEqual(JobThreadPolicy.resolve(.returnToWakeWord, noJob()), .endThread)
    }

    func testAJobKeepsItsThreadOpenBetweenTurns() {
        XCTAssertEqual(JobThreadPolicy.resolve(.returnToWakeWord, jobInputs()), .keepThread,
                       "the next wake word continues the job's conversation")
    }

    func testNothingToEndIsNotAnEnd() {
        XCTAssertEqual(JobThreadPolicy.resolve(.returnToWakeWord, noJob(active: nil)), .keepThread)
        XCTAssertEqual(JobThreadPolicy.resolve(.returnToWakeWord, noJob(persistence: false)),
                       .keepThread)
    }

    func testTheThreadClosesOnceTheJobIsOver() {
        XCTAssertEqual(JobThreadPolicy.resolve(.returnToWakeWord, jobInputs()), .keepThread)
        XCTAssertEqual(JobThreadPolicy.resolve(.returnToWakeWord, noJob()), .endThread)
    }

    // MARK: Which thread the turn lands in

    func testEveryTurnSourceResolvesToTheBoundThread() {
        for source in [JobThreadPolicy.TurnSource.wakeWord, .tapToTalk, .typed] {
            XCTAssertEqual(JobThreadPolicy.resolve(.turn(source), jobInputs(active: other)),
                           .useBoundThread(id: bound), "\(source) must join the job's conversation")
        }
    }

    func testAJobWithNoThreadYetAdoptsTheOpenOne() {
        XCTAssertEqual(JobThreadPolicy.resolve(.turn(.wakeWord),
                                               jobInputs(bound: nil, exists: false, active: other)),
                       .bindActiveThread(id: other))
    }

    /// Thread creation is lazy — `startThread` only runs once ASR has produced text — so a job
    /// started from a settings screen has nothing to bind until the first turn.
    func testAJobWithNoThreadAtAllStartsOne() {
        XCTAssertEqual(JobThreadPolicy.resolve(.turn(.wakeWord),
                                               jobInputs(bound: nil, exists: false, active: nil)),
                       .bindNewThread(reason: .noThreadYet))
        XCTAssertEqual(JobThreadPolicy.resolve(.jobStarted,
                                               jobInputs(bound: nil, exists: false, active: nil)),
                       .deferBinding)
    }

    func testStartingAJobAdoptsTheConversationItWasStartedIn() {
        XCTAssertEqual(JobThreadPolicy.resolve(.jobStarted,
                                               jobInputs(bound: nil, exists: false, active: other)),
                       .bindActiveThread(id: other))
    }

    func testADeletedJobThreadIsRebound() {
        XCTAssertEqual(JobThreadPolicy.resolve(.turn(.wakeWord), jobInputs(exists: false)),
                       .bindNewThread(reason: .boundThreadDeleted),
                       "a deleted thread must not strand the job on a dangling id")
    }

    func testWithoutPersistenceNothingIsBound() {
        XCTAssertEqual(JobThreadPolicy.resolve(.turn(.wakeWord), jobInputs(persistence: false)),
                       .proceedUnbound)
    }

    // MARK: Leaving the job's conversation

    func testAnExplicitNewChatDuringAJobAsksFirst() {
        guard case .askFirst(let question) =
                JobThreadPolicy.resolve(.newChat(confirmed: false), jobInputs()) else {
            return XCTFail("a new chat during a job must be a question")
        }
        XCTAssertEqual(question.requested, .newChat)
        XCTAssertTrue(question.spoken.contains("1005"))
        XCTAssertTrue(question.spoken.contains("separate chat"))
    }

    func testAConfirmedNewChatDetachesRatherThanDiscardingTheJobsThread() {
        XCTAssertEqual(JobThreadPolicy.resolve(.newChat(confirmed: true), jobInputs()),
                       .detachThread)
    }

    func testANewChatWithNoJobIsNotAQuestion() {
        XCTAssertEqual(JobThreadPolicy.resolve(.newChat(confirmed: false), noJob()),
                       .proceedUnbound)
    }

    /// The job is not the open conversation — the technician already stepped out of it — so
    /// starting another one takes nothing away from the job.
    func testANewChatFromOutsideTheJobsThreadIsNotAQuestion() {
        XCTAssertEqual(JobThreadPolicy.resolve(.newChat(confirmed: false),
                                               jobInputs(active: other)),
                       .proceedUnbound)
    }

    func testOpeningAnotherConversationDuringAJobAsksFirst() {
        guard case .askFirst(let question) =
                JobThreadPolicy.resolve(.resumeThread(id: other, confirmed: false), jobInputs()) else {
            return XCTFail("switching away from the job must be a question")
        }
        XCTAssertEqual(question.requested, .switchThread(id: other))
    }

    func testReopeningTheJobsOwnThreadIsNeverAQuestion() {
        XCTAssertEqual(JobThreadPolicy.resolve(.resumeThread(id: bound, confirmed: false),
                                               jobInputs(active: other)),
                       .useBoundThread(id: bound))
    }

    func testOnceDetachedTurnsStopResolvingToTheJobsThread() {
        XCTAssertEqual(JobThreadPolicy.resolve(.turn(.wakeWord), jobInputs(detached: true)),
                       .proceedUnbound)
        XCTAssertEqual(JobThreadPolicy.resolve(.returnToWakeWord, jobInputs(detached: true)),
                       .endThread)
        XCTAssertEqual(JobThreadPolicy.resolve(.newChat(confirmed: false), jobInputs(detached: true)),
                       .proceedUnbound)
    }

    // MARK: Disconnect, close, launch

    func testPuttingTheGlassesDownDoesNotEndAJobsConversation() {
        XCTAssertEqual(JobThreadPolicy.resolve(.disconnect, jobInputs()), .keepThread)
        XCTAssertEqual(JobThreadPolicy.resolve(.disconnect, noJob()), .endThread)
    }

    func testAThreadThatIsNotTheJobsStillEndsOnDisconnect() {
        XCTAssertEqual(JobThreadPolicy.resolve(.disconnect, jobInputs(active: other)), .endThread)
    }

    func testFinishingTheJobEndsItsConversation() {
        XCTAssertEqual(JobThreadPolicy.resolve(.jobClosed, jobInputs()), .endThread)
        XCTAssertEqual(JobThreadPolicy.resolve(.jobClosed, jobInputs(active: other)), .keepThread)
    }

    func testARestoredJobPicksItsConversationBackUp() {
        XCTAssertEqual(JobThreadPolicy.resolve(.launchRestore, jobInputs(active: nil)),
                       .useBoundThread(id: bound))
    }

    /// Nothing is created at launch — no turn is happening — so a dangling id is simply dropped
    /// and the next turn rebinds.
    func testARestoredJobWhoseThreadWasDeletedForgetsTheDanglingId() {
        XCTAssertEqual(JobThreadPolicy.resolve(.launchRestore,
                                               jobInputs(exists: false, active: nil)),
                       .clearBinding(reason: .boundThreadDeleted))
    }

    func testTheQuestionStillReadsWithoutAJobNumber() {
        guard case .askFirst(let question) =
                JobThreadPolicy.resolve(.newChat(confirmed: false), jobInputs(reference: nil)) else {
            return XCTFail("still a question with no number yet")
        }
        XCTAssertFalse(question.spoken.contains("job nil"))
        XCTAssertTrue(question.spoken.contains("a job"))
    }
}

// MARK: - Getting the job number

final class JobIntakeStateTests: XCTestCase {

    /// "Start job 1005" — one step, nothing asked.
    func testAJobStartedWithItsNumberAsksNothing() {
        let outcome = JobIntakeState.needsReference.advance(.jobStarted(reference: " 1005 "))
        XCTAssertEqual(outcome.state, .recorded(reference: "1005"))
        XCTAssertEqual(outcome.recordedReference, "1005")
        XCTAssertFalse(outcome.state.hasQuestionDue)
        XCTAssertFalse(outcome.state.isOutstanding)
    }

    func testAJobStartedWithoutOneOwesIt() {
        let outcome = JobIntakeState.needsReference.advance(.jobStarted(reference: nil))
        XCTAssertEqual(outcome.state, .needsReference)
        XCTAssertTrue(outcome.state.hasQuestionDue)
        XCTAssertTrue(outcome.state.isOutstanding)
        XCTAssertFalse(outcome.state.awaitsAnswer, "nothing has been asked yet")
    }

    func testAskingThenHearingThenReadingBackRecordsTheNumber() {
        var state = JobIntakeState.needsReference
        state = state.advance(.questionAsked).state
        XCTAssertEqual(state, .asked(attempts: 1))
        XCTAssertTrue(state.awaitsAnswer)

        let heard = state.advance(.heard("it's job 1005"))
        XCTAssertEqual(heard.state, .confirming(candidate: "1005", attempts: 1))
        XCTAssertEqual(heard.prompt, .readBack("1005"))
        XCTAssertTrue(heard.consumesUtterance)
        XCTAssertNil(heard.recordedReference, "nothing is written down before the read-back")

        let confirmed = heard.state.advance(.heard("yes that's right"))
        XCTAssertEqual(confirmed.state, .recorded(reference: "1005"))
        XCTAssertEqual(confirmed.recordedReference, "1005")
        XCTAssertEqual(confirmed.prompt, .confirmed("1005"))
    }

    /// Speech-recognised digits are the whole reason the read-back exists.
    func testMisheardDigitsAreCorrectedAndTheCorrectionIsRecorded() {
        let confirming = JobIntakeState.confirming(candidate: "10 or 5", attempts: 1)
        let corrected = confirming.advance(.heard("no, it's 1005"))
        XCTAssertEqual(corrected.state, .confirming(candidate: "1005", attempts: 1))
        XCTAssertEqual(corrected.prompt, .readBack("1005"))
        XCTAssertEqual(corrected.audit, .corrected(from: "10 or 5"))

        let recorded = corrected.state.advance(.heard("yep"))
        XCTAssertEqual(recorded.recordedReference, "1005")
    }

    func testRepeatingTheSameNumberIsAgreement() {
        let confirming = JobIntakeState.confirming(candidate: "1005", attempts: 1)
        let outcome = confirming.advance(.heard("1005"))
        XCTAssertEqual(outcome.state, .recorded(reference: "1005"))
    }

    /// One correction loop, then typing is offered and the app stops asking.
    func testABareNoLoopsOnceThenGivesUp() {
        let first = JobIntakeState.confirming(candidate: "1005", attempts: 1).advance(.heard("no"))
        XCTAssertEqual(first.state, .asked(attempts: 2))
        XCTAssertEqual(first.prompt, .askAgain)
        XCTAssertFalse(first.state.hasQuestionDue, "the ask budget is spent")

        let second = JobIntakeState.confirming(candidate: "1006", attempts: 2).advance(.heard("nope"))
        XCTAssertEqual(second.state, .outstanding)
        XCTAssertEqual(second.prompt, .offerTyping)
        XCTAssertEqual(second.audit, .gaveUp)
        XCTAssertTrue(second.state.isOutstanding)
        XCTAssertFalse(second.state.hasQuestionDue)
    }

    func testDecliningIsRecordedAndNeverAskedAgain() {
        let declined = JobIntakeState.asked(attempts: 1).advance(.heard("I don't have one"))
        XCTAssertEqual(declined.state, .declined)
        XCTAssertEqual(declined.audit, .declined)
        XCTAssertEqual(declined.prompt, .acknowledgeDeclined)
        XCTAssertFalse(declined.state.hasQuestionDue)
        XCTAssertFalse(declined.state.isOutstanding)
        XCTAssertNil(declined.state.advance(.questionAsked).prompt)
        XCTAssertEqual(declined.state.advance(.questionAsked).state, .declined)
    }

    /// The technician got on with the job. The turn is theirs, and the question stays open.
    func testAnUnrelatedUtteranceIsNotSwallowed() {
        for line in ["what's this error code?", "show me the wiring diagram",
                     "the discharge pressure is 240 psi", "take a picture of this"] {
            let outcome = JobIntakeState.asked(attempts: 1).advance(.heard(line))
            XCTAssertEqual(outcome.state, .asked(attempts: 1), "\(line) must not move the intake")
            XCTAssertFalse(outcome.consumesUtterance, "\(line) must reach the model")
            XCTAssertNil(outcome.recordedReference)
        }
    }

    func testTheAskBudgetIsTwo() {
        var state = JobIntakeState.needsReference
        state = state.advance(.questionAsked).state
        state = state.advance(.questionAsked).state
        XCTAssertEqual(state, .asked(attempts: 2))
        XCTAssertFalse(state.hasQuestionDue)
        XCTAssertEqual(state.advance(.questionAsked).state, .asked(attempts: 2),
                       "a third ask is the nag this machine exists to avoid")
    }

    func testATypedNumberNeedsNoReadBack() {
        let outcome = JobIntakeState.outstanding.advance(.referenceSupplied("WO-1005"))
        XCTAssertEqual(outcome.state, .recorded(reference: "WO-1005"))
        XCTAssertEqual(outcome.recordedReference, "WO-1005")
    }

    func testAnEmptySuppliedNumberChangesNothing() {
        XCTAssertEqual(JobIntakeState.needsReference.advance(.referenceSupplied("   ")).state,
                       .needsReference)
    }

    /// Persisted with the session, so "still owed" survives a restart.
    func testEveryStateSurvivesARoundTrip() throws {
        let states: [JobIntakeState] = [.notRequired, .needsReference, .asked(attempts: 2),
                                        .confirming(candidate: "1005", attempts: 1),
                                        .recorded(reference: "WO/1005-B"), .declined, .outstanding]
        for state in states {
            let data = try JSONEncoder().encode(state)
            XCTAssertEqual(try JSONDecoder().decode(JobIntakeState.self, from: data), state)
        }
    }
}

// MARK: - Is that an answer, or is it the job?

final class JobReferenceClassifierTests: XCTestCase {

    private func reference(_ text: String) -> String? {
        if case .reference(let value) = JobReferenceClassifier.classify(text) { return value }
        return nil
    }

    func testTheCarrierPhraseComesOffAndTheRestIsVerbatim() {
        XCTAssertEqual(reference("1005"), "1005")
        XCTAssertEqual(reference("job 1005"), "1005")
        XCTAssertEqual(reference("Job number 1005."), "1005")
        XCTAssertEqual(reference("it's job number 1005"), "1005")
        XCTAssertEqual(reference("work order WO-4471"), "WO-4471")
        XCTAssertEqual(reference("the number is 22/8841"), "22/8841")
    }

    /// Recorded exactly as given: no case folding, no digit grouping, no separator tidying.
    func testCasingAndSeparatorsAreLeftAlone() {
        XCTAssertEqual(reference("job wo-1005b"), "wo-1005b")
        XCTAssertEqual(reference("job 10 05"), "10 05")
        XCTAssertEqual(reference("job #4471"), "#4471")
    }

    func testYesAndNoAreTheirOwnAnswers() {
        XCTAssertEqual(JobReferenceClassifier.classify("yes"), .affirmative)
        XCTAssertEqual(JobReferenceClassifier.classify("that's right"), .affirmative)
        XCTAssertEqual(JobReferenceClassifier.classify("no"), .negative)
        XCTAssertEqual(JobReferenceClassifier.classify("not quite"), .negative)
    }

    func testACorrectionCarriesItsNumberPastTheNo() {
        XCTAssertEqual(reference("no, it's 1006"), "1006")
        XCTAssertEqual(reference("no it's job 1006"), "1006")
    }

    func testHavingNoNumberIsAnAnswer() {
        for line in ["I don't have one", "there is no job number", "none", "haven't got one"] {
            XCTAssertEqual(JobReferenceClassifier.classify(line), .decline, line)
        }
    }

    /// The costly mistake is filing a visit under a reading or a question.
    func testQuestionsCommandsAndReadingsAreNotJobNumbers() {
        for line in ["what's this error code?", "what is fault 33", "show me page 41",
                     "the suction pressure is 240 psi", "it's reading 24 volts",
                     "error code E5", "take a picture", "how many minutes on that",
                     "can you look up 30RB", "the compressor has been running for 20 minutes"] {
            XCTAssertNil(reference(line), "\(line) must not be taken as a job number")
        }
    }

    func testSomethingWithNoDigitsIsNeverAJobNumber() {
        XCTAssertNil(reference("the Henderson job"))
        XCTAssertNil(reference("the usual one"))
    }

    func testAnEmptyUtteranceIsUnrelated() {
        XCTAssertEqual(JobReferenceClassifier.classify("   "), .unrelated)
    }

    func testALongSentenceIsNotAJobNumber() {
        XCTAssertNil(reference("I think the job number might be somewhere around 1005 or so"))
    }

    /// Regression: an apostrophe used to be normalised to a *space*, splitting "that's" into
    /// "that s" and "don't" into "don t" — so most natural ways of saying yes, no and "I don't
    /// have one" silently stopped being answers and fell through to the model as ordinary turns.
    func testApostrophesDoNotSplitWordsApart() {
        XCTAssertEqual(JobReferenceClassifier.normalise("that's right"), "thats right")
        XCTAssertEqual(JobReferenceClassifier.normalise("I don't have one"), "i dont have one")
        XCTAssertEqual(JobReferenceClassifier.normalise("that\u{2019}s it"), "thats it",
                       "the recogniser emits a typographic apostrophe, not a straight one")

        XCTAssertEqual(JobReferenceClassifier.classify("that's right"), .affirmative)
        XCTAssertEqual(JobReferenceClassifier.classify("that\u{2019}s right"), .affirmative)
        XCTAssertEqual(JobReferenceClassifier.classify("that's wrong"), .negative)
        XCTAssertEqual(JobReferenceClassifier.classify("I don't have one"), .decline)
    }

    /// Regression: the carrier phrase was matched against the raw text, so a comma the recogniser
    /// inserted — "no, it's 1005" — stopped "no it's" ever matching, and the correction was read
    /// back as the whole sentence.
    func testPunctuationInsideACarrierPhraseDoesNotBlockIt() {
        XCTAssertEqual(JobReferenceClassifier.stripCarrierPhrase(from: "no, it's 1005"), "1005")
        XCTAssertEqual(JobReferenceClassifier.stripCarrierPhrase(from: "No — job number: 1005"), "1005")
        XCTAssertEqual(JobReferenceClassifier.stripCarrierPhrase(from: "Um, the number is WO-1005"),
                       "WO-1005")
        XCTAssertEqual(reference("no, it's 1005"), "1005")
    }

    /// …and stripping counts words, not characters, so nothing of the number is eaten.
    func testStrippingNeverEatsPartOfTheNumber() {
        XCTAssertEqual(JobReferenceClassifier.stripCarrierPhrase(from: "job 1005"), "1005")
        XCTAssertEqual(JobReferenceClassifier.stripCarrierPhrase(from: "1005"), "1005")
        XCTAssertEqual(JobReferenceClassifier.stripCarrierPhrase(from: "job"), "job",
                       "a carrier phrase with nothing after it is not a carrier phrase")
    }
}

// MARK: - Has the technician moved to another machine?

final class JobChangeDetectorTests: XCTestCase {

    /// Two models of the same family — so a half-heard "SLP99UH" is a spelling *both* answer to,
    /// which is how a split or partial read actually becomes ambiguous — plus a control board the
    /// vault names in prose but never as a machine.
    private let index = VaultModelIndex(vaultName: "Test", files: [(
        filename: "models.md",
        contents: """
        ## SLP99UH090XV60CK (090XV60C)
        Ninety thousand BTU furnace. Control board KIT44A71 is shared across the range.

        ## SLP99UH070XV36BK (070XV36B)
        Seventy thousand BTU furnace.
        """)])

    private func identity(_ heading: String) -> EquipmentIdentity {
        EquipmentIdentity(modelToken: heading, heading: heading, file: "models.md", source: .spoken)
    }

    // MARK: Resolving

    func testExactlyOneModelIsAnIdentification() {
        guard case .model(let candidate) = JobChangeDetector.candidate(
            in: "this one is an SLP99UH090XV60CK", index: index, source: .spoken) else {
            return XCTFail("one match is an identification")
        }
        XCTAssertEqual(candidate.modelToken, "SLP99UH090XV60CK")
        XCTAssertEqual(candidate.source, .spoken)
    }

    /// The same bar `equipment_lookup` uses to set equipment at all. A question that could close a
    /// job must not be easier to trigger than the thing it guards — so a read that only gets as far
    /// as the family both units share resolves to neither.
    func testASplitOrAmbiguousReadIsUnclear() {
        let resolution = JobChangeDetector.candidate(in: "it says SLP99UH on the plate",
                                                     index: index, source: .nameplate)
        XCTAssertEqual(resolution, .unclear(reason: .severalModels))
    }

    func testAPartNumberTheVaultMentionsIsNotAMachine() {
        let resolution = JobChangeDetector.candidate(in: "the board is KIT44A71", index: index,
                                                     source: .spoken)
        XCTAssertEqual(resolution, .unclear(reason: .notAModel))
    }

    func testTextThatNamesNothingResolvesToNothing() {
        XCTAssertEqual(JobChangeDetector.candidate(in: "the fan is noisy", index: index,
                                                   source: .spoken), .none)
    }

    func testAnEmptyIndexMakesTheWholeThingANoOp() {
        let empty = VaultModelIndex(vaultName: "Empty", files: [])
        XCTAssertEqual(JobChangeDetector.candidate(in: "SLP99UH090XV60CK", index: empty,
                                                   source: .spoken), .none)
    }

    // MARK: Comparing

    func testTheFirstMachineOfAJobIsNeverAChange() {
        let outcome = JobChangeDetector.compare(current: nil,
                                                candidate: .model(identity("SLP99UH090XV60CK")))
        XCTAssertEqual(outcome, .same)
    }

    func testTheSameMachineIsNotAChange() {
        let current = identity("SLP99UH090XV60CK")
        XCTAssertEqual(JobChangeDetector.compare(current: current, candidate: .model(current)),
                       .same)
    }

    func testADifferentModelIsAnAdditionalUnit() {
        let outcome = JobChangeDetector.compare(current: identity("SLP99UH090XV60CK"),
                                                candidate: .model(identity("SLP98UH070XV36B")))
        guard case .additionalUnit(let candidate) = outcome else {
            return XCTFail("a different model is a different unit")
        }
        XCTAssertEqual(candidate.heading, "SLP98UH070XV36B")
    }

    /// Two identical units on one site are the same model and different machines.
    func testTheSameModelWithADifferentSerialIsAnotherUnit() {
        let model = identity("SLP99UH090XV60CK")
        let outcome = JobChangeDetector.compare(current: model, currentSerial: "5819K00123",
                                                candidate: .model(model),
                                                candidateSerial: "5819K00987")
        guard case .additionalUnit = outcome else { return XCTFail("different serials, two units") }
    }

    func testTheSameSerialReadTwoWaysIsOneUnit() {
        let model = identity("SLP99UH090XV60CK")
        XCTAssertEqual(JobChangeDetector.compare(current: model, currentSerial: "5819K-00123",
                                                 candidate: .model(model),
                                                 candidateSerial: "5819k00123"),
                       .same)
    }

    func testAMissingSerialOnEitherSideIsNotEvidenceOfASecondUnit() {
        let model = identity("SLP99UH090XV60CK")
        XCTAssertEqual(JobChangeDetector.compare(current: model, currentSerial: "5819K00123",
                                                 candidate: .model(model), candidateSerial: nil),
                       .same)
    }

    func testAnUnclearReadNeverProposesAChange() {
        let outcome = JobChangeDetector.compare(current: identity("SLP99UH090XV60CK"),
                                                candidate: .unclear(reason: .severalModels))
        XCTAssertEqual(outcome, .unclear(reason: .severalModels))
    }

    func testTheQuestionNamesTheJobAndTheMachine() {
        let question = JobUnitChangeQuestion(jobReference: "1005",
                                             candidate: identity("SLP98UH070XV36B"))
        XCTAssertTrue(question.spoken.contains("1005"))
        XCTAssertTrue(question.spoken.contains("finished"))
    }
}

// MARK: - Answering the change question

final class JobUnitChangeClassifierTests: XCTestCase {

    func testSameJobAnswers() {
        for line in ["same job", "it's another unit on the same job", "same one",
                     "next unit, same work order"] {
            XCTAssertEqual(JobUnitChangeClassifier.classify(line), .sameJob, line)
        }
    }

    func testFinishedAnswers() {
        for line in ["that one's finished", "the job is done", "finished", "this is a new job"] {
            XCTAssertEqual(JobUnitChangeClassifier.classify(line), .jobFinished, line)
        }
    }

    func testUnsureAnswers() {
        for line in ["not sure", "I don't know", "hang on"] {
            XCTAssertEqual(JobUnitChangeClassifier.classify(line), .unsure, line)
        }
    }

    /// "The same job is finished" must not read as "same job".
    func testAFinishStillReadsAsAFinishWhenItNamesTheSameJob() {
        XCTAssertEqual(JobUnitChangeClassifier.classify("the same job is finished"), .jobFinished)
    }

    func testAnythingElsePassesThrough() {
        for line in ["what's the charge on this one", "read me the error code", "240 volts"] {
            XCTAssertNil(JobUnitChangeClassifier.classify(line), line)
        }
    }

    /// Regression: the same apostrophe bug lived here too, so "that one's finished" and
    /// "I don't know" were not answers and the held question stayed held.
    func testApostrophesDoNotSplitWordsApart() {
        XCTAssertEqual(JobUnitChangeClassifier.classify("that one's finished"), .jobFinished)
        XCTAssertEqual(JobUnitChangeClassifier.classify("that one\u{2019}s done"), .jobFinished)
        XCTAssertEqual(JobUnitChangeClassifier.classify("I don't know"), .unsure)
    }
}

// MARK: - What the job's conversation is called

final class JobThreadTitleTests: XCTestCase {

    func testTheNumberLeadsAndTheMachineFollows() {
        XCTAssertEqual(JobThreadTitle.title(reference: "1005", equipment: "SLP99UH"),
                       "Job 1005 — SLP99UH")
        XCTAssertEqual(JobThreadTitle.title(reference: "1005", equipment: nil), "Job 1005")
        XCTAssertEqual(JobThreadTitle.title(reference: " 1005 ", equipment: "  "), "Job 1005")
    }

    func testWithNoNumberThereIsNothingToLeadWith() {
        XCTAssertNil(JobThreadTitle.title(reference: nil, equipment: "SLP99UH"))
        XCTAssertNil(JobThreadTitle.title(reference: "  ", equipment: "SLP99UH"))
    }

    func testOnlyThisJobsOwnTitlesAreRecognisedAsItsOwn() {
        XCTAssertTrue(JobThreadTitle.isGenerated("Job 1005", reference: "1005"))
        XCTAssertTrue(JobThreadTitle.isGenerated("Job 1005 — SLP99UH", reference: "1005"))
        XCTAssertFalse(JobThreadTitle.isGenerated("Job 1006", reference: "1005"))
        XCTAssertFalse(JobThreadTitle.isGenerated("Job interview questions", reference: "1005"),
                       "a wearer's own conversation that happens to start with the word must not be taken over")
    }
}
