import XCTest
@testable import OpenGlasses

/// Plan FP P2 — review: the state machine, who may approve, merging into an entry that already
/// says it, the safety check that surfaces and never rejects, the model a vault does not know, and
/// the gates.
///
/// Headless: fresh candidate and entry stores over a temporary directory, a temporary
/// `DocumentStore`, and injected vaults, licence, device role and HIPAA flag.
@MainActor
final class TeamLearningReviewTests: XCTestCase {

    private typealias F = TeamLearningFixtures

    private var root: URL!
    private var candidates: LearningCandidateStore!
    private var entries: LearningEntryStore!
    private var documents: DocumentStore!
    private var service: LearningReviewService!
    private var reviewerDevice = false
    private var hipaa = false
    private var licence: FieldAssistCapabilityCheck = .granted

    private let reviewer = LearningReview.Approver(name: "Ari Reviewer", role: "Service manager")
    private let now = Date(timeIntervalSince1970: 1_791_633_600.75) // 2026-10-10T12:00:00.75Z

    override func setUp() {
        super.setUp()
        root = F.tempDirectory("TeamLearningReview")
        candidates = LearningCandidateStore(directory: root.appendingPathComponent("candidates", isDirectory: true))
        entries = LearningEntryStore(directory: root.appendingPathComponent("entries", isDirectory: true))
        documents = F.documentStore(in: root)
        reviewerDevice = false
        hipaa = false
        licence = .granted
        service = LearningReviewService(candidates: candidates, entries: entries, documentStore: documents)
        service.capability = { [unowned self] in self.licence }
        service.isReviewerDevice = { [unowned self] in self.reviewerDevice }
        service.hipaaMode = { [unowned self] in self.hipaa }
        service.vaults = { [LearningCorpus.VaultTarget(id: F.vaultId, modelIndex: F.modelIndex())] }
        service.coreFiles = { _ in [(filename: "safety.md", contents: F.safetyCore),
                                    (filename: "models.md", contents: F.modelsCore)] }
        service.clock = { [unowned self] in self.now }
    }

    override func tearDown() {
        service = nil
        documents = nil
        entries = nil
        candidates = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    @discardableResult
    private func file(_ candidate: LearningCandidate) -> LearningCandidate {
        candidates.add(candidate)
        return candidate
    }

    private func approved(_ result: Result<LearningReviewService.Outcome, LearningReview.Refusal>,
                          file: StaticString = #filePath, line: UInt = #line) throws -> LearningReviewService.Outcome {
        switch result {
        case .success(let outcome): return outcome
        case .failure(let refusal):
            XCTFail("refused: \(refusal.spoken)", file: file, line: line)
            throw refusal
        }
    }

    // MARK: - The state machine

    func testEveryTransitionTheMachineAllows() {
        typealias R = LearningReview
        XCTAssertEqual(try R.next(.candidate, .approve(entryID: "e")).get(), .approved(entryID: "e"))
        XCTAssertEqual(try R.next(.candidate, .editAndApprove(entryID: "e")).get(), .editedAndApproved(entryID: "e"))
        XCTAssertEqual(try R.next(.candidate, .reject(reason: " Already in the manual ")).get(),
                       .rejected(reason: "Already in the manual"))
        XCTAssertEqual(try R.next(.candidate, .merge(into: "e")).get(), .merged(into: "e"))
        for approved in [R.State.approved(entryID: "e"), .editedAndApproved(entryID: "e")] {
            XCTAssertEqual(try R.next(approved, .supersede(by: "f")).get(), .superseded(by: "f"))
            XCTAssertEqual(try R.next(approved, .retract(reason: "Board revision changed")).get(),
                           .retracted(reason: "Board revision changed"))
        }
        // Replays are idempotent.
        XCTAssertEqual(try R.next(.superseded(by: "f"), .supersede(by: "f")).get(), .superseded(by: "f"))
        XCTAssertEqual(try R.next(.retracted(reason: "first"), .retract(reason: "second")).get(),
                       .retracted(reason: "first"), "a second retraction keeps the first one's reason")
    }

    func testEveryTransitionTheMachineRefuses() {
        typealias R = LearningReview
        let refused: [(R.State, R.Action)] = [
            (.candidate, .supersede(by: "f")),
            (.candidate, .retract(reason: "x")),
            (.approved(entryID: "e"), .approve(entryID: "g")),
            (.approved(entryID: "e"), .editAndApprove(entryID: "g")),
            (.approved(entryID: "e"), .reject(reason: "x")),
            (.approved(entryID: "e"), .merge(into: "g")),
            (.editedAndApproved(entryID: "e"), .merge(into: "g")),
            (.rejected(reason: "x"), .approve(entryID: "e")),
            (.rejected(reason: "x"), .merge(into: "e")),
            (.merged(into: "e"), .approve(entryID: "e")),
            (.merged(into: "e"), .reject(reason: "x")),
            (.superseded(by: "f"), .supersede(by: "g")),
            (.superseded(by: "f"), .retract(reason: "x")),
            (.superseded(by: "f"), .approve(entryID: "e")),
            (.retracted(reason: "x"), .supersede(by: "f")),
            (.retracted(reason: "x"), .approve(entryID: "e")),
        ]
        for (state, action) in refused {
            XCTAssertEqual(R.next(state, action), .failure(.invalidTransition(from: state, action: action)),
                           "\(state) + \(action)")
        }
        XCTAssertEqual(R.next(.candidate, .reject(reason: "  ")), .failure(.missingReason))
        XCTAssertEqual(R.next(.approved(entryID: "e"), .retract(reason: "")), .failure(.missingReason))
    }

    // MARK: - Approve

    func testApprovingAsWrittenProducesTheContractsEntry() throws {
        let candidate = file(F.candidate(session: "job-7"))
        let outcome = try approved(service.approve(candidateID: candidate.id, approver: reviewer))
        let entry = outcome.entry

        XCTAssertEqual(outcome.state, .approved(entryID: entry.id))
        XCTAssertEqual(entry.id.count, 32)
        XCTAssertTrue(entry.id.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(entry.subject, .model(modelToken: F.model090))
        XCTAssertEqual(entry.vaultIDs, [F.vaultId], "defaults to the vault it was filed in")
        XCTAssertEqual(entry.finding, candidate.finding)
        XCTAssertEqual(entry.symptom, candidate.symptom)
        XCTAssertEqual(entry.fix, candidate.fix)
        XCTAssertEqual(entry.approvedAt, Date(timeIntervalSince1970: 1_791_633_600), "Unix seconds")
        XCTAssertEqual(entry.approvedByRole, "Service manager")
        XCTAssertEqual(entry.approvedByName, "Ari Reviewer")
        XCTAssertFalse(entry.authorIsApprover)
        XCTAssertFalse(entry.contradictsSafetyNote)
        XCTAssertEqual(entry.candidateID, candidate.id)
        XCTAssertEqual(entry.origin, .spoken)
        XCTAssertEqual(entry.sourceJobIDs, ["job-7"])
        XCTAssertEqual(entry.confirmedJobCount, 1)
        XCTAssertNil(entry.captured, "approved as written keeps no second text")
        XCTAssertEqual(entry.citationName,
                       "Team learning · \(F.model090) · 2026-10-10 · approved by Service manager")

        XCTAssertEqual(entries.entries, [entry])
        let stored = try XCTUnwrap(candidates.candidate(id: candidate.id))
        XCTAssertEqual(stored.status, .approved)
        XCTAssertEqual(stored.entryID, entry.id)
        XCTAssertEqual(outcome.placement.published, [F.vaultId])
        XCTAssertEqual(documents.documentCount(namespace: DocumentStore.learningNamespace(F.vaultId)), 1)

        // The wire names are the contract's (§5) plus the 2026-10-09 amendment.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(entry)) as? [String: Any])
        for key in ["entryID", "subject", "vaultIDs", "finding", "approvedAt", "approvedByRole", "authorIsApprover",
                    "contradictsSafetyNote", "candidateID", "origin", "sourceJobIDs", "confirmedJobCount"] {
            XCTAssertNotNil(object[key], "contract field \(key) missing")
        }
        let subject = try XCTUnwrap(object["subject"] as? [String: Any])
        XCTAssertEqual(subject["kind"] as? String, "model")
        XCTAssertEqual(subject["modelToken"] as? String, F.model090)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(LearningEntry.self, from: encoder.encode(entry)), entry)
        let practice = F.entry(subject: .practice(topic: "Condensate traps"))
        let practiceObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(practice)) as? [String: Any])
        XCTAssertEqual((practiceObject["subject"] as? [String: Any])?["kind"] as? String, "practice")
        XCTAssertEqual((practiceObject["subject"] as? [String: Any])?["topic"] as? String, "Condensate traps")
    }

    func testEditingBeforeApprovalKeepsBothTexts() throws {
        let candidate = file(F.candidate())
        let outcome = try approved(service.approve(
            candidateID: candidate.id, approver: reviewer,
            edits: .init(finding: "On a cold start the pressure-switch tubing sweats and the switch reads open")))
        XCTAssertEqual(outcome.state, .editedAndApproved(entryID: outcome.entry.id))
        XCTAssertEqual(outcome.entry.finding, "On a cold start the pressure-switch tubing sweats and the switch reads open")
        XCTAssertEqual(outcome.entry.captured,
                       LearningEntry.Texts(finding: candidate.finding, symptom: candidate.symptom, fix: candidate.fix))
        XCTAssertEqual(LearningReview.state(of: outcome.entry), .editedAndApproved(entryID: outcome.entry.id))

        // An edit that changes nothing is an approval as written.
        let second = file(F.candidate())
        let same = try approved(service.approve(candidateID: second.id, approver: reviewer,
                                                edits: .init(finding: second.finding)))
        XCTAssertEqual(same.state, .approved(entryID: same.entry.id))
        XCTAssertNil(same.entry.captured)
    }

    func testApprovalTextFollowsTheContractRules() {
        let candidate = file(F.candidate())
        let tooLong = String(repeating: "x", count: LearningCandidateText.findingLimit + 1)
        guard case .failure(.text(.tooLong(.finding, _, _))) = service.approve(
            candidateID: candidate.id, approver: reviewer, edits: .init(finding: tooLong)) else {
            return XCTFail("an over-length finding is refused whole")
        }
        XCTAssertEqual(service.approve(candidateID: candidate.id,
                                       approver: .init(name: "Ari", role: " ")).failureValue, .missingRole)
        XCTAssertEqual(service.approve(candidateID: candidate.id,
                                       approver: .init(name: "Ari", role: String(repeating: "r", count: 81))).failureValue,
                       .roleTooLong(count: 81))
        XCTAssertTrue(entries.entries.isEmpty)
        XCTAssertEqual(candidates.candidate(id: candidate.id)?.status, .filed, "nothing changed on a refusal")
    }

    func testACandidateWithNoMachineNeedsASubjectNamed() throws {
        let candidate = file(F.candidate(model: nil, spokenModel: nil))
        XCTAssertEqual(service.approve(candidateID: candidate.id, approver: reviewer).failureValue, .subjectNeeded)
        let practice = try approved(service.approve(candidateID: candidate.id, approver: reviewer,
                                                    subject: .practice(topic: "Cold starts")))
        XCTAssertEqual(practice.entry.subject, .practice(topic: "Cold starts"))
        XCTAssertEqual(practice.entry.citationName, "Team learning · Cold starts · 2026-10-10 · approved by Service manager")
    }

    func testAWithdrawnCandidateCannotBeReviewed() {
        let candidate = file(F.candidate(status: .withdrawn))
        XCTAssertEqual(service.approve(candidateID: candidate.id, approver: reviewer).failureValue, .candidateWithdrawn)
        XCTAssertEqual(service.reject(candidateID: candidate.id, reason: "x").failureValue, .candidateWithdrawn)
    }

    func testAnApprovedCandidateCannotBeApprovedTwice() throws {
        let candidate = file(F.candidate())
        let first = try approved(service.approve(candidateID: candidate.id, approver: reviewer))
        guard case .failure(.invalidTransition(.approved(first.entry.id), _)) =
                service.approve(candidateID: candidate.id, approver: reviewer) else {
            return XCTFail("a second approval is refused")
        }
        XCTAssertEqual(entries.entries.count, 1)
    }

    // MARK: - Who may approve

    func testTheAuthorCannotApproveTheirOwnFindingOffAReviewerDevice() {
        let candidate = file(F.candidate(author: "Sam Tane"))
        reviewerDevice = false
        let refusal = service.approve(candidateID: candidate.id,
                                      approver: .init(name: "  sam   TANE ", role: "Technician")).failureValue
        XCTAssertEqual(refusal, .authorIsApprover)
        XCTAssertTrue(refusal?.spoken.contains("reviewer device") ?? false)
        XCTAssertTrue(entries.entries.isEmpty)
        XCTAssertEqual(service.merge(candidateID: candidate.id, into: "nope",
                                     approver: .init(name: "Sam Tane", role: "Technician")).failureValue,
                       .unknownEntry("nope"))
    }

    func testOnAReviewerDeviceTheAuthorMayApproveAndTheRecordSaysSo() throws {
        let candidate = file(F.candidate(author: "Sam Tane"))
        reviewerDevice = true
        let outcome = try approved(service.approve(candidateID: candidate.id,
                                                   approver: .init(name: "Sam Tane", role: "Owner")))
        XCTAssertTrue(outcome.entry.authorIsApprover)
        XCTAssertEqual(outcome.entry.approvedByRole, "Owner")
    }

    func testTheReviewerDeviceSettingIsOffByDefaultAndDeclaredForProfiles() {
        let previous = UserDefaults.standard.object(forKey: "teamLearningReviewerDevice")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "teamLearningReviewerDevice") }
            else { UserDefaults.standard.removeObject(forKey: "teamLearningReviewerDevice") }
        }
        UserDefaults.standard.removeObject(forKey: "teamLearningReviewerDevice")
        XCTAssertFalse(Config.teamLearningReviewerDevice, "a field phone is not a reviewer device")
        Config.teamLearningReviewerDevice = true
        XCTAssertTrue(Config.teamLearningReviewerDevice)
        XCTAssertEqual(SettingKey.teamLearningReviewerDevice.rawValue, "teamLearningReviewerDevice",
                       "the profile key is the stored key")
        XCTAssertEqual(SettingKey.teamLearningReviewerDevice.kind, .ceiling(pinnedTo: false),
                       "an organisation may pin a phone off as a reviewer; naming one is a later decision")
        XCTAssertNotEqual(SettingKey.teamLearningReviewerDevice.ceilingDescription, "teamLearningReviewerDevice")
    }

    // MARK: - Merge (decision 3 of 2026-10-09)

    func testMergingAddsTheJobAndRaisesTheCountWithoutASecondEntry() throws {
        let first = file(F.candidate(session: "job-1"))
        let entry = try approved(service.approve(candidateID: first.id, approver: reviewer)).entry
        let citation = entry.citationName
        let documentText = documents.fullText(documentId: LearningCorpus.documentId(entryID: entry.id, vaultId: F.vaultId))

        let second = file(F.candidate(session: "job-2", author: "Kiri Ngata"))
        let merged = try service.merge(candidateID: second.id, into: entry.id, approver: reviewer).get()
        XCTAssertEqual(merged.id, entry.id)
        XCTAssertEqual(merged.sourceJobIDs, ["job-1", "job-2"])
        XCTAssertEqual(merged.confirmedJobCount, 2)
        XCTAssertEqual(merged.citationName, citation, "the citation does not change")
        XCTAssertEqual(entries.entries.count, 1, "no duplicate entry")
        XCTAssertEqual(documents.documentCount(namespace: DocumentStore.learningNamespace(F.vaultId)), 1)
        XCTAssertEqual(documents.fullText(documentId: LearningCorpus.documentId(entryID: entry.id, vaultId: F.vaultId)),
                       documentText, "the document is unchanged; the lead-in's count reads the entry")
        let stored = try XCTUnwrap(candidates.candidate(id: second.id))
        XCTAssertEqual(stored.status, .merged)
        XCTAssertEqual(stored.entryID, entry.id)
        XCTAssertEqual(LearningReview.state(of: stored), .merged(into: entry.id))

        // A third from a job already counted joins nothing new.
        let third = file(F.candidate(session: "job-2", author: "Kiri Ngata"))
        let again = try service.merge(candidateID: third.id, into: entry.id, approver: reviewer).get()
        XCTAssertEqual(again.confirmedJobCount, 2)
        XCTAssertEqual(again.sourceJobIDs, ["job-1", "job-2"])

        // A retracted entry takes no merges.
        _ = try service.retract(entryID: entry.id, reason: "Superseded by the new board").get()
        let fourth = file(F.candidate(session: "job-3"))
        XCTAssertEqual(service.merge(candidateID: fourth.id, into: entry.id, approver: reviewer).failureValue,
                       .entryNotLive(entry.id))
    }

    func testMergeSuggestionsMatchSubjectAndNormalisedFinding() {
        let live = F.entry(finding: "The pressure switch tubing   sweats and reads OPEN on a cold start")
        var retracted = F.entry(finding: "The pressure switch tubing sweats and reads open on a cold start")
        retracted.retractedAt = now
        let otherModel = F.entry(subject: .model(modelToken: F.model070),
                                 finding: "The pressure switch tubing sweats and reads open on a cold start")
        let otherFinding = F.entry(finding: "The inducer bearing squeals below freezing")
        let candidate = F.candidate(model: " slp99uh090xv60ck ")
        let suggested = LearningReview.mergeSuggestions(for: candidate, among: [live, retracted, otherModel, otherFinding])
        XCTAssertEqual(suggested, [live.id], "same model by identity, same finding once case and spacing are set aside")

        candidates.add(candidate)
        entries.upsert(live)
        XCTAssertEqual(service.mergeSuggestions(candidateID: candidate.id), [live.id])

        let practice = F.entry(subject: .practice(topic: "Cold starts"), finding: "Warm the board first")
        XCTAssertTrue(LearningReview.sameSubject(practice.subject, .practice(topic: "cold   STARTS")))
        XCTAssertFalse(LearningReview.sameSubject(practice.subject, .model(modelToken: "Cold starts")))
    }

    // MARK: - Safety

    func testASafetyCollisionIsSurfacedAndPublishingItNeedsASecondConfirmation() throws {
        let candidate = file(F.candidate(finding: "Jumper the rollout switch to confirm the inducer pulls in, then remove it",
                                         symptom: nil, fix: nil))
        let finding = try XCTUnwrap(service.safetyCheck(candidateID: candidate.id))
        XCTAssertTrue(finding.collides)
        XCTAssertTrue(finding.terms.contains("jumper"), "\(finding.terms)")
        XCTAssertTrue(finding.terms.contains("rollout"), "the safety file's own heading words count")
        XCTAssertEqual(finding.files, ["safety.md"])

        // Surfaced, never rejected: the first approval asks again and changes nothing.
        guard case .failure(.safetyConfirmationNeeded(let surfaced)) =
                service.approve(candidateID: candidate.id, approver: reviewer) else {
            return XCTFail("a collision needs the second confirmation")
        }
        XCTAssertEqual(surfaced, finding)
        XCTAssertTrue(entries.entries.isEmpty)
        XCTAssertEqual(candidates.candidate(id: candidate.id)?.status, .filed)

        let outcome = try approved(service.approve(candidateID: candidate.id, approver: reviewer,
                                                   confirmsSafetyDeparture: true))
        XCTAssertTrue(outcome.entry.contradictsSafetyNote)
        XCTAssertEqual(outcome.safety, finding)
    }

    func testAFindingClearOfTheSafetyCoreNeedsNoSecondConfirmation() throws {
        let benign = LearningSafetyCheck.check(finding: "The condensate trap clogs with algae in summer",
                                               symptom: nil, fix: "Flush it every spring",
                                               coreFiles: [("safety.md", F.safetyCore)])
        XCTAssertFalse(benign.collides)
        XCTAssertEqual(benign, .none)
        // Only files named for safety are read, as the prompt builder reads them.
        let notSafety = LearningSafetyCheck.check(finding: "Check the panel lockout", symptom: nil, fix: nil,
                                                  coreFiles: [("models.md", "## Lockout procedure")])
        XCTAssertEqual(notSafety.files, [], "a heading outside a safety file is not the safety core")
        XCTAssertEqual(notSafety.terms, ["lockout"], "the fixed hazard list still applies")

        let candidate = file(F.candidate(finding: "The condensate trap clogs with algae in summer", symptom: nil, fix: nil))
        let outcome = try approved(service.approve(candidateID: candidate.id, approver: reviewer))
        XCTAssertFalse(outcome.entry.contradictsSafetyNote)
    }

    // MARK: - A model the vault does not know (contract §7.2)

    func testAnUnknownModelIsFlaggedAndNotPublishedToThatVault() throws {
        service.vaults = {
            [LearningCorpus.VaultTarget(id: F.vaultId, modelIndex: F.modelIndex()),
             LearningCorpus.VaultTarget(id: "other_vault", modelIndex: F.modelIndex([("models.md", "## XR15CUTOFF\n")]))]
        }
        let candidate = file(F.candidate())
        let preview = try XCTUnwrap(service.placementPreview(candidateID: candidate.id, vaultIDs: []))
        XCTAssertEqual(preview.published, [F.vaultId])
        XCTAssertEqual(preview.unknownModel, ["other_vault"], "flagged before approval")

        let outcome = try approved(service.approve(candidateID: candidate.id, approver: reviewer, vaultIDs: []))
        XCTAssertEqual(outcome.entry.vaultIDs, [], "empty means every vault")
        XCTAssertEqual(outcome.placement.published, [F.vaultId])
        XCTAssertEqual(outcome.placement.unknownModel, ["other_vault"])
        XCTAssertEqual(documents.documentCount(namespace: DocumentStore.learningNamespace(F.vaultId)), 1)
        XCTAssertEqual(documents.documentCount(namespace: DocumentStore.learningNamespace("other_vault")), 0,
                       "never published blind")

        // A model spoken but never resolved is unknown everywhere it is not a vault's model.
        let spoken = file(F.candidate(model: nil, spokenModel: "Rheem 090"))
        let held = try approved(service.approve(candidateID: spoken.id, approver: reviewer))
        XCTAssertEqual(held.placement.published, [])
        XCTAssertEqual(held.placement.unknownModel, [F.vaultId])
        XCTAssertEqual(documents.documentCount(namespace: DocumentStore.learningNamespace(F.vaultId)), 1)

        // A practice entry has no model to know.
        let practice = file(F.candidate(model: nil))
        let published = try approved(service.approve(candidateID: practice.id, approver: reviewer,
                                                     subject: .practice(topic: "Cold starts"), vaultIDs: []))
        XCTAssertEqual(published.placement.published.sorted(), [F.vaultId, "other_vault"])
    }

    // MARK: - Reject

    func testRejectingRecordsTheReasonForTheAuthor() throws {
        let candidate = file(F.candidate())
        let rejected = try service.reject(candidateID: candidate.id, reason: " Already on page 12 of the manual ").get()
        XCTAssertEqual(rejected.status, .notTakenUp)
        XCTAssertEqual(rejected.reviewReason, "Already on page 12 of the manual")
        XCTAssertEqual(LearningReview.state(of: rejected), .rejected(reason: "Already on page 12 of the manual"))
        XCTAssertEqual(service.reject(candidateID: candidate.id, reason: "again").failureValue,
                       .invalidTransition(from: .rejected(reason: "Already on page 12 of the manual"),
                                          action: .reject(reason: "again")))
        XCTAssertTrue(entries.entries.isEmpty)
    }

    // MARK: - Gates

    func testTheCapabilityGateRefusesReviewAndPublishWithTheChecksReason() {
        let candidate = file(F.candidate())
        licence = .notIncluded(held: [.bundledVaults, .ownVaults])
        XCTAssertEqual(service.approve(candidateID: candidate.id, approver: reviewer).failureValue,
                       .notEntitled(FieldAssistPaywallCopy.teamLearningsReviewNotIncluded))
        licence = .denied(.expired(now))
        XCTAssertEqual(service.reject(candidateID: candidate.id, reason: "x").failureValue,
                       .notEntitled(FieldAssistPaywallCopy.teamLearningsReviewLapsed))
        licence = .denied(.noEvidence)
        XCTAssertEqual(service.approve(candidateID: candidate.id, approver: reviewer).failureValue,
                       .notEntitled(FieldAssistPaywallCopy.teamLearningsReviewLocked))
        XCTAssertTrue(entries.entries.isEmpty)
        XCTAssertEqual(documents.documentCount(namespace: DocumentStore.learningNamespace(F.vaultId)), 0)
        XCTAssertEqual(candidates.candidate(id: candidate.id)?.status, .filed)
    }

    func testRetractionIsNotGatedSoALapsedLicenceCanStillTakeAnAnswerOutOfService() throws {
        let candidate = file(F.candidate())
        let entry = try approved(service.approve(candidateID: candidate.id, approver: reviewer)).entry
        licence = .denied(.expired(now))
        let retracted = try service.retract(entryID: entry.id, reason: "Wrong board revision").get()
        XCTAssertNotNil(retracted.retractedAt)
        XCTAssertEqual(documents.documentCount(namespace: DocumentStore.learningNamespace(F.vaultId)), 0)
    }

    func testHIPAAModeRefusesReviewAndPublish() throws {
        let candidate = file(F.candidate())
        hipaa = true
        let refusal = service.approve(candidateID: candidate.id, approver: reviewer).failureValue
        XCTAssertEqual(refusal, .hipaa)
        XCTAssertTrue(refusal?.spoken.contains("HIPAA") ?? false)
        XCTAssertEqual(service.reject(candidateID: candidate.id, reason: "x").failureValue, .hipaa)
        XCTAssertTrue(entries.entries.isEmpty)

        // An entry already held is not republished while HIPAA mode is on.
        entries.upsert(F.entry())
        service.republish()
        XCTAssertEqual(documents.documentCount(namespace: DocumentStore.learningNamespace(F.vaultId)), 0)
        hipaa = false
        service.republish()
        XCTAssertEqual(documents.documentCount(namespace: DocumentStore.learningNamespace(F.vaultId)), 1)
    }

    // MARK: - Storage

    func testTheEntryStoreIsProtectedExcludedFromBackupAndSurvivesARestart() throws {
        entries.upsert(F.entry(finding: "Board resets when the inducer starts"))
        let values = try entries.fileLocation.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertEqual(SensitiveStore.learningEntries.record.backupExcluded, true)
        XCTAssertEqual(SensitiveStore.learningEntries.record.subjectLinkage, .thirdPartySubject)
        let reopened = LearningEntryStore(directory: root.appendingPathComponent("entries", isDirectory: true))
        XCTAssertEqual(reopened.entries, entries.entries)
        XCTAssertEqual(reopened.deleteMatching("inducer"), 1)
        XCTAssertTrue(reopened.entries.isEmpty)
    }
}

private extension Result {
    /// The failure, or nil on success — for asserting a refusal's case in one line.
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
