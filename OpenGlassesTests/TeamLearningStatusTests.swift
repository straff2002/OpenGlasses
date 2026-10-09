import XCTest
@testable import OpenGlasses

/// Plan FP P3 — the author hears what became of a finding (FP §2): the job it was filed on shows
/// *filed*, then *sent* once a bundle carrying it has left, then *approved* or *not taken up* once
/// the reviewer's decision is accepted — on the session and on its `WorkRecord`, for a job still
/// open and for one that has ended, and never with any of the finding's words.
///
/// Headless: a fresh `FieldSessionService` over a temporary directory, fresh stores, and the
/// outbox and intake wired to that service the way the app wires them to the shared one.
@MainActor
final class TeamLearningStatusTests: XCTestCase {

    private typealias F = TeamLearningFixtures

    private var root: URL!
    private var sessions: FieldSessionService!
    private var candidates: LearningCandidateStore!
    private var entries: LearningEntryStore!
    private var service: LearningCandidateService!
    private var outbox: LearningBundleOutbox!
    private var intake: LearningBundleIntake!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?
    private var previousHipaa = false

    override func setUp() {
        super.setUp()
        root = F.tempDirectory("TeamLearningStatus")
        previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousHipaa = Config.hipaaMode
        Config.hipaaMode = false
        previousEntitlement = EntitlementTestScope.grant(tier: .team)
        VaultRegistry.shared.resetCache()
        sessions = FieldSessionService(sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true))
        candidates = LearningCandidateStore(directory: root.appendingPathComponent("candidates", isDirectory: true))
        entries = LearningEntryStore(directory: root.appendingPathComponent("entries", isDirectory: true))
        service = LearningCandidateService(store: candidates, sessions: sessions)
        service.authorName = { "Sam Tane" }
        service.capability = { .granted }
        outbox = LearningBundleOutbox(candidates: candidates, entries: entries)
        outbox.capability = { .granted }
        outbox.hipaaMode = { false }
        outbox.exports = StagedExportCoordinator(channel: .fieldSessionExport,
                                                 rootDirectoryName: "TeamLearningStatus-\(UUID().uuidString.prefix(8))")
        outbox.recordStatus = { [unowned self] candidate in
            self.sessions.recordTeamLearning(.teamLearningStatus, reference: candidate.reference,
                                             sessionId: candidate.sessionId)
        }
        intake = LearningBundleIntake(candidates: candidates, entries: entries,
                                      documentStore: F.documentStore(in: root))
        intake.capability = { .granted }
        intake.hipaaMode = { false }
        intake.vaults = { [] }
        intake.recordStatus = { [unowned self] candidate, inUse in
            self.sessions.recordTeamLearning(.teamLearningStatus, reference: candidate.reference(inUse: inUse),
                                             sessionId: candidate.sessionId)
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: outbox.exports.root)
        intake = nil
        outbox = nil
        service = nil
        entries = nil
        candidates = nil
        sessions = nil
        try? FileManager.default.removeItem(at: root)
        if let previousEnabled { UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
        Config.hipaaMode = previousHipaa
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private let finding = "The pressure switch tubing sweats and reads open on a cold start"

    private func file(reference: String) throws -> (FieldSession, LearningCandidate) {
        let session = try sessions.startSession(vaultId: "refrigeration", assetId: nil, jobReference: reference)
        sessions.setEquipment(.init(modelToken: F.model090, heading: F.model090, file: "models.md", source: .spoken))
        let candidate = try service.note(finding: finding).get()
        return (session, candidate)
    }

    /// Send the phone's candidates and have the composer report a confirmed send.
    private func send() throws {
        let bundle = try outbox.composeCandidates().get()
        let request = try outbox.deliveryRequest(for: bundle, channel: .email, recipients: ["base@example.com"]).get()
        outbox.completed(request, outcome: .sent)
    }

    /// The reviewer's decisions arrive and are accepted.
    private func decide(_ status: LearningBundle.Status, entries list: [LearningEntry] = [],
                        issuedAt: Int64) throws {
        let data = LearningBundle(direction: .decisions, organisationLabel: "Northbridge", issuedAt: issuedAt,
                                  statuses: [status], entries: list.map(LearningBundle.Entry.init)).encoded()
        _ = try intake.receive(data).get()
        _ = try intake.acceptAll().get()
    }

    private func status(on sessionId: String) -> LearningCandidate.Status? {
        let session = sessions.activeSession?.id == sessionId ? sessions.activeSession
            : sessions.history.first { $0.id == sessionId }
        return session?.teamLearnings?.first?.status
    }

    private func recordStatus(_ sessionId: String) -> LearningCandidateReference? {
        (sessions.activeSession?.id == sessionId ? sessions.workRecord() : sessions.workRecord(sessionId: sessionId))?
            .teamLearnings?.first
    }

    private func events(_ sessionId: String) -> [SessionLogger.Event] {
        SessionLogger.readEvents(at: root.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true))
    }

    // MARK: - On a job still open

    func testAnOpenJobShowsFiledThenSentThenApproved() throws {
        let (session, candidate) = try file(reference: "WO-1")
        XCTAssertEqual(status(on: session.id), .filed)

        _ = try outbox.composeCandidates().get()
        XCTAssertEqual(status(on: session.id), .filed, "composing is not sending")

        try send()
        XCTAssertEqual(status(on: session.id), .sent)
        XCTAssertEqual(recordStatus(session.id)?.status, .sent)

        let entry = LearningEntry(subject: .model(modelToken: F.model090), vaultIDs: ["refrigeration"],
                                  finding: finding, approvedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                  approvedByRole: "Service manager", approvedByName: "Ari", candidateID: candidate.id)
        try decide(.init(candidateID: candidate.id, revision: 1, status: .approved, entryID: entry.id, reason: nil,
                         issuedAt: 1_800_000_100), entries: [entry], issuedAt: 1_800_000_200)
        XCTAssertEqual(status(on: session.id), .approved)
        let reference = try XCTUnwrap(recordStatus(session.id))
        XCTAssertEqual(reference.status, .approved)
        XCTAssertTrue(reference.inUse, "its entry answers on this phone now")

        let kinds = events(session.id).filter { $0.kind == .teamLearningStatus }
        XCTAssertEqual(kinds.compactMap { $0.payload?["status"]?.value as? String }.suffix(2), ["sent", "approved"])
        for event in events(session.id) where event.kind == .teamLearningStatus {
            XCTAssertNil(event.text, "a status event carries no text")
        }
        let json = String(decoding: try XCTUnwrap(sessions.workRecord()).json, as: UTF8.self)
        XCTAssertFalse(json.contains("sweats"), "the record carries the finding's existence, never its words")
    }

    // MARK: - On a job that has ended

    func testAnEndedJobShowsSentThenNotTakenUpThroughItsOwnLog() throws {
        let (first, candidate) = try file(reference: "WO-1")
        _ = try sessions.endSession()
        let second = try sessions.startSession(vaultId: "refrigeration", assetId: nil, jobReference: "WO-2")

        try send()
        XCTAssertEqual(status(on: first.id), .sent)
        XCTAssertNil(sessions.activeSession?.teamLearnings, "nothing lands on the job that happens to be open")

        try decide(.init(candidateID: candidate.id, revision: 1, status: .notTakenUp, entryID: nil,
                         reason: "Already covered by the manual", issuedAt: 1_800_000_100), issuedAt: 1_800_000_200)
        XCTAssertEqual(status(on: first.id), .notTakenUp)
        XCTAssertEqual(recordStatus(first.id)?.status, .notTakenUp)
        XCTAssertEqual(candidates.candidate(id: candidate.id)?.reviewReason, "Already covered by the manual",
                       "the author hears the reason from their own candidate")
        XCTAssertFalse(events(second.id).contains { $0.kind == .teamLearningStatus },
                       "a status goes only into the log of the job it was filed on")
        XCTAssertEqual(events(first.id).filter { $0.kind == .teamLearningStatus }.count, 2)

        // …and the ended job's record on disk says so after a restart.
        let restored = FieldSessionService(sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true))
        XCTAssertEqual(restored.history.first { $0.id == first.id }?.teamLearnings?.first?.status, .notTakenUp)
    }

    func testAMergedStatusIsShownAndIsFinal() throws {
        let (session, candidate) = try file(reference: "WO-1")
        try send()
        let entryID = LearningCandidate.newID()
        try decide(.init(candidateID: candidate.id, revision: 1, status: .merged, entryID: entryID, reason: nil,
                         issuedAt: 1_800_000_100), issuedAt: 1_800_000_200)
        XCTAssertEqual(status(on: session.id), .merged)
        XCTAssertEqual(recordStatus(session.id)?.inUse, false, "merged into an entry this phone does not hold yet")
        // A later, contradicting status changes nothing: the decision was final.
        let data = LearningBundle(direction: .decisions, issuedAt: 1_800_000_300,
                                  statuses: [.init(candidateID: candidate.id, revision: 1, status: .notTakenUp,
                                                   entryID: nil, reason: "Changed my mind", issuedAt: 1_800_000_250)]).encoded()
        _ = try intake.receive(data).get()
        _ = try intake.acceptAll().get()
        XCTAssertEqual(status(on: session.id), .merged)
    }
}
