import XCTest
@testable import OpenGlasses

/// W04.3 — consent is a versioned, withdrawable record tied to a purpose, a data class, a recipient
/// and an actor, and the three actors cannot stand in for one another.
///
/// The failure this is built against is the ordinary one: a wearer taps yes, and that yes is later
/// read as the agreement of the person in front of the lens, or as an organisation's authority to
/// process, or as still standing under terms that have since changed. Each of those is a separate
/// question here, and asking one and being handed the answer to another is not possible.
@MainActor
final class ConsentRecordTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_757_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("consent-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func record(purpose: ConsentPurpose = .remoteAction,
                        dataClass: ConsentDataClass = .none,
                        recipient: String = "gateway",
                        actor: ConsentActor = .wearer,
                        version: Int = 1,
                        granted: TimeInterval = 0,
                        withdrawn: TimeInterval? = nil) -> ConsentRecord {
        ConsentRecord(purpose: purpose, dataClass: dataClass, recipient: recipient, actor: actor,
                      version: version, grantedAt: epoch.addingTimeInterval(granted),
                      withdrawnAt: withdrawn.map(epoch.addingTimeInterval))
    }

    private func evaluate(_ records: [ConsentRecord], requiredVersion: Int = 1,
                          actor: ConsentActor = .wearer,
                          purpose: ConsentPurpose = .remoteAction,
                          dataClass: ConsentDataClass = .none,
                          recipient: String = "gateway") -> ConsentOutcome {
        ConsentPolicy.evaluate(purpose: purpose, dataClass: dataClass, recipient: recipient,
                               requiredVersion: requiredVersion, actor: actor, in: records,
                               at: epoch.addingTimeInterval(1000))
    }

    // MARK: - The four outcomes

    func testGrantedWhenALiveRecordCoversTheQuestion() {
        guard case .granted(let matched) = evaluate([record()]) else {
            return XCTFail("a live record at the required version is a grant")
        }
        XCTAssertEqual(matched.actor, .wearer)
        XCTAssertTrue(evaluate([record()]).allowsProcessing)
        XCTAssertFalse(evaluate([record()]).shouldPrompt)
    }

    func testNotGrantedWhenNothingCoversIt() {
        XCTAssertEqual(evaluate([]), .notGranted)
        XCTAssertTrue(ConsentOutcome.notGranted.shouldPrompt)
        XCTAssertFalse(ConsentOutcome.notGranted.allowsProcessing)
    }

    func testWithdrawnIsItsOwnAnswerNotAnAbsence() {
        let outcome = evaluate([record(withdrawn: 10)])
        XCTAssertEqual(outcome, .withdrawn(at: epoch.addingTimeInterval(10)))
        XCTAssertFalse(outcome.allowsProcessing)
        XCTAssertFalse(outcome.shouldPrompt,
                       "asking again the moment somebody says stop is not a consent surface")
    }

    func testAVersionBumpMakesAStandingAgreementStale() {
        let outcome = evaluate([record(version: 1)], requiredVersion: 2)
        XCTAssertEqual(outcome, .stale(recorded: 1, required: 2))
        XCTAssertFalse(outcome.allowsProcessing)
        XCTAssertTrue(outcome.shouldPrompt, "new terms are asked about, not assumed")
    }

    func testTheLatestRecordGovernsAndAWithdrawalIsNotUndoneByAnOlderYes() {
        let old = record(granted: 0)
        let newer = record(granted: 100, withdrawn: 200)
        XCTAssertEqual(evaluate([old, newer]), .withdrawn(at: epoch.addingTimeInterval(200)))
        XCTAssertEqual(evaluate([newer, old]), .withdrawn(at: epoch.addingTimeInterval(200)),
                       "the answer cannot depend on the order the rows happen to be in")
    }

    /// Consent is tied to purpose, data class *and* recipient. Agreeing that the gateway may act is
    /// not agreeing that an ops peer may, and agreeing to one purpose is not agreeing to another.
    func testPurposeDataClassAndRecipientMustAllMatch() {
        let granted = [record(purpose: .remoteAction, dataClass: .none, recipient: "gateway")]
        XCTAssertEqual(evaluate(granted, purpose: .captureSharing), .notGranted)
        XCTAssertEqual(evaluate(granted, dataClass: .imagery), .notGranted)
        XCTAssertEqual(evaluate(granted, recipient: "ops-peer:abcd1234"), .notGranted)
        XCTAssertTrue(evaluate(granted).allowsProcessing)
    }

    // MARK: - The actors cannot stand in for one another

    /// The wearer's own approval is not an answer about the subject, however sincerely it was
    /// given — and it does not become one by being the only record there is.
    func testAWearerApprovalDoesNotAnswerASubjectQuestion() {
        let wearer = [record(purpose: .subjectEnrolment, dataClass: .identity,
                             recipient: "on-device", actor: .wearer)]
        XCTAssertTrue(evaluate(wearer, actor: .wearer, purpose: .subjectEnrolment,
                               dataClass: .identity, recipient: "on-device").allowsProcessing)
        XCTAssertEqual(evaluate(wearer, actor: .subject, purpose: .subjectEnrolment,
                                dataClass: .identity, recipient: "on-device"),
                       .notGranted,
                       "a record by another actor is not a weaker match — it is not a match")
    }

    func testAWearerCannotAttestForASubject() {
        XCTAssertThrowsError(try SubjectConsentEvidence.fromEnterpriseAuthority(
            record(actor: .wearer))) { error in
            XCTAssertEqual(error as? ConsentAuthorityError, .wearerCannotAttestForSubject)
        }
    }

    func testASubjectIsNotAnAuthorityToEnrolOtherSubjects() {
        XCTAssertThrowsError(try SubjectConsentEvidence.fromEnterpriseAuthority(
            record(actor: .subject))) { error in
            XCTAssertEqual(error as? ConsentAuthorityError, .subjectIsNotAnAuthority)
        }
    }

    func testAWithdrawnEnterpriseAuthorityCannotAttest() {
        XCTAssertThrowsError(try SubjectConsentEvidence.fromEnterpriseAuthority(
            record(actor: .enterprise, withdrawn: 10))) { error in
            XCTAssertEqual(error as? ConsentAuthorityError, .authorityWithdrawn)
        }
    }

    func testALiveEnterpriseAuthorityIsTheOnlyWayToRecordASubjectEnrolment() throws {
        let authority = record(purpose: .subjectEnrolment, dataClass: .identity,
                               recipient: "on-device", actor: .enterprise)
        let evidence = try SubjectConsentEvidence.fromEnterpriseAuthority(authority)
        XCTAssertEqual(evidence.authorityRecordID, authority.id)

        let store = ConsentStore(directory: directory)
        let enrolment = store.recordSubjectEnrolment(purpose: .subjectEnrolment,
                                                     dataClass: .identity, recipient: "on-device",
                                                     version: 1, evidence: evidence, at: epoch)
        XCTAssertEqual(enrolment.actor, .subject)
        XCTAssertTrue(store.evaluate(purpose: .subjectEnrolment, dataClass: .identity,
                                     recipient: "on-device", requiredVersion: 1, actor: .subject,
                                     at: epoch.addingTimeInterval(1)).allowsProcessing)
    }

    /// A device permission is the wearer's own operating system letting this app use a sensor. It
    /// says nothing about the people in front of the lens, and there is deliberately nothing in the
    /// consent API that turns one into a record.
    func testOSCameraPermissionIsNotSubjectAgreement() {
        XCTAssertTrue(ConsentPolicy.osPermissionIsNotSubjectAgreement)
        // Whatever the OS has granted, a subject question with no subject record is notGranted.
        XCTAssertEqual(evaluate([], actor: .subject, purpose: .subjectEnrolment,
                                dataClass: .imagery, recipient: "on-device"),
                       .notGranted)
    }

    // MARK: - The store

    func testTheStoreRoundTripsWithdrawalAndIsProtectedAndBackupExcluded() throws {
        let store = ConsentStore(directory: directory)
        XCTAssertTrue(store.storageAvailable)

        let granted = store.recordWearerApproval(purpose: .remoteAction, dataClass: .none,
                                                 recipient: "gateway", version: 1, at: epoch)
        XCTAssertTrue(store.protectionApplied)
        let values = try store.storeURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)

        XCTAssertNotNil(store.withdraw(id: granted.id, at: epoch.addingTimeInterval(10)))
        // Withdrawing again does not move the time it happened.
        XCTAssertEqual(store.withdraw(id: granted.id, at: epoch.addingTimeInterval(99))?.withdrawnAt,
                       epoch.addingTimeInterval(10))

        let reopened = ConsentStore(directory: directory)
        XCTAssertEqual(reopened.records.count, 1)
        XCTAssertEqual(reopened.evaluate(purpose: .remoteAction, dataClass: .none,
                                         recipient: "gateway", requiredVersion: 1,
                                         at: epoch.addingTimeInterval(100)),
                       .withdrawn(at: epoch.addingTimeInterval(10)),
                       "a withdrawal survives a relaunch, which is the whole point of recording it")
    }

    func testWithdrawingAPurposeStopsEveryLiveAgreementUnderIt() {
        let store = ConsentStore(directory: directory)
        store.recordWearerApproval(purpose: .remoteAction, dataClass: .none, recipient: "gateway",
                                   version: 1, at: epoch)
        store.recordWearerApproval(purpose: .remoteAction, dataClass: .none,
                                   recipient: "coding-agent", version: 1, at: epoch)
        store.recordWearerApproval(purpose: .clinicalExport, dataClass: .health,
                                   recipient: "clinic", version: 1, at: epoch)

        XCTAssertEqual(store.withdrawAll(purpose: .remoteAction, at: epoch.addingTimeInterval(5)), 2)
        XCTAssertEqual(store.withdrawAll(purpose: .remoteAction, at: epoch.addingTimeInterval(6)), 0,
                       "withdrawing twice is not two withdrawals")
        XCTAssertTrue(store.evaluate(purpose: .clinicalExport, dataClass: .health,
                                     recipient: "clinic", requiredVersion: 1,
                                     at: epoch.addingTimeInterval(10)).allowsProcessing,
                      "an unrelated purpose is untouched")
    }

    func testAnUnreadableRegisterDoesNotReadAsNobodyHavingAgreed() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("consent-records.json"))

        let store = ConsentStore(directory: directory)
        XCTAssertFalse(store.storageAvailable)
        XCTAssertTrue(store.records.isEmpty)
        // The corrupt bytes are preserved rather than overwritten with an empty register.
        store.recordWearerApproval(purpose: .remoteAction, dataClass: .none, recipient: "gateway",
                                   version: 1, at: epoch)
        let onDisk = try String(contentsOf: directory.appendingPathComponent("consent-records.json"),
                                encoding: .utf8)
        XCTAssertEqual(onDisk, "not json")
    }

    // MARK: - Under the shared remote-action surface

    func testTheGateAsksTheFirstTimeAndRecordsTheAgreement() {
        let decision = RemoteActionConsentGate.decide(source: .gateway, records: [], at: epoch)
        XCTAssertTrue(decision.allowsPrompt)
        XCTAssertNil(decision.promptPrefix)
        XCTAssertTrue(decision.shouldRecordOnApproval)
        XCTAssertEqual(decision.outcome, .notGranted)
    }

    func testTheGateStopsAskingOnceTheAgreementStands() {
        let agreed = [record(recipient: RemoteActionConsentGate.recipient(for: .gateway))]
        let decision = RemoteActionConsentGate.decide(source: .gateway, records: agreed, at: epoch)
        XCTAssertTrue(decision.allowsPrompt)
        XCTAssertFalse(decision.shouldRecordOnApproval, "an agreement is recorded once, not per call")
    }

    /// The re-prompt a version bump is for: the wearer agreed under terms that no longer apply, so
    /// the ask says so and their answer is recorded at the current version.
    func testAVersionBumpRePromptsWithTheChangeNamed() {
        let underOldTerms = [record(recipient: RemoteActionConsentGate.recipient(for: .gateway),
                                    version: ConsentPurpose.remoteAction.currentVersion - 1)]
        let decision = RemoteActionConsentGate.decide(source: .gateway, records: underOldTerms,
                                                      at: epoch)
        XCTAssertTrue(decision.allowsPrompt)
        XCTAssertEqual(decision.promptPrefix, "What you agreed to has changed.")
        XCTAssertTrue(decision.shouldRecordOnApproval)
    }

    func testAWithdrawnSourceIsRefusedWithoutBeingAsked() {
        let stopped = [record(recipient: RemoteActionConsentGate.recipient(for: .gateway),
                              withdrawn: 10)]
        let decision = RemoteActionConsentGate.decide(source: .gateway, records: stopped,
                                                      at: epoch.addingTimeInterval(20))
        XCTAssertFalse(decision.allowsPrompt)
        XCTAssertFalse(decision.shouldRecordOnApproval)
        XCTAssertTrue(RemoteActionConsentGate.withdrawnMessage(tool: "capture_photo")
            .contains("Do not retry"))
    }

    /// Each source keeps its own agreement, and an ops peer's wearer-authored label is fingerprinted
    /// rather than stored.
    func testEachSourceHasItsOwnRecipientIdentity() {
        let identities = [RemoteActionSource.assistant, .codingAgent, .gateway,
                          .opsPeer(label: "Acme Ops")]
            .map(RemoteActionConsentGate.recipient(for:))
        XCTAssertEqual(Set(identities).count, 4)
        XCTAssertFalse(identities.contains { $0.contains("Acme") },
                       "a wearer-authored label is not stored verbatim in a consent record")
        XCTAssertNotEqual(RemoteActionConsentGate.recipient(for: .opsPeer(label: "Acme Ops")),
                          RemoteActionConsentGate.recipient(for: .opsPeer(label: "Other Ops")))
    }

    // MARK: - Through the coordinator

    func testTheCoordinatorRecordsTheWearersAgreementOnTheFirstYes() async {
        let store = ConsentStore(directory: directory)
        let coordinator = ToolConfirmationCoordinator(consentStore: store)
        let binding = coordinator.approvalGrants.binding(seam: .native, toolName: "capture_photo",
                                                         definitionDigest: "d1", args: [:])

        async let decision = coordinator.requestApproval(toolName: "capture_photo",
                                                         summary: "take a photo",
                                                         source: .gateway, binding: binding,
                                                         at: epoch)
        await answer(coordinator, approve: true)
        guard case .approved = await decision else { return XCTFail("approval expected") }

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.actor, .wearer)
        XCTAssertEqual(store.records.first?.recipient,
                       RemoteActionConsentGate.recipient(for: .gateway))
        XCTAssertEqual(store.records.first?.version, ConsentPurpose.remoteAction.currentVersion)
    }

    func testTheCoordinatorDoesNotEvenAskAfterAWithdrawal() async {
        let store = ConsentStore(directory: directory)
        let granted = store.recordWearerApproval(
            purpose: .remoteAction, dataClass: .none,
            recipient: RemoteActionConsentGate.recipient(for: .gateway), version: 1, at: epoch)
        store.withdraw(id: granted.id, at: epoch.addingTimeInterval(1))

        let coordinator = ToolConfirmationCoordinator(consentStore: store)
        let binding = coordinator.approvalGrants.binding(seam: .native, toolName: "capture_photo",
                                                         definitionDigest: "d1", args: [:])
        let decision = await coordinator.requestApproval(toolName: "capture_photo",
                                                         summary: "take a photo",
                                                         source: .gateway, binding: binding,
                                                         at: epoch.addingTimeInterval(10))
        XCTAssertEqual(decision, .consentWithdrawn)
        XCTAssertNil(coordinator.pending, "nothing was put in front of the wearer")
        XCTAssertEqual(coordinator.approvalGrants.liveGrantCount, 0)
    }

    private func answer(_ coordinator: ToolConfirmationCoordinator, approve: Bool) async {
        for _ in 0..<200 {
            if coordinator.pending != nil { coordinator.resolve(approve); return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("confirmation never became pending")
    }
}
