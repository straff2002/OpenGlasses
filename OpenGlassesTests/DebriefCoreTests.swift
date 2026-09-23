import XCTest
@testable import OpenGlasses

/// The pure half of the job debrief (Plan FO P3b): which job was meant, what a summary may
/// contain, and how the read-back settles.
///
/// Every one of these is a decision about a customer's record, so every one of them is provable
/// without a session, a store, a model or a car.
final class DebriefCoreTests: XCTestCase {

    // MARK: - Which job

    private func candidate(_ number: String?, daysAgo: Int, id: String = UUID().uuidString,
                           outcome: String = "Resolved",
                           active: Bool = false) -> DebriefJobResolver.Candidate {
        DebriefJobResolver.Candidate(
            sessionId: id, jobReference: number,
            startedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!,
            outcomeLabel: outcome, isActive: active)
    }

    /// Newest first — the order the resolver's "next" and "previous" are relative to.
    private var day: [DebriefJobResolver.Candidate] {
        [candidate("1007", daysAgo: 0, id: "s7", active: true),
         candidate("1006", daysAgo: 0, id: "s6"),
         candidate("1005", daysAgo: 1, id: "s5"),
         candidate(nil, daysAgo: 2, id: "s4")]
    }

    func testANumberResolvesToThatJob() {
        XCTAssertEqual(DebriefJobResolver.resolve("debrief job 1006", candidates: day),
                       .resolved(sessionId: "s6"))
        XCTAssertEqual(DebriefJobResolver.resolve("let's do 1005", candidates: day),
                       .resolved(sessionId: "s5"))
    }

    func testNextWalksBackwardsInTimeFromTheJobInHand() {
        XCTAssertEqual(DebriefJobResolver.resolve("next job", candidates: day, current: "s6"),
                       .resolved(sessionId: "s5"))
        XCTAssertEqual(DebriefJobResolver.resolve("the one before that", candidates: day,
                                                  current: "s5"),
                       .resolved(sessionId: "s6"))
        XCTAssertEqual(DebriefJobResolver.resolve("the last job", candidates: day),
                       .resolved(sessionId: "s7"))
    }

    func testNextWithNoJobInHandIsTheNewest() {
        XCTAssertEqual(DebriefJobResolver.resolve("next job", candidates: day),
                       .resolved(sessionId: "s7"))
    }

    /// Two jobs with the same number is the case §6 names: the app asks by date, and the question
    /// carries both dates rather than a guess.
    func testTwoJobsWithTheSameNumberAreAskedAboutByDate() {
        let clashing = [candidate("1006", daysAgo: 0, id: "today"),
                        candidate("1006", daysAgo: 6, id: "lastWeek")]
        guard case .ambiguous(let question, let ids) =
                DebriefJobResolver.resolve("debrief job 1006", candidates: clashing) else {
            return XCTFail("two jobs numbered 1006 must be asked about, never guessed between")
        }
        XCTAssertEqual(Set(ids), ["today", "lastWeek"])
        XCTAssertTrue(question.contains("1006"))
        XCTAssertTrue(question.lowercased().contains("which one"))
    }

    func testANumberNothingAnswersToIsAQuestionAndNeverTheNewestJob() {
        guard case .notFound(let question) =
                DebriefJobResolver.resolve("debrief job 9999", candidates: day) else {
            return XCTFail("an unknown number must not silently resolve to anything")
        }
        XCTAssertTrue(question.contains("9999"))
    }

    func testADayResolvesAJobWhenOnlyOneIsOnIt() {
        XCTAssertEqual(DebriefJobResolver.resolve("the one from yesterday", candidates: day),
                       .resolved(sessionId: "s5"))
    }

    func testAnOrdinarySentenceIsNotAJobReference() {
        XCTAssertEqual(DebriefJobResolver.resolve("the drier looked wet", candidates: day),
                       .notAReference)
        XCTAssertEqual(DebriefJobResolver.resolve("ok", candidates: day), .notAReference)
    }

    func testTheSpokenNameCarriesNumberDateAndOutcome() {
        let spoken = candidate("1006", daysAgo: 0, outcome: "Escalated").spoken
        XCTAssertTrue(spoken.hasPrefix("Job 1006, "))
        XCTAssertTrue(spoken.hasSuffix(", Escalated"))
    }

    func testAJobWithNoNumberStillHasASpokenName() {
        XCTAssertTrue(candidate(nil, daysAgo: 1).spoken.hasPrefix(JobTabModel.noJobNumber))
    }

    // MARK: - The summary

    private func summaryJSON(_ categories: [String: [[String: Any]]]) -> [String: Any] {
        categories.mapValues { $0 as Any }
    }

    func testAValidSummaryDecodesWithItsCitations() {
        let json = summaryJSON([
            "findings": [["text": "Drier looks wet", "source_turn_ids": ["d-t1"]]],
            "follow_ups": [["text": "Wants the drier checked next visit",
                            "source_turn_ids": ["d-t2", "d-t1"]]]
        ])
        guard case .success(let summary) = DebriefSummaryDecoder.decode(json,
                                                                        turnIds: ["d-t1", "d-t2"]) else {
            return XCTFail("a summary citing real turns must decode")
        }
        XCTAssertEqual(summary.itemCount, 2)
        XCTAssertEqual(summary.items(.findings).first?.sourceTurnIds, ["d-t1"])
        XCTAssertTrue(summary.items(.forBase).isEmpty, "an absent category is simply empty")
    }

    func testAnItemWithNoCitationIsRejectedRatherThanTrimmed() {
        let json = summaryJSON(["findings": [["text": "Compressor is noisy",
                                              "source_turn_ids": [] as [String]]]])
        guard case .failure(let failure) = DebriefSummaryDecoder.decode(json, turnIds: ["d-t1"]) else {
            return XCTFail("an uncited item must never reach a record")
        }
        XCTAssertEqual(failure, .itemWithoutCitation(category: "findings", text: "Compressor is noisy"))
    }

    func testAnItemCitingATurnThatNeverHappenedIsRejected() {
        let json = summaryJSON(["for_base": [["text": "Needs a second visit",
                                              "source_turn_ids": ["d-t9"]]]])
        guard case .failure(let failure) = DebriefSummaryDecoder.decode(json, turnIds: ["d-t1"]) else {
            return XCTFail("a citation to a turn that does not exist must be refused")
        }
        XCTAssertEqual(failure, .unknownTurnId(category: "for_base", turnId: "d-t9"))
    }

    func testACompletedCheckInFindingsIsFlaggedRatherThanPromoted() {
        let json = summaryJSON(["findings": [["text": "Replaced the drier",
                                              "source_turn_ids": ["d-t1"]]]])
        guard case .success(let summary) = DebriefSummaryDecoder.decode(json, turnIds: ["d-t1"]) else {
            return XCTFail("the item is kept; it is the claim that is marked")
        }
        XCTAssertEqual(summary.items(.findings).first?.flag, .reportedNotVerified)
        XCTAssertEqual(summary.items(.findings).first?.line, "Replaced the drier — reported, not verified")
    }

    func testAnIntentionIsNotAPromotion() {
        XCTAssertFalse(DebriefSummaryDecoder.readsAsCompletedWork("should check the drier"))
        XCTAssertFalse(DebriefSummaryDecoder.readsAsCompletedWork("still needs testing"))
        XCTAssertTrue(DebriefSummaryDecoder.readsAsCompletedWork("tested it at full load"))
    }

    func testAFollowUpIsNeverFlagged() {
        let json = summaryJSON(["follow_ups": [["text": "Checked with the customer about access",
                                                "source_turn_ids": ["d-t1"]]]])
        guard case .success(let summary) = DebriefSummaryDecoder.decode(json, turnIds: ["d-t1"]) else {
            return XCTFail("a follow-up decodes")
        }
        XCTAssertNil(summary.items(.followUps).first?.flag,
                     "a follow-up is not a claim about this visit's work")
    }

    func testACategoryIsCappedAndTheWholeSummaryIsBounded() {
        let many = (1...12).map { ["text": "Item \($0)", "source_turn_ids": ["d-t1"]] }
        guard case .success(let summary) = DebriefSummaryDecoder.decode(
            summaryJSON(["findings": many]), turnIds: ["d-t1"]) else {
            return XCTFail("an over-long list is clipped to the cap, not refused")
        }
        XCTAssertEqual(summary.items(.findings).count, DebriefSummary.maximumItemsPerCategory)
    }

    func testAnEmptySummaryIsAFailureRatherThanAnEmptyRecord() {
        guard case .failure(.empty) = DebriefSummaryDecoder.decode([:], turnIds: ["d-t1"]) else {
            return XCTFail("an empty summary is not something to read back and save")
        }
    }

    func testNonObjectJSONIsRefused() {
        guard case .failure(.notAnObject) = DebriefSummaryDecoder.decode(
            jsonData: Data("[]".utf8), turnIds: ["d-t1"]) else {
            return XCTFail("a non-object answer is refused")
        }
    }

    func testTheSchemaNamesEveryCategoryAndRequiresCitations() {
        let schema = DebriefSummary.jsonSchema
        let properties = schema["properties"] as? [String: Any] ?? [:]
        for category in DebriefSummary.Category.allCases {
            guard let list = properties[category.rawValue] as? [String: Any],
                  let items = list["items"] as? [String: Any],
                  let required = items["required"] as? [String] else {
                return XCTFail("\(category.rawValue) is missing from the schema")
            }
            XCTAssertTrue(required.contains("source_turn_ids"),
                          "\(category.rawValue) must require its citations")
        }
    }

    // MARK: - The read-back and the decision

    private var twoItems: DebriefSummary {
        DebriefSummary(categories: [
            .findings: [DebriefSummary.Item(text: "Drier looks wet", sourceTurnIds: ["d-t1"])],
            .forBase: [DebriefSummary.Item(text: "Needs a second visit", sourceTurnIds: ["d-t2"])]
        ])
    }

    func testTheHappyPathIsListenSummariseReadBackSave() {
        var state = DebriefReviewState.listening
        var outcome = state.advance(.heard("the drier looked wet"))
        XCTAssertTrue(outcome.recordsTurn)
        XCTAssertFalse(outcome.consumesUtterance, "an ordinary line still reaches the model")
        state = outcome.state

        outcome = state.advance(.heard("that's it"))
        XCTAssertEqual(outcome.state, .summarising)
        XCTAssertEqual(outcome.action, .requestSummary)
        state = outcome.state

        outcome = state.advance(.summaryReturned(twoItems))
        XCTAssertEqual(outcome.action, .speakReadBack)
        state = outcome.state.advance(.readBackSpoken).state
        XCTAssertEqual(state, .awaitingDecision(twoItems))

        outcome = state.advance(.heard("save it"))
        XCTAssertEqual(outcome.state, .saved)
        XCTAssertEqual(outcome.action, .save)
        XCTAssertTrue(outcome.consumesUtterance)
    }

    func testScrapItWritesNothing() {
        let outcome = DebriefReviewState.awaitingDecision(twoItems).advance(.heard("scrap it"))
        XCTAssertEqual(outcome.state, .discarded)
        XCTAssertEqual(outcome.action, .discard)
    }

    func testAnUnrelatedUtteranceDuringTheDecisionPassesThroughAndLeavesItOutstanding() {
        let state = DebriefReviewState.awaitingDecision(twoItems)
        let outcome = state.advance(.heard("what's the superheat target on this thing"))
        XCTAssertEqual(outcome.state, state, "the decision stays outstanding")
        XCTAssertFalse(outcome.consumesUtterance, "the question must reach the model")
        XCTAssertEqual(outcome.action, .none)
    }

    func testChangingAnItemKeepsItsCitations() {
        let state = DebriefReviewState.awaitingDecision(twoItems)
        let editing = state.advance(.heard("change the drier one"))
        guard case .editing(let category, let index, _) = editing.state else {
            return XCTFail("\"change the drier one\" must open that item for editing")
        }
        XCTAssertEqual(category, .findings)
        let replaced = editing.state.advance(.heard("the drier was damp, not wet"))
        guard let summary = replaced.state.summary else { return XCTFail("the summary survives an edit") }
        XCTAssertEqual(summary.items(.findings)[index].text, "the drier was damp, not wet")
        XCTAssertEqual(summary.items(.findings)[index].sourceTurnIds, ["d-t1"],
                       "an edit is the same report said again, not a new claim with no source")
    }

    func testAFailedSummaryOffersRetryOrKeepingWhatWasSaid() {
        var state = DebriefReviewState.summarising
        let failed = state.advance(.summaryFailed("no good"))
        state = failed.state
        guard case .failed = state else { return XCTFail("a failed call is its own state") }

        XCTAssertEqual(state.advance(.heard("try again")).action, .requestSummary)
        let raw = state.advance(.heard("keep what i said"))
        XCTAssertEqual(raw.action, .saveRaw)
        XCTAssertEqual(raw.state, .saved)
    }

    func testASaveWithNothingSummarisedDoesNothing() {
        let outcome = DebriefReviewState.listening.advance(.saveRequested)
        XCTAssertEqual(outcome.state, .listening)
        XCTAssertEqual(outcome.action, .none, "a save cannot be what produces a record")
    }

    func testTheReadBackNamesEveryNonEmptyCategoryAndEndsWithTheQuestion() {
        let lines = twoItems.readBackLines
        XCTAssertEqual(lines.first, DebriefSummary.Category.findings.heading + ":")
        XCTAssertTrue(lines.contains { $0.contains("Needs a second visit") })
        XCTAssertFalse(lines.contains { $0.hasPrefix(DebriefSummary.Category.customerNotes.heading) },
                       "an empty category is not read out")
        XCTAssertTrue(twoItems.spokenReadBack.hasSuffix(DebriefPrompt.decision.spoken))
    }

    // MARK: - What lands on the record

    func testADebriefBuiltFromASummaryCarriesItsCitationsAndProvenance() {
        let turns = [JobDebrief.Turn(id: "d-t1", text: "the drier looked wet", at: Date()),
                     JobDebrief.Turn(id: "d-t2", text: "base should send somebody back", at: Date())]
        let provenance = AIProvenance(modelIdentifier: "test-model", providerClass: .cloud,
                                      promptVersionDigest: "sha256:abc")
        let debrief = JobDebrief.make(summary: twoItems, turns: turns, provenance: provenance,
                                      threadId: "thread-1")
        XCTAssertEqual(debrief.entries.count, 2)
        XCTAssertEqual(debrief.entries.first?.sourceTurnIds, ["d-t1"])
        XCTAssertEqual(debrief.provenance?.modelIdentifier, "test-model")
        XCTAssertFalse(debrief.unsummarised)
        XCTAssertEqual(debrief.sources(for: debrief.entries[0]).first?.text, "the drier looked wet")
    }

    func testAnUnsummarisedDebriefSaysSoAndKeepsTheWords() {
        let turns = [JobDebrief.Turn(id: "d-t1", text: "compressor sounded rough", at: Date())]
        let debrief = JobDebrief.unsummarised(turns: turns, threadId: nil)
        XCTAssertTrue(debrief.unsummarised)
        XCTAssertTrue(debrief.entries.isEmpty)
        XCTAssertEqual(debrief.summaryLines.first, JobDebrief.unsummarisedNote)
        XCTAssertTrue(debrief.summaryLines.contains { $0.contains("compressor sounded rough") })
        XCTAssertNil(debrief.provenance, "there was no model in an unsummarised debrief")
    }

    func testADebriefRoundTripsThroughJSON() throws {
        let debrief = JobDebrief.make(
            summary: twoItems,
            turns: [JobDebrief.Turn(id: "d-t1", text: "one", at: Date(timeIntervalSince1970: 10)),
                    JobDebrief.Turn(id: "d-t2", text: "two", at: Date(timeIntervalSince1970: 20))],
            provenance: nil, threadId: "t")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(JobDebrief.self, from: encoder.encode(debrief))
        XCTAssertEqual(back, debrief)
    }

    /// A record written before debriefs existed still decodes, and simply has none.
    func testALegacyRecordWithNoDebriefKeyStillDecodes() throws {
        let json = """
        {"session_id":"abc","vault":"refrigeration","vault_name":"Refrigeration",
         "started_at":"2026-01-01T00:00:00Z","billable_minutes":0}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(WorkRecord.self, from: Data(json.utf8))
        XCTAssertTrue(record.debriefs.isEmpty)
    }

    // MARK: - Which document a debrief goes in

    func testADebriefBeforeTheReportGoesPrintsInTheWorkOrder() {
        let debrief = JobDebrief.unsummarised(turns: [], threadId: nil)
        XCTAssertEqual(DebriefDocumentPolicy.placement(debriefs: [debrief], reportAlreadySent: false),
                       .inWorkOrder([debrief]))
    }

    func testADebriefAfterTheReportHasGoneIsASecondDocument() {
        let debrief = JobDebrief.unsummarised(turns: [], threadId: nil)
        let placement = DebriefDocumentPolicy.placement(debriefs: [debrief], reportAlreadySent: true)
        XCTAssertEqual(placement, .asAddendum([debrief]))
        XCTAssertTrue(placement.workOrderDebriefs.isEmpty,
                      "the work order a customer already holds must not change")
    }

    func testNoDebriefsIsNothingToPlace() {
        XCTAssertEqual(DebriefDocumentPolicy.placement(debriefs: [], reportAlreadySent: true),
                       .nothing)
    }

    // MARK: - The model's block

    func testTheDebriefBlockNamesTheJobAndForbidsTheThreeThings() throws {
        let job = candidate("1005", daysAgo: 1)
        let block = try XCTUnwrap(DebriefContract.block(job: job, record: nil))
        XCTAssertTrue(block.hasPrefix(DebriefContract.heading))
        XCTAssertTrue(block.contains("Job 1005"))
        XCTAssertTrue(block.contains("Do not propose work"))
        XCTAssertTrue(block.contains("never claim anything has been saved"))
        XCTAssertLessThanOrEqual(block.count, DebriefContract.characterLimit)
    }

    func testNoDebriefMeansNoBlock() {
        XCTAssertNil(DebriefContract.block(job: nil, record: nil))
    }
}
