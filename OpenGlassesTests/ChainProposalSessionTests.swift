import XCTest
@testable import OpenGlasses

/// Plan JJ P3 end to end, over the invented vault of P2's session tests: a chain the model proposes
/// from passages retrieved on the job, read back, changed, run through the same runner, filed
/// marked unreviewed, kept on the phone, shared as a `chains.md` fragment with no office, filed for
/// review as well when the office is configured, superseded by a reviewed chain of the same name,
/// and a running chain resumed after a relaunch. Every table, rule, passage and value is invented.
@MainActor
final class ChainProposalSessionTests: XCTestCase {

    private typealias F = ChainProposalFixtures

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var exports: StagedExportCoordinator!
    private static let vaultId = "chain_proposal_test"

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChainProposalSessionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        exports = StagedExportCoordinator(channel: .fieldSessionExport,
                                          rootDirectoryName: "ChainProposalSessionTests-\(UUID().uuidString.prefix(8))")
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        VaultImporter.uninstall(id: Self.vaultId)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: exports.root)
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    // MARK: - The vault and the job

    private func vaultFolder(chains: String) throws -> URL {
        let dir = tempRoot.appendingPathComponent("vault-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let docs = dir.appendingPathComponent("documents", isDirectory: true)
        _ = try TableFixtures.write(TableFixtures.pdf([TableFixtures.prosePage(), TableFixtureLayouts.simpleGrid(printed: "12"),
                                                       TableFixtureLayouts.twoLevelHeader(),
                                                       TableFixtureLayouts.unitsInHeader(),
                                                       TableFixtureLayouts.groupingBands()]),
                                    named: "a.pdf", in: docs)
        let manifest = VaultManifest(
            id: Self.vaultId, name: "Chain Proposal Test", version: "1.0.0",
            files: ["safety.md", "chains.md"], proceduresDir: nil, documentsDir: "documents",
            documents: [VaultDocument(file: "a.pdf", title: F.book)],
            gating: .init(iap: "enterprise"), promptRules: ["Never fabricate.", "Cite the source."])
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try "# Safety\n\nIsolate before work.".write(to: dir.appendingPathComponent("safety.md"),
                                                     atomically: true, encoding: .utf8)
        try chains.write(to: dir.appendingPathComponent("chains.md"), atomically: true, encoding: .utf8)
        return dir
    }

    private struct Job {
        let service: FieldSessionService
        let store: DocumentStore
        let sessions: URL
        let candidates: LearningCandidateStore
    }

    private func startJob(chains: String = RuleChainFixtures.chainsMarkdown, office: Bool = false) async throws -> Job {
        let storeDir = tempRoot.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = DocumentStore(directory: storeDir)
        let report = try VaultImporter.installReporting(from: try vaultFolder(chains: chains))
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        _ = try await VaultImporter.syncDocuments(manifest: report.manifest, into: store)

        let sessions = tempRoot.appendingPathComponent("sessions", isDirectory: true)
        let service = makeService(sessions: sessions, store: store)
        let candidates = LearningCandidateStore(directory: tempRoot.appendingPathComponent("candidates", isDirectory: true))
        let review = LearningCandidateService(store: candidates, sessions: service)
        review.capability = { .granted }
        review.authorName = { "Technician" }
        service.chainReviewCandidates = review
        service.chainOfficeConfigured = { office }
        _ = try service.startSession(vaultId: report.manifest.id, assetId: nil, jobReference: "1042")
        return Job(service: service, store: store, sessions: sessions, candidates: candidates)
    }

    private func makeService(sessions: URL, store: DocumentStore) -> FieldSessionService {
        let service = FieldSessionService(sessionsRoot: sessions)
        service.documentStore = store
        service.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        service.sourceCenter = ShowSourceCenter()
        service.sourceCenter.isAppActive = { true }
        service.sourceCenter.announce = { _ in }
        return service
    }

    /// The invented passages, as `manual_lookup` would have noted them on this job.
    private func retrieve(_ job: Job) throws {
        let documentId = try XCTUnwrap(job.store.list(namespace: DocumentStore.vaultNamespace(Self.vaultId)).first?.id)
        job.service.sourceCenter.noteLookup(F.retrieved(documentId: documentId), sessionId: job.service.activeSession?.id)
    }

    private func propose(_ args: [String: Any], _ job: Job) async throws -> String {
        try await ProposeChainTool(documentStore: job.store, sessionService: job.service).execute(args: args)
    }

    private func chain(_ args: [String: Any], _ job: Job) async throws -> String {
        try await RuleChainFixtures.run(RuleChainTool(documentStore: job.store, sessionService: job.service,
                                                      settings: { DeliverySettings() }, exports: exports),
                                        args, job.service)
    }

    private var proposal: [String: Any] {
        ["action": "propose", "chain": F.steps, "name": F.name, "answers": F.answers, "sources": F.sources]
    }

    /// Propose, change step 2 to ask for the ambient, start and answer through to the result.
    private func proposeChangeAndRun(_ job: Job) async throws -> String {
        try retrieve(job)
        _ = try await propose(proposal, job)
        _ = try await propose(["action": "change", "step": 2, "text": F.askAmbient], job)
        _ = try await chain(["action": "start", "chain": F.name], job)
        var last = ""
        for answer in ["32", "14", "5", "2"] {
            last = try await chain(["action": "answer", "value": answer], job)
        }
        return last
    }

    // MARK: - Proposing and running

    func testAProposalIsReadBackChangedAndRunThroughTheRunnerAndItsReadBackIsFiledMarkedProposed() async throws {
        let job = try await startJob()

        // With nothing retrieved, nothing can be proposed.
        let early = try await propose(proposal, job)
        XCTAssertTrue(early.hasPrefix("Not proposed: Nothing has been retrieved on this job"), early)

        // The prompt says how to propose, beside the chains the vault offers.
        let idle = try XCTUnwrap(job.service.promptContext())
        XCTAssertTrue(idle.contains("RULE CHAINS this vault offers"), idle)
        XCTAssertTrue(idle.contains("PROPOSING A CHAIN: when the technician's question is about a table or a rule and no "
                                    + "chain above answers it, first retrieve the clauses with manual_lookup"), idle)

        try retrieve(job)
        let readBack = try await propose(proposal, job)
        XCTAssertTrue(readBack.hasPrefix("Proposed chain: \(F.name) (proposed, unreviewed)\n"), readBack)
        XCTAssertTrue(readBack.contains("— follows Rule QR-14 — from \(F.book), page 7, §QR-14"), readBack)
        XCTAssertTrue(readBack.contains("Never run it without their go."), readBack)
        XCTAssertNil(job.service.activeChain, "a proposal runs nothing")
        let waiting = try XCTUnwrap(job.service.promptContext())
        XCTAssertTrue(waiting.contains("PROPOSED RULE CHAIN — \(F.name) (proposed, unreviewed), read back and waiting"), waiting)
        let listed = try await chain(["action": "list"], job)
        XCTAssertTrue(listed.contains("• \(F.name) (proposed, unreviewed: waiting for the technician's go)"), listed)

        // "Ask me the ambient instead."
        let changed = try await propose(["action": "change", "step": 2, "text": F.askAmbient], job)
        XCTAssertTrue(changed.contains("2. Ask for ambient: What is the ambient temperature along the run?"), changed)

        let started = try await chain(["action": "start", "chain": F.name], job)
        XCTAssertTrue(started.hasPrefix("Started the chain '\(F.name)' (proposed, unreviewed)."), started)
        let asking = try XCTUnwrap(job.service.promptContext())
        XCTAssertTrue(asking.contains("ACTIVE RULE CHAIN — \(F.name) (proposed, unreviewed) (step 1 of 9):"), asking)
        XCTAssertNil(job.service.pendingProposal, "started, it no longer waits for go")

        var done = ""
        for answer in ["32", "14", "5", "2"] {
            done = try await chain(["action": "answer", "value": answer], job)
        }
        XCTAssertTrue(done.contains("Finished. Say the result: Use QMX90 › two conductors: rated 45 A"), done)
        XCTAssertTrue(done.contains("Say that this chain is proposed, unreviewed"), done)
        XCTAssertTrue(done.contains("rule_chain 'keep' keeps it on this phone"), done)

        let reading = try XCTUnwrap(job.service.activeSession?.spokenReadings.last)
        XCTAssertEqual(reading.quantity, "chain: \(F.name) (proposed, unreviewed)")
        XCTAssertTrue(reading.isRuleChain)
        let lines = reading.value.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Chain: \(F.name) (proposed, unreviewed)")
        XCTAssertEqual(lines[1], "Proposed from the passages retrieved: band from \(F.book), page 6, §QR-12; factor from "
                       + "\(F.book), page 7, §QR-14; size from \(F.book), page 8, §QR-17")
        XCTAssertEqual(lines[2], "1. load: 32 A, as the technician said")
        XCTAssertTrue(reading.value.contains("— follows Rule QR-14"), reading.value)
        let summary = WorkRecord(session: try XCTUnwrap(job.service.activeSession), vaultName: "Chain Proposal Test").summary
        XCTAssertTrue(summary.contains("Rule chains worked on this job:\n  Chain: \(F.name) (proposed, unreviewed)"), summary)
    }

    func testAProposalCitingARuleTheRetrievedPassagesLackIsRefusedOnTheJob() async throws {
        let job = try await startJob()
        try retrieve(job)
        var args = proposal
        args["chain"] = F.steps.replacingOccurrences(of: "cite Rule QR-17", with: "cite Rule QR-71")
        let refused = try await propose(args, job)
        XCTAssertTrue(refused.hasPrefix("Not proposed: The retrieved passages do not contain Rule QR-71."), refused)
        XCTAssertNil(job.service.pendingProposal)
        let start = try await chain(["action": "start", "chain": F.name], job)
        // Its words still fit an authored chain's name, which starts; the refused proposal does not.
        XCTAssertFalse(start.contains(F.name) || start.contains("proposed, unreviewed"), start)
        XCTAssertFalse(job.service.offeredChains.contains { $0.origin == .proposed })
    }

    // MARK: - Keeping, on the phone first

    func testKeepWithNoOfficeSavesOnThePhoneListsItUnreviewedSharesItAndQueuesNoBundle() async throws {
        let job = try await startJob(office: false)
        let nothing = try await chain(["action": "keep"], job)
        XCTAssertTrue(nothing.hasPrefix("There is no proposed chain that ran to a result"), nothing)

        _ = try await proposeChangeAndRun(job)
        let kept = try await chain(["action": "keep"], job)
        XCTAssertTrue(kept.hasPrefix("Kept '\(F.name)' on this phone, unreviewed — kept on this phone."), kept)
        XCTAssertFalse(kept.contains("office"), "no office here, so nothing is said about one: \(kept)")
        XCTAssertEqual(job.candidates.candidates, [], "with no office configured nothing is filed for a bundle")

        // In the vault's own folder on the phone, beside chains.md, and never a manifest file.
        let vault = try XCTUnwrap(job.service.activeVault)
        XCTAssertEqual(KeptChains.read(store: vault).map(\.name), [F.name])
        XCTAssertFalse(vault.manifest.files.contains(KeptChains.fileName))
        XCTAssertFalse(try XCTUnwrap(job.service.promptContext()).contains("lookup factor = Table 98"),
                       "a kept chain is offered by name, never read in as text")

        let list = try await chain(["action": "list"], job)
        XCTAssertTrue(list.contains("• \(F.name) (unreviewed — kept on this phone)"), list)
        XCTAssertTrue(list.contains("• Size a conductor for a load\n"), "the authored chains are still offered")
        XCTAssertTrue(try XCTUnwrap(job.service.promptContext()).contains("- \(F.name) (unreviewed — kept on this phone)"))

        // It runs like any other chain, and files marked as kept.
        let started = try await chain(["action": "start", "chain": F.name], job)
        XCTAssertTrue(started.hasPrefix("Started the chain '\(F.name)' (unreviewed — kept on this phone)."), started)
        for answer in ["32", "14", "5", "2"] { _ = try await chain(["action": "answer", "value": answer], job) }
        XCTAssertEqual(job.service.activeSession?.spokenReadings.last?.quantity,
                       "chain: \(F.name) (unreviewed — kept on this phone)")

        // Shared by the share sheet as a chains.md the P2 parser accepts — no office, no endpoint.
        let shared = try await chain(["action": "share"], job)
        XCTAssertTrue(shared.contains("ready to share as a chains.md file"), shared)
        let request = try XCTUnwrap(job.service.stagedDelivery)
        XCTAssertEqual(request.channel, .shareSheet)
        XCTAssertEqual(request.payload.ruleChains?.names, [F.name])
        let file = try XCTUnwrap(request.attachments.first)
        XCTAssertEqual(file.kind, .chainsMarkdown)
        XCTAssertEqual(file.filename, "chains.md")
        let text = try String(contentsOf: file.url, encoding: .utf8)
        let parsed = ChainParser.parse(text)
        XCTAssertEqual(parsed.problems, [], text)
        XCTAssertEqual(parsed.chains.map(\.name), [F.name])
        XCTAssertNil(request.payload.queuedOp(), "nothing is queued for an endpoint")
        XCTAssertEqual(job.candidates.candidates, [], "and still no bundle")

        // On another job on this phone, the kept chain is still offered.
        _ = try job.service.endSession(outcome: .resolved)
        _ = try job.service.startSession(vaultId: Self.vaultId, assetId: nil, jobReference: "1043")
        let later = try await chain(["action": "list"], job)
        XCTAssertTrue(later.contains("(unreviewed — kept on this phone)"), later)
        let keepAgain = try await chain(["action": "keep"], job)
        XCTAssertTrue(keepAgain.hasPrefix("There is no proposed chain that ran to a result on this job"), keepAgain)
    }

    func testKeepWithTheOfficeConfiguredAlsoFilesTheFragmentForTheBundle() async throws {
        let job = try await startJob(office: true)
        _ = try await proposeChangeAndRun(job)
        let kept = try await chain(["action": "keep"], job)
        XCTAssertTrue(kept.contains("A copy is filed for your office's review"), kept)
        XCTAssertEqual(KeptChains.read(store: try XCTUnwrap(job.service.activeVault)).map(\.name), [F.name],
                       "kept on the phone first, office or not")

        let candidate = try XCTUnwrap(job.candidates.candidates.first)
        XCTAssertEqual(job.candidates.candidates.count, 1)
        XCTAssertTrue(candidate.finding.contains("## \(F.name)"), candidate.finding)
        let fragment = String(candidate.finding[try XCTUnwrap(candidate.finding.range(of: "# Rule chains kept"))
            .lowerBound...])
        XCTAssertEqual(ChainParser.parse(fragment).chains.map(\.name), [F.name], "the fragment reads as chains.md")
        XCTAssertNil(candidate.equipment, "nothing else from the job rides with it")
        XCTAssertEqual(candidate.evidence, LearningCandidate.Evidence())
        XCTAssertNil(candidate.symptom)
        XCTAssertEqual(candidate.jobReference, "1042")

        let outbox = LearningBundleOutbox(candidates: job.candidates,
                                          entries: LearningEntryStore(directory: tempRoot.appendingPathComponent("entries")))
        outbox.capability = { .granted }
        outbox.hipaaMode = { false }
        let bundle = try outbox.composeCandidates().get()
        XCTAssertEqual(bundle.candidates.map(\.finding), [candidate.finding], "it goes in the team-learning bundle")
    }

    func testAReviewedChainOfTheSameNameInChainsMdSupersedesTheKeptOne() async throws {
        let job = try await startJob()
        _ = try await proposeChangeAndRun(job)
        _ = try await chain(["action": "keep"], job)
        XCTAssertEqual(job.service.keptChains.map(\.name), [F.name])

        // The organisation reviews it and adds it to chains.md under the same name; the vault is
        // pushed again.
        let reviewed = RuleChainFixtures.chainsMarkdown + "\n\n" + ChainProposal.markdown(
            name: F.name, answers: "the reviewed answer.", stepLines: [
                "ask load (A) range 1..400: What load?", "say \"Reviewed: {load} A.\""])
        _ = try VaultImporter.installReporting(from: try vaultFolder(chains: reviewed))
        VaultRegistry.shared.reloadUserManifests()

        XCTAssertEqual(job.service.keptChains, [], "the reviewed chain supersedes the kept one")
        let list = try await chain(["action": "list"], job)
        XCTAssertTrue(list.contains("• \(F.name)\n"), list)
        XCTAssertFalse(list.contains("kept on this phone"), list)
        XCTAssertEqual(list.components(separatedBy: "• \(F.name)").count, 2, "offered once: \(list)")
        let started = try await chain(["action": "start", "chain": F.name], job)
        XCTAssertTrue(started.hasPrefix("Started the chain '\(F.name)'.\n"), "the authored one, unmarked: \(started)")
    }

    // MARK: - A relaunch mid-chain

    func testARunningChainSurvivesARelaunchAtTheSameStepAndFilesNothingUntilItEnds() async throws {
        let job = try await startJob()
        _ = try await chain(["action": "start", "chain": "Size a conductor for a load"], job)
        _ = try await chain(["action": "answer", "value": "4000"], job)
        _ = try await chain(["action": "answer", "value": "32"], job)
        _ = try await chain(["action": "answer", "value": "14 °C"], job)
        let readings = job.service.activeSession?.spokenReadings.count
        XCTAssertEqual(job.service.activeSession?.ruleChainRun?.answers, ["4000", "32", "14 °C"])

        // The app is killed and relaunched: a new service over the same sessions folder restores the
        // job from its record, and the chain with it.
        let relaunched = makeService(sessions: job.sessions, store: job.store)
        XCTAssertEqual(relaunched.activeSession?.id, job.service.activeSession?.id)
        let run = try XCTUnwrap(relaunched.activeChain)
        XCTAssertEqual(run.state.position, 2)
        XCTAssertEqual(run.chain.name, "Size a conductor for a load")
        let status = try await RuleChainTool(documentStore: job.store, sessionService: relaunched).execute(args: ["action": "status"])
        XCTAssertTrue(status.contains("step 3 of 9") && status.contains("- ambient: 14 °C, as the technician said"), status)
        XCTAssertTrue(try XCTUnwrap(relaunched.promptContext()).contains("ACTIVE RULE CHAIN — Size a conductor for a load (step 3 of 9):"))
        XCTAssertEqual(relaunched.activeSession?.spokenReadings.count, readings, "nothing filed mid-chain")

        let tool = RuleChainTool(documentStore: job.store, sessionService: relaunched)
        _ = try await RuleChainFixtures.run(tool, ["action": "answer", "value": "5"], relaunched)
        let done = try await RuleChainFixtures.run(tool, ["action": "answer", "value": "2"], relaunched)
        XCTAssertTrue(done.contains("Finished. Say the result: Use QMX90 › two conductors"), done)
        XCTAssertEqual(relaunched.activeSession?.spokenReadings.count, (readings ?? 0) + 1)
        XCTAssertNil(relaunched.activeSession?.ruleChainRun, "an ended chain is no longer kept with the job")
        XCTAssertNil(makeService(sessions: job.sessions, store: job.store).activeChain, "and does not come back")
    }

    func testAProposedChainResumesAfterARelaunchStillMarked() async throws {
        let job = try await startJob()
        try retrieve(job)
        _ = try await propose(proposal, job)
        _ = try await chain(["action": "start", "chain": F.name], job)
        _ = try await chain(["action": "answer", "value": "32"], job)

        let relaunched = makeService(sessions: job.sessions, store: job.store)
        let run = try XCTUnwrap(relaunched.activeChain)
        XCTAssertEqual(run.origin, .proposed)
        XCTAssertEqual(run.sources["factor"], "\(F.book), page 7, §QR-14")
        XCTAssertEqual(run.state.position, 2, "the assumed ambient is worked, and it waits on the conductors")
        let stopped = try await RuleChainTool(documentStore: job.store, sessionService: relaunched).execute(args: ["action": "stop"])
        XCTAssertTrue(stopped.contains("Nothing was recorded"), stopped)
        XCTAssertNil(makeService(sessions: job.sessions, store: job.store).activeChain)
    }
}
