import CryptoKit
import XCTest
@testable import OpenGlasses

/// Plan DZ P2 — the acquisition pipeline end to end, against a temp directory and a fake transport.
///
/// The five exit criteria drive the file:
///  - curated and custom imports use the same state machine;
///  - pause/relaunch/resume preserves progress, from persisted bytes rather than a callback;
///  - size, digest, redirect, traversal and revision mismatches cannot produce `.complete`;
///  - cancellation and deletion affect only the selected plan; and
///  - the app recovers cleanly from termination during each transition.
///
/// No test touches the network, and none exercises a `.shared` service.
final class LocalModelDownloadManagerTests: XCTestCase {

    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    /// Extra roots created mid-test, so nothing is left in the temp directory afterwards.
    private var scratchRoots: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dz-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "dz.download.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        for scratch in scratchRoots { try? FileManager.default.removeItem(at: scratch) }
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    // MARK: - Exit criterion 1: one state machine for both origins

    func testCuratedAndImportedModelsInstallThroughTheSamePipeline() async throws {
        for origin in [LocalModelDownloadPlan.Origin.curatedCatalog, .repositoryImport] {
            let body = Data("weights-\(origin.rawValue)".utf8)
            let repository = makeRepository()
            let transfer = FakeFileTransfer(body: body)
            let manager = makeManager(repository: repository, transfer: transfer)
            let descriptor = descriptor(for: body, id: "owner/repo#\(origin.rawValue).gguf")

            let plan = try await manager.createPlan(descriptor: descriptor, origin: origin,
                                                    fit: fit(descriptor))
            _ = try await manager.grantConsent(planID: plan.id)
            let outcome = await manager.run(planID: plan.id)
            let finished = try XCTUnwrap(outcome)

            XCTAssertEqual(finished.state, .installed, origin.rawValue)
            let installation = try XCTUnwrap(repository.installation(for: descriptor.id))
            XCTAssertEqual(installation.validatedFiles.count, 1)
            XCTAssertEqual(installation.descriptor.revision, descriptor.revision)
            // The weights are where the backend will look for them, byte-identical.
            let installed = repository.directory(for: installation)
                .appendingPathComponent("model.gguf")
            XCTAssertEqual(try Data(contentsOf: installed), body)
            // And the plan directory is gone once nothing depends on it.
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: repository.stagingRoot.appendingPathComponent(plan.id.uuidString).path))
        }
    }

    func testOnlyOnePlanMayBeActiveAtATime() async throws {
        let repository = makeRepository()
        let manager = makeManager(repository: repository, transfer: FakeFileTransfer(body: Data("a".utf8)))
        let first = try await manager.createPlan(descriptor: descriptor(for: Data("a".utf8)),
                                                 origin: .curatedCatalog,
                                                 fit: fit(descriptor(for: Data("a".utf8))))
        let second = descriptor(for: Data("b".utf8), id: "owner/repo#second.gguf")
        do {
            _ = try await manager.createPlan(descriptor: second, origin: .repositoryImport,
                                             fit: fit(second))
            XCTFail("a second concurrent plan must be refused")
        } catch let error as LocalModelDownloadManager.ManagerError {
            XCTAssertEqual(error, .anotherPlanActive(first.id))
        }
    }

    func testAPlanIsRefusedWhenTheFitReportSaysNo() async throws {
        let repository = makeRepository()
        let manager = makeManager(repository: repository, transfer: FakeFileTransfer(body: Data()))
        let descriptor = descriptor(for: Data("a".utf8))
        // The unreadable-free-space case: the fit is not installable, so no plan exists at all.
        let refusedFit = LocalModelFitReport.make(.init(descriptor: descriptor,
                                                        availableStorageBytes: nil,
                                                        availableProcessBytes: 8_000_000_000))
        do {
            _ = try await manager.createPlan(descriptor: descriptor, origin: .repositoryImport,
                                             fit: refusedFit)
            XCTFail("an uninstallable fit must not produce a plan")
        } catch let error as LocalModelDownloadManager.ManagerError {
            XCTAssertEqual(error, .fitRefused([.freeSpaceUnreadable]))
        }
        let plans = await manager.plans()
        XCTAssertTrue(plans.isEmpty)
    }

    func testConsentIsRequiredBeforeAnyByteMoves() async throws {
        let body = Data("weights".utf8)
        let repository = makeRepository()
        let transfer = FakeFileTransfer(body: body)
        let manager = makeManager(repository: repository, transfer: transfer)
        let descriptor = descriptor(for: body, license: LocalModelLicenseSummary(
            displayName: "Custom", summary: "…", requiresAcceptance: true, revision: "rev-1"))

        let plan = try await manager.createPlan(
            descriptor: descriptor, origin: .repositoryImport,
            fit: fit(descriptor, acceptedLicenseRevision: "rev-1"))

        // Consent for the wrong revision, and no consent at all, both leave the plan where it was.
        await XCTAssertThrowsErrorAsync(try await manager.grantConsent(planID: plan.id))
        await XCTAssertThrowsErrorAsync(
            try await manager.grantConsent(planID: plan.id, acceptedLicenseRevision: "rev-0"))
        let unconsentedOutcome = await manager.run(planID: plan.id)
        let unconsented = try XCTUnwrap(unconsentedOutcome)
        XCTAssertEqual(unconsented.state, .failed(.terminal(.consentMissing)))
        let requests = await transfer.requestedIdentifiers
        XCTAssertTrue(requests.isEmpty, "nothing may be fetched before consent")

        XCTAssertNil(repository.installation(for: descriptor.id))
    }

    // MARK: - Exit criterion 3: mismatches cannot produce `.complete`

    func testSizeMismatchCannotProduceAnInstallation() async throws {
        let (repository, plan) = try await runPlan(body: Data("weights".utf8)) { transfer in
            await transfer.setResponse(.init(body: Data("weights-but-longer".utf8)))
        }
        XCTAssertEqual(plan.state, .failed(.terminal(.sizeMismatch)))
        assertNothingInstalled(repository)
    }

    func testDigestMismatchCannotProduceAnInstallation() async throws {
        // Same length, different bytes: only the digest can catch this one.
        let (repository, plan) = try await runPlan(body: Data("weights".utf8)) { transfer in
            await transfer.setResponse(.init(body: Data("WEIGHTS".utf8)))
        }
        XCTAssertEqual(plan.state, .failed(.terminal(.digestMismatch)))
        assertNothingInstalled(repository)
    }

    func testARedirectToAnotherHostCannotProduceAnInstallation() async throws {
        let body = Data("weights".utf8)
        let (repository, plan) = try await runPlan(body: body) { transfer in
            await transfer.setResponse(.init(body: body,
                                             finalURL: URL(string: "https://evil.example/model.gguf")))
        }
        XCTAssertEqual(plan.state, .failed(.terminal(.redirectHostRejected)))
        assertNothingInstalled(repository)
    }

    func testAnInsecureFinalURLCannotProduceAnInstallation() async throws {
        let body = Data("weights".utf8)
        let (repository, plan) = try await runPlan(body: body) { transfer in
            await transfer.setResponse(.init(body: body,
                                             finalURL: URL(string: "http://huggingface.co/model.gguf")))
        }
        XCTAssertEqual(plan.state, .failed(.terminal(.insecureRedirect)))
        assertNothingInstalled(repository)
    }

    func testAnErrorStatusFailsRetryablyAndInstallsNothing() async throws {
        let body = Data("weights".utf8)
        let (repository, plan) = try await runPlan(body: body) { transfer in
            await transfer.setResponse(.init(body: body, statusCode: 503))
        }
        XCTAssertEqual(plan.state, .failed(.retryable(.httpStatus)))
        assertNothingInstalled(repository)
    }

    func testAnUnpinnedRevisionCannotProduceAnInstallationAndNeverReachesTheNetwork() async throws {
        let body = Data("weights".utf8)
        let repository = makeRepository()
        let transfer = FakeFileTransfer(body: body)
        let manager = makeManager(repository: repository, transfer: transfer)
        // A branch name passes the descriptor's own fault check (it is "pinned" in the sense of not
        // being the legacy sentinel) but can never resolve to an exact file URL.
        let descriptor = descriptor(for: body, revision: "main")

        let plan = try await manager.createPlan(descriptor: descriptor, origin: .repositoryImport,
                                                fit: fit(descriptor))
        _ = try await manager.grantConsent(planID: plan.id)
        let outcome = await manager.run(planID: plan.id)
        let finished = try XCTUnwrap(outcome)

        XCTAssertEqual(finished.state, .failed(.terminal(.revisionMismatch)))
        let requests = await transfer.requestedIdentifiers
        XCTAssertTrue(requests.isEmpty)
        assertNothingInstalled(repository)
    }

    func testATraversalPathInAStoredPlanIsRefusedBeforeAnyRequest() async throws {
        let repository = makeRepository()
        let transfer = FakeFileTransfer(body: Data("weights".utf8))
        let manager = makeManager(repository: repository, transfer: transfer)

        // A plan whose file escapes its own staging directory cannot be built through the public
        // API, so it is written straight to disk — the shape a tampered or corrupted plan has.
        let planID = UUID()
        try writeRawPlan(planID: planID, in: repository, state: ["name": "queued"]) { stored in
            var json = stored
            var files = (json["files"] as? [[String: Any]]) ?? []
            files[0]["relativePath"] = "../../escape.gguf"
            json["files"] = files
            return json
        }

        let outcome = await manager.run(planID: planID)
        let finished = try XCTUnwrap(outcome)
        XCTAssertEqual(finished.state, .failed(.terminal(.containmentRefused)))
        let requests = await transfer.requestedIdentifiers
        XCTAssertTrue(requests.isEmpty, "containment is checked before the fetch, not after")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("escape.gguf").path))
    }

    // MARK: - Exit criterion 4: cancellation and deletion are scoped

    func testCancellationTouchesOnlyTheSelectedPlan() async throws {
        let repository = makeRepository()
        let transfer = FakeFileTransfer(body: Data("weights".utf8))
        let manager = makeManager(repository: repository, transfer: transfer)

        let cancelled = UUID()
        let bystander = UUID()
        try writeRawPlan(planID: cancelled, in: repository, state: ["name": "queued"])
        try writeRawPlan(planID: bystander, in: repository, state: ["name": "awaitingConsent"])

        let cancelOutcome = await manager.cancel(planID: cancelled)
        let result = try XCTUnwrap(cancelOutcome)
        XCTAssertEqual(result.state, .cancelled)
        let cancelledPlans = await transfer.cancelledPlans
        XCTAssertEqual(cancelledPlans, [cancelled], "only the selected plan's tasks are cancelled")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repository.stagingRoot.appendingPathComponent(cancelled.uuidString).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repository.stagingRoot.appendingPathComponent(bystander.uuidString).path))
    }

    func testDeletionRemovesOnlyTheSelectedModelAndUnloadsItFirst() async throws {
        let repository = makeRepository()
        let unloaded = UnloadRecorder()
        let manager = makeManager(repository: repository,
                                  transfer: FakeFileTransfer(body: Data("a".utf8)),
                                  unloadIfResident: { id in await unloaded.record(id) })

        let keptID = try await install(body: Data("kept".utf8), id: "owner/repo#kept.gguf",
                                       repository: repository)
        let doomedID = try await install(body: Data("doomed".utf8), id: "owner/repo#doomed.gguf",
                                          repository: repository)

        try await manager.deleteInstallation(doomedID)

        XCTAssertNil(repository.installation(for: doomedID))
        XCTAssertNotNil(repository.installation(for: keptID))
        let recorded = await unloaded.ids
        XCTAssertEqual(recorded, [doomedID], "the model is released before its files go")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.directory(for: doomedID).path))

        // Deleting something that is not installed is a typed error, not a silent success.
        await XCTAssertThrowsErrorAsync(
            try await manager.deleteInstallation(LocalModelID("owner/repo#never.gguf"))) {
            XCTAssertEqual($0 as? LocalModelDownloadManager.ManagerError,
                           .installationNotFound(LocalModelID("owner/repo#never.gguf")))
        }
    }

    // MARK: - Exit criterion 2: pause, relaunch, resume

    func testProgressSurvivesRelaunchAndOnlyTheUnfinishedFileIsRefetched() async throws {
        let repository = makeRepository()
        let first = Data("first-file".utf8)
        let second = Data("second-file".utf8)
        let descriptor = descriptor(files: [(name: "a.gguf", body: first), (name: "b.gguf", body: second)])

        // The state a termination mid-download leaves: one file staged and validated, the plan
        // recorded as working on the second.
        let planID = UUID()
        var plan = try XCTUnwrap(LocalModelDownloadPlan(descriptor: descriptor,
                                                        origin: .curatedCatalog, id: planID))
        plan.markValidated(fileIndex: 0, byteCount: Int64(first.count))
        plan.state = .downloading(fileIndex: 1)
        try writePlan(plan, in: repository)
        let filesDirectory = repository.stagingRoot.appendingPathComponent(planID.uuidString)
            .appendingPathComponent(LocalModelDownloadPlan.filesDirectoryName)
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        try first.write(to: filesDirectory.appendingPathComponent("a.gguf"))

        // A fresh manager, as after a relaunch: no in-memory callbacks survive, only the plan file.
        let transfer = FakeFileTransfer(body: second)
        let manager = makeManager(repository: repository, transfer: transfer)
        let restored = await manager.restore()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].recovery, .resumeDownload(fileIndex: 1))
        XCTAssertEqual(restored[0].plan.completedBytes, Int64(first.count),
                       "progress comes from the bytes on disk, not from a callback")
        XCTAssertGreaterThan(restored[0].plan.fractionCompleted, 0)

        let outcome = await manager.run(planID: planID)
        let finished = try XCTUnwrap(outcome)
        XCTAssertEqual(finished.state, .installed)
        let requested = await transfer.requestedIdentifiers
        XCTAssertEqual(requested, [LocalModelTransferIdentifier(planID: planID, fileIndex: 1)],
                       "a validated file is not fetched again")
    }

    func testAStagedFileThatNoLongerMatchesIsNotTrustedAfterRelaunch() async throws {
        let repository = makeRepository()
        let body = Data("weights".utf8)
        let planID = UUID()
        var plan = try XCTUnwrap(LocalModelDownloadPlan(descriptor: descriptor(for: body),
                                                        origin: .curatedCatalog, id: planID))
        plan.markValidated(fileIndex: 0, byteCount: Int64(body.count))
        plan.state = .installing
        try writePlan(plan, in: repository)
        // The staged file is truncated — the bytes the digest was computed over are gone.
        let filesDirectory = repository.stagingRoot.appendingPathComponent(planID.uuidString)
            .appendingPathComponent(LocalModelDownloadPlan.filesDirectoryName)
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        try Data("wei".utf8).write(to: filesDirectory.appendingPathComponent("model.gguf"))

        let manager = makeManager(repository: repository, transfer: FakeFileTransfer(body: body))
        let restored = await manager.restore()
        XCTAssertEqual(restored.first?.recovery, .resumeDownload(fileIndex: 0))
        assertNothingInstalled(repository)
    }

    // MARK: - Exit criterion 5: recovery from termination at every transition

    func testRecoveryFromTerminationAtEveryTransition() async throws {
        let states: [(name: String, extra: [String: Any], expected: LocalModelDownloadPlan.Recovery)] = [
            ("planned", [:], .awaitUser),
            ("awaitingConsent", [:], .awaitUser),
            ("queued", [:], .resumeDownload(fileIndex: 0)),
            ("downloading", ["fileIndex": 0], .resumeDownload(fileIndex: 0)),
            ("validating", ["fileIndex": 0], .resumeDownload(fileIndex: 0)),
            ("installing", [:], .resumeDownload(fileIndex: 0)),
            ("installed", [:], .discard),
            ("cancelled", [:], .discard),
            ("failed", ["failureReason": "transport", "isRetryable": true], .offerRetry(.transport)),
            ("failed", ["failureReason": "digestMismatch", "isRetryable": false], .discard),
        ]

        for testCase in states {
            // A fresh root per row: plans from earlier rows would otherwise still be on disk and
            // the "nothing left" assertions would be about the wrong plan.
            scratchRoots.append(root)
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("dz-download-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let repository = makeRepository()
            let manager = makeManager(repository: repository,
                                      transfer: FakeFileTransfer(body: Data("weights".utf8)))
            let planID = UUID()
            var state: [String: Any] = ["name": testCase.name]
            state.merge(testCase.extra) { _, new in new }
            try writeRawPlan(planID: planID, in: repository, state: state)

            let restored = await manager.restore()
            let mine = restored.first { $0.plan.id == planID }
            switch testCase.expected {
            case .discard:
                XCTAssertNil(mine, "\(testCase.name) should be discarded")
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: repository.stagingRoot.appendingPathComponent(planID.uuidString).path))
            default:
                XCTAssertEqual(mine?.recovery, testCase.expected, testCase.name)
            }
            // Whatever the state, nothing was published as installed by recovering.
            assertNothingInstalled(repository)
        }
    }

    func testAnInstallInterruptedAfterTheMoveIsFinishedByRecovery() async throws {
        // The one interruption that leaves files in place without a marker: the directory moved,
        // the process died before `.complete`. Recovery must finish it, not fail it.
        let repository = makeRepository()
        let body = Data("weights".utf8)
        let descriptor = descriptor(for: body)
        let planID = UUID()
        var plan = try XCTUnwrap(LocalModelDownloadPlan(descriptor: descriptor,
                                                        origin: .curatedCatalog, id: planID))
        plan.markValidated(fileIndex: 0, byteCount: Int64(body.count))
        plan.state = .installing
        try writePlan(plan, in: repository)

        // Files and manifest already in the installed directory; marker absent.
        let installed = repository.directory(for: descriptor.id)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try body.write(to: installed.appendingPathComponent("model.gguf"))
        let installation = InstalledLocalModel(
            descriptor: descriptor,
            storage: .managed(directoryName: descriptor.id.storageComponent),
            installedAt: Date(timeIntervalSince1970: 1_000),
            validatedFiles: plan.files.map(\.modelFile))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(installation)
            .write(to: installed.appendingPathComponent(LocalModelRepository.manifestFileName))

        XCTAssertNil(repository.installation(for: descriptor.id),
                     "without the marker the model is not installed — the marker is written last")

        let manager = makeManager(repository: repository, transfer: FakeFileTransfer(body: body))
        _ = await manager.restore()
        XCTAssertNotNil(repository.installation(for: descriptor.id))
    }

    func testTheMarkerIsTheLastThingWrittenSoAHalfInstallIsNeverPresented() throws {
        let repository = makeRepository()
        let body = Data("weights".utf8)
        let descriptor = descriptor(for: body)
        let staging = repository.stagingRoot.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try body.write(to: staging.appendingPathComponent("model.gguf"))

        let installation = InstalledLocalModel(
            descriptor: descriptor,
            storage: .managed(directoryName: descriptor.id.storageComponent),
            installedAt: Date(timeIntervalSince1970: 1_000),
            validatedFiles: descriptor.files)
        try repository.install(installation, movingContentsOf: staging)

        let directory = repository.directory(for: descriptor.id)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(LocalModelRepository.completionMarkerName).path))
        XCTAssertNotNil(repository.installation(for: descriptor.id))

        // Remove the marker and the installation disappears from view, files and manifest intact.
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(LocalModelRepository.completionMarkerName))
        XCTAssertNil(repository.installation(for: descriptor.id))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("model.gguf").path))
    }

    func testReinstallingReplacesTheDirectoryWithoutEverLosingBothCopies() throws {
        let repository = makeRepository()
        let descriptor = descriptor(for: Data("v1".utf8))
        for body in [Data("v1".utf8), Data("v2-longer".utf8)] {
            let staging = repository.stagingRoot
                .appendingPathComponent("staged-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try body.write(to: staging.appendingPathComponent("model.gguf"))
            try repository.install(InstalledLocalModel(
                descriptor: descriptor,
                storage: .managed(directoryName: descriptor.id.storageComponent),
                installedAt: Date(timeIntervalSince1970: 1_000),
                validatedFiles: descriptor.files), movingContentsOf: staging)
            XCTAssertNotNil(repository.installation(for: descriptor.id))
        }
        let installed = repository.directory(for: descriptor.id).appendingPathComponent("model.gguf")
        XCTAssertEqual(try Data(contentsOf: installed), Data("v2-longer".utf8))
    }

    // MARK: - Digest

    func testDigestIsStreamedAndAgreesWithTheOneShotHash() throws {
        // Bigger than the read chunk, so the incremental path is the one under test.
        var body = Data()
        for index in 0..<(LocalModelDigest.chunkBytes / 8 + 1_000) {
            withUnsafeBytes(of: UInt64(index)) { body.append(contentsOf: $0) }
        }
        let url = root.appendingPathComponent("big.bin")
        try body.write(to: url)
        let expected = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try LocalModelDigest.sha256(ofFileAt: url), expected)
    }

    // MARK: - Helpers

    private func makeRepository() -> LocalModelRepository {
        LocalModelRepository(root: root, defaults: defaults, legacyModelIDs: { [] },
                             now: { Date(timeIntervalSince1970: 2_000) })
    }

    private func makeManager(repository: LocalModelRepository,
                             transfer: FakeFileTransfer,
                             unloadIfResident: @escaping @Sendable (LocalModelID) async -> Void = { _ in })
        -> LocalModelDownloadManager {
        LocalModelDownloadManager(repository: repository,
                                  transfer: transfer,
                                  now: { Date(timeIntervalSince1970: 2_000) },
                                  unloadIfResident: unloadIfResident)
    }

    /// Run a single-file plan whose transport is configured by `configure`, returning the outcome.
    private func runPlan(body: Data,
                         configure: (FakeFileTransfer) async -> Void)
        async throws -> (LocalModelRepository, LocalModelDownloadPlan) {
        let repository = makeRepository()
        let transfer = FakeFileTransfer(body: body)
        await configure(transfer)
        let manager = makeManager(repository: repository, transfer: transfer)
        let descriptor = descriptor(for: body)
        let plan = try await manager.createPlan(descriptor: descriptor, origin: .repositoryImport,
                                                fit: fit(descriptor))
        _ = try await manager.grantConsent(planID: plan.id)
        let outcome = await manager.run(planID: plan.id)
        return (repository, try XCTUnwrap(outcome))
    }

    /// Install a model through the real pipeline, returning its id.
    private func install(body: Data, id: String,
                         repository: LocalModelRepository) async throws -> LocalModelID {
        let manager = makeManager(repository: repository, transfer: FakeFileTransfer(body: body))
        let descriptor = descriptor(for: body, id: id)
        let plan = try await manager.createPlan(descriptor: descriptor, origin: .curatedCatalog,
                                                fit: fit(descriptor))
        _ = try await manager.grantConsent(planID: plan.id)
        let outcome = await manager.run(planID: plan.id)
        let finished = try XCTUnwrap(outcome)
        XCTAssertEqual(finished.state, .installed)
        return descriptor.id
    }

    private func assertNothingInstalled(_ repository: LocalModelRepository,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(repository.installedModels().isEmpty,
                      "no failure path may publish an installation", file: file, line: line)
        let markers = (try? FileManager.default.subpathsOfDirectory(atPath: root.path))?
            .filter { $0.hasSuffix(LocalModelRepository.completionMarkerName) } ?? []
        XCTAssertTrue(markers.isEmpty, "a `.complete` marker exists where it must not",
                      file: file, line: line)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func descriptor(for body: Data,
                            id: String = "owner/repo#model.gguf",
                            revision: String = String(repeating: "b", count: 40),
                            license: LocalModelLicenseSummary = .unverified) -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: LocalModelID(id),
            displayName: "Test model",
            runtime: .llamaCpp,
            repositoryID: "owner/repo",
            revision: revision,
            files: [LocalModelFile(relativePath: "model.gguf",
                                   byteCount: Int64(body.count),
                                   sha256: sha256(body),
                                   role: .weights)],
            quantization: "Q4_K_M",
            capabilities: [.text],
            contextLength: 4096,
            estimatedWeightsBytes: Int64(body.count),
            estimatedWorkingBytes: 1,
            minimumHeadroomBytes: 0,
            license: license)
    }

    private func descriptor(files: [(name: String, body: Data)]) -> LocalModelDescriptor {
        LocalModelDescriptor(
            id: LocalModelID("owner/repo#multi.gguf"),
            displayName: "Multi-file model",
            runtime: .llamaCpp,
            repositoryID: "owner/repo",
            revision: String(repeating: "b", count: 40),
            files: files.map {
                LocalModelFile(relativePath: $0.name, byteCount: Int64($0.body.count),
                               sha256: sha256($0.body), role: .weights)
            },
            quantization: "Q4_K_M",
            capabilities: [.text],
            contextLength: 4096,
            estimatedWeightsBytes: Int64(files.reduce(0) { $0 + $1.body.count }),
            estimatedWorkingBytes: 1,
            minimumHeadroomBytes: 0)
    }

    private func fit(_ descriptor: LocalModelDescriptor,
                     acceptedLicenseRevision: String? = nil) -> LocalModelFitReport {
        LocalModelFitReport.make(.init(descriptor: descriptor,
                                       availableStorageBytes: 64_000_000_000,
                                       availableProcessBytes: 8_000_000_000,
                                       acceptedLicenseRevision: acceptedLicenseRevision))
    }

    private func writePlan(_ plan: LocalModelDownloadPlan,
                           in repository: LocalModelRepository) throws {
        let directory = repository.stagingRoot.appendingPathComponent(plan.id.uuidString,
                                                                      isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(plan).write(to: directory.appendingPathComponent(LocalModelDownloadPlan.fileName))
    }

    /// Write a plan straight to disk, optionally mangling the JSON — the shape a tampered or
    /// half-written plan file has, which the public API deliberately cannot produce.
    private func writeRawPlan(planID: UUID,
                              in repository: LocalModelRepository,
                              state: [String: Any],
                              transform: ([String: Any]) -> [String: Any] = { $0 }) throws {
        var plan = try XCTUnwrap(LocalModelDownloadPlan(descriptor: descriptor(for: Data("weights".utf8)),
                                                        origin: .curatedCatalog, id: planID))
        plan.state = .queued
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(plan))
                                    as? [String: Any])
        json["state"] = state
        json = transform(json)

        let directory = repository.stagingRoot.appendingPathComponent(planID.uuidString,
                                                                      isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent(LocalModelDownloadPlan.fileName))
    }
}

/// Records the ids handed to the unload hook, so "deletion releases the model first" is observable.
actor UnloadRecorder {
    private(set) var ids: [LocalModelID] = []
    func record(_ id: LocalModelID) { ids.append(id) }
}

/// A transport that answers from memory. Every field an outcome carries is settable, because the
/// manager's job is to re-check all of them.
actor FakeFileTransfer: LocalModelFileTransferring {

    struct Response {
        var body: Data
        var statusCode: Int = 200
        var finalURL: URL?
        /// Byte count the transport *claims*, when it should differ from what it wrote.
        var reportedBytes: Int64?
        var error: LocalModelFileTransferError?
    }

    private var response: Response
    private(set) var requestedIdentifiers: [LocalModelTransferIdentifier] = []
    private(set) var cancelledPlans: [UUID] = []
    private var live: [LocalModelTransferIdentifier] = []

    init(body: Data) {
        self.response = Response(body: body)
    }

    func setResponse(_ response: Response) { self.response = response }
    func setLiveIdentifiers(_ identifiers: [LocalModelTransferIdentifier]) { live = identifiers }

    func transfer(_ request: LocalModelFileTransferRequest) async throws -> LocalModelFileTransferOutcome {
        requestedIdentifiers.append(request.identifier)
        if let error = response.error { throw error }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-\(UUID().uuidString).part")
        try response.body.write(to: temporary)
        return LocalModelFileTransferOutcome(
            statusCode: response.statusCode,
            finalURL: response.finalURL ?? request.url,
            fileURL: temporary,
            byteCount: response.reportedBytes ?? Int64(response.body.count))
    }

    func cancelTasks(forPlan planID: UUID) async { cancelledPlans.append(planID) }

    func liveIdentifiers() async -> [LocalModelTransferIdentifier] { live }
}
