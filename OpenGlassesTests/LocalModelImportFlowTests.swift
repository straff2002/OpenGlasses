import XCTest
@testable import OpenGlasses

/// Plan DZ P2 — the import sheet's flow, and the announcements and diagnostics that go with the
/// download it starts.
///
/// The controller is driven against fakes end to end: parse → resolve → choose → licence → fit →
/// confirm. No network, no `.shared` service, no screen.
@MainActor
final class LocalModelImportFlowTests: XCTestCase {

    private let gigabyte: Int64 = 1_073_741_824
    private let revision = String(repeating: "c", count: 40)

    // MARK: - Parse refusals reach the sheet verbatim

    func testAParseRefusalIsShownInTheParsersOwnWords() async {
        let controller = makeController()
        for (input, expected): (String, LocalModelImportRejection) in [
            ("", .empty),
            ("http://huggingface.co/owner/repo", .disallowedScheme("http")),
            ("https://huggingface.co/owner/repo?token=abc", .queryNotAllowed),
            ("https://example.com/owner/repo", .disallowedHost("example.com")),
            ("huggingface.co/owner/repo", .missingScheme),
            ("https://huggingface.co/owner/repo/blob/main/f.gguf", .pathOutsideRepositoryForm),
        ] {
            controller.repositoryText = input
            await controller.resolve()
            guard case .failed(let message) = controller.stage else {
                return XCTFail("\(input) was not refused")
            }
            XCTAssertEqual(message, expected.localizedMessage,
                           "the refusal was reworded on its way to the sheet")
        }
    }

    func testARefusalNeverEchoesWhatWasTyped() async {
        let controller = makeController()
        controller.repositoryText = "https://evil.example.com/secret-token-abc123/repo"
        await controller.resolve()
        guard case .failed(let message) = controller.stage else { return XCTFail("not refused") }
        XCTAssertFalse(message.contains("secret-token-abc123"))
        XCTAssertFalse(message.contains("evil.example.com"))
    }

    // MARK: - Repository faults

    func testAGatedRepositoryIsRefusedWithTheFaultsOwnMessage() async {
        let controller = makeController(metadata: metadata(isGated: true))
        controller.repositoryText = "owner/repo"
        await controller.resolve()
        guard case .failed(let message) = controller.stage else { return XCTFail("not refused") }
        XCTAssertEqual(message, LocalModelImportFault.repositoryNotPublic.localizedMessage)
    }

    func testARepositoryWithNoCheckSummedFilesCannotBeImported() async {
        let controller = makeController(files: [
            LocalModelRemoteFile(path: "model-Q4_K_M.gguf", byteCount: 500_000_000, sha256: nil),
        ])
        controller.repositoryText = "owner/repo"
        await controller.resolve()
        guard case .failed(let message) = controller.stage else { return XCTFail("not refused") }
        XCTAssertEqual(message, LocalModelImportFault.noVerifiableFiles.localizedMessage)
    }

    // MARK: - Selection

    func testTheCuratedDefaultIsPreselectedAndGoesStraightToConfirmation() async {
        let controller = makeController()
        controller.repositoryText = "owner/repo"
        await controller.resolve()

        XCTAssertEqual(controller.selectedCandidateID, "model-Q4_K_M.gguf")
        XCTAssertEqual(controller.stage, .confirming)
        XCTAssertNotNil(controller.fit)
    }

    func testWithoutTheExactPreferredFileTheUserMustChoose() async {
        let controller = makeController(files: [
            file("model-Q5_K_M.gguf", bytes: 700_000_000),
            file("model-Q3_K_S.gguf", bytes: 300_000_000),
        ])
        controller.repositoryText = "owner/repo"
        await controller.resolve()

        XCTAssertEqual(controller.stage, .choosing)
        XCTAssertNil(controller.selectedCandidateID, "nobody chooses for the user but the user")
        XCTAssertEqual(controller.weightsCandidates.map(\.id),
                       ["model-Q3_K_S.gguf", "model-Q5_K_M.gguf"],
                       "smallest first, so the cheapest option reads first")

        controller.choose("model-Q5_K_M.gguf")
        XCTAssertEqual(controller.stage, .confirming)
        XCTAssertEqual(controller.descriptor?.quantization, "Q5_K_M")
    }

    func testProjectorsAreListedButNeverSelectable() async {
        let controller = makeController(files: [
            file("model-Q4_K_M.gguf"),
            file("mmproj-model-f16.gguf", bytes: 100_000_000),
        ])
        controller.repositoryText = "owner/repo"
        await controller.resolve()

        XCTAssertEqual(controller.projectorCandidates.count, 1)
        XCTAssertFalse(controller.weightsCandidates.contains { $0.id.contains("mmproj") })
    }

    // MARK: - Licence acceptance and the fit gate

    func testAnUnknownLicenceBlocksUntilItIsAcceptedAndThenPermits() async {
        // An identifier the app has not summarized requires acceptance — the honest reading of
        // "nobody here has read these terms".
        let controller = makeController(metadata: metadata(license: "some-bespoke-licence"))
        controller.repositoryText = "owner/repo"
        await controller.resolve()

        XCTAssertTrue(controller.requiresLicenceAcceptance)
        XCTAssertFalse(controller.canDownload)
        XCTAssertEqual(controller.fitPresentation?.blockerMessages,
                       [LocalModelFitReport.Blocker.licenseNotAccepted.localizedMessage])

        controller.licenceAccepted = true
        controller.licenceAcceptanceChanged()
        XCTAssertTrue(controller.canDownload, "ticking the box must actually unlock the action")
    }

    func testAPermissiveLicenceNeedsNoAcceptance() async {
        let controller = makeController(metadata: metadata(license: "apache-2.0"))
        controller.repositoryText = "owner/repo"
        await controller.resolve()
        XCTAssertFalse(controller.requiresLicenceAcceptance)
        XCTAssertTrue(controller.canDownload)
    }

    func testABlockerKeepsTheActionDisabledAndWarningsDoNot() async {
        // Unreadable free space blocks…
        let blocked = makeController(freeDiskBytes: nil)
        blocked.repositoryText = "owner/repo"
        await blocked.resolve()
        XCTAssertFalse(blocked.canDownload)

        // …while a memory verdict that says "probably won't fit" only warns.
        let warned = makeController(availableProcessBytes: 200_000_000)
        warned.repositoryText = "owner/repo"
        await warned.resolve()
        XCTAssertTrue(warned.canDownload)
        XCTAssertFalse(warned.fitPresentation?.warningMessages.isEmpty ?? true)
    }

    func testConfirmHandsThePipelineTheDescriptorAndTheAcceptedRevision() async {
        let started = StartedBox()
        let controller = makeController(metadata: metadata(license: "some-bespoke-licence"),
                                        started: started)
        controller.repositoryText = "owner/repo"
        await controller.resolve()
        controller.licenceAccepted = true
        controller.licenceAcceptanceChanged()
        await controller.confirm()

        XCTAssertEqual(started.descriptor?.repositoryID, "owner/repo")
        XCTAssertEqual(started.descriptor?.revision, revision, "pinned before any bytes move")
        XCTAssertEqual(started.descriptor?.capabilities, [.text],
                       "an import claims text and nothing else")
        XCTAssertEqual(started.acceptedRevision, revision)
        XCTAssertEqual(controller.stage, .started)
    }

    func testConfirmDoesNothingWhileABlockerStands() async {
        let started = StartedBox()
        let controller = makeController(freeDiskBytes: nil, started: started)
        controller.repositoryText = "owner/repo"
        await controller.resolve()
        await controller.confirm()
        XCTAssertNil(started.descriptor, "a blocked confirmation must not reach the pipeline")
    }

    // MARK: - Progress announcements

    func testProgressIsAnnouncedOnlyAfterEnoughMovementAndEnoughTime() {
        var announcer = LocalModelProgressAnnouncer(modelName: "Test model")
        let start = Date(timeIntervalSince1970: 0)

        XCTAssertNotNil(announcer.announcement(for: .progress(fraction: 0.12), at: start))
        // Same second, more movement: refused on the time floor.
        XCTAssertNil(announcer.announcement(for: .progress(fraction: 0.40), at: start))
        // Later, but not enough movement: refused on the percent floor.
        XCTAssertNil(announcer.announcement(for: .progress(fraction: 0.15),
                                            at: start.addingTimeInterval(60)))
        // Both floors cleared.
        XCTAssertNotNil(announcer.announcement(for: .progress(fraction: 0.40),
                                               at: start.addingTimeInterval(60)))
    }

    func testZeroPercentSaysNothing() {
        var announcer = LocalModelProgressAnnouncer(modelName: "Test model")
        XCTAssertNil(announcer.announcement(for: .progress(fraction: 0),
                                            at: Date(timeIntervalSince1970: 0)))
    }

    func testCompletionAndFailureIgnoreBothFloors() {
        var completed = LocalModelProgressAnnouncer(modelName: "Test model")
        let start = Date(timeIntervalSince1970: 0)
        _ = completed.announcement(for: .progress(fraction: 0.5), at: start)
        XCTAssertNotNil(completed.announcement(for: .completed, at: start),
                        "the event a person is actually waiting for is never suppressed")

        var failed = LocalModelProgressAnnouncer(modelName: "Test model")
        _ = failed.announcement(for: .progress(fraction: 0.5), at: start)
        XCTAssertNotNil(failed.announcement(for: .failed("The connection dropped."), at: start))
    }

    func testNothingIsSaidAfterTheDownloadHasFinished() {
        var announcer = LocalModelProgressAnnouncer(modelName: "Test model")
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertNotNil(announcer.announcement(for: .completed, at: start))
        XCTAssertNil(announcer.announcement(for: .progress(fraction: 0.9),
                                            at: start.addingTimeInterval(600)))
        XCTAssertNil(announcer.announcement(for: .completed, at: start.addingTimeInterval(600)))
    }

    func testARetryStartsAFreshAnnouncementBudget() {
        var announcer = LocalModelProgressAnnouncer(modelName: "Test model")
        let start = Date(timeIntervalSince1970: 0)
        _ = announcer.announcement(for: .progress(fraction: 0.8), at: start)
        _ = announcer.announcement(for: .failed("The connection dropped."), at: start)
        announcer.restart()
        XCTAssertNotNil(announcer.announcement(for: .progress(fraction: 0.05),
                                               at: start.addingTimeInterval(1)),
                        "the second attempt must not inherit the first one's ceiling")
    }

    func testLeavingTheScreenSaysTheDownloadContinues() {
        let notice = LocalModelProgressAnnouncer.backgroundContinuationNotice(modelName: "Test model")
        XCTAssertTrue(notice.contains("background"))
        XCTAssertTrue(notice.contains("Test model"))
    }

    // MARK: - Helpers

    private final class StartedBox {
        var descriptor: LocalModelDescriptor?
        var acceptedRevision: String?
    }

    private struct StubFetcher: LocalModelRepositoryMetadataFetching {
        let metadata: LocalModelRepositoryMetadata
        let files: [LocalModelRemoteFile]

        func metadata(for reference: LocalModelRepositoryReference) async throws
            -> LocalModelRepositoryMetadata { metadata }

        func files(for reference: LocalModelRepositoryReference,
                   revision: String) async throws -> [LocalModelRemoteFile] { files }
    }

    private func file(_ path: String, bytes: Int64 = 500_000_000) -> LocalModelRemoteFile {
        LocalModelRemoteFile(path: path, byteCount: bytes,
                             sha256: String(repeating: "a", count: 64))
    }

    private func metadata(isGated: Bool = false,
                          license: String? = "apache-2.0") -> LocalModelRepositoryMetadata {
        LocalModelRepositoryMetadata(revision: revision, licenseIdentifier: license,
                                     isGated: isGated, isPrivate: false)
    }

    private func makeController(metadata: LocalModelRepositoryMetadata? = nil,
                                files: [LocalModelRemoteFile]? = nil,
                                freeDiskBytes: Int64? = 64 * 1_073_741_824,
                                availableProcessBytes: Int64 = 8 * 1_073_741_824,
                                started: StartedBox? = nil) -> LocalModelImportController {
        let box = started ?? StartedBox()
        return LocalModelImportController(
            planner: LocalModelImportPlanner(fetcher: StubFetcher(
                metadata: metadata ?? self.metadata(),
                files: files ?? [file("model-Q4_K_M.gguf")])),
            makeFit: { descriptor, accepted in
                LocalModelFitReport.make(.init(descriptor: descriptor,
                                                availableStorageBytes: freeDiskBytes,
                                                availableProcessBytes: availableProcessBytes,
                                                acceptedLicenseRevision: accepted))
            },
            startDownload: { descriptor, accepted in
                box.descriptor = descriptor
                box.acceptedRevision = accepted
            })
    }
}
