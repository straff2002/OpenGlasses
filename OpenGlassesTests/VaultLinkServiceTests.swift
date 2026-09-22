import XCTest
@testable import OpenGlasses

/// Plan FS PR2 — the receive flow end to end, with every seam injected: no network, no catalog, no
/// entitlement of its own and no clock.
@MainActor
final class VaultLinkServiceTests: XCTestCase {

    private var tempRoot: URL!
    private var staging: VaultLinkStagingStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultLinkServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        staging = VaultLinkStagingStore(root: tempRoot.appendingPathComponent("staging", isDirectory: true))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Harness

    /// What the service was asked to install, so a test can assert on it without touching disk.
    private final class InstallRecorder {
        var requests: [VaultLinkInstaller.Request] = []
        var failure: Error?

        func install(_ request: VaultLinkInstaller.Request) async throws -> VaultLinkInstaller.Outcome {
            requests.append(request)
            if let failure { throw failure }
            let manifest = try JSONDecoder().decode(VaultManifest.self,
                                                    from: request.files["manifest.json"] ?? Data())
            return .init(vaultId: manifest.id, vaultName: manifest.name, warnings: [],
                         needsDocumentSync: manifest.hasDocuments, manifest: manifest)
        }
    }

    private struct AuditRecorder {
        final class Box { var notes: [(String, Bool)] = [] }
        let box = Box()
    }

    private func service(archive: Data,
                         publishers: [VaultPublisher] = [],
                         capability: FieldAssistCapabilityCheck = .granted,
                         policy: VaultLinkInstallPolicy = .init(unsigned: .allowedWithAcknowledgement),
                         onCellular: Bool = false,
                         installedVersion: String? = nil,
                         installer: InstallRecorder,
                         audit: AuditRecorder = AuditRecorder(),
                         finalHost: String = "manuals.example.com",
                         downloadFailure: Error? = nil,
                         maximumBytes: Int = Config.vaultLinkMaxBytes) -> VaultLinkService {
        let staging = self.staging!
        return VaultLinkService(
            download: { _, store, progress in
                if let downloadFailure { throw downloadFailure }
                let file = try store.create()
                try store.append(archive, to: file)
                progress(archive.count)
                return (file, URL(string: "https://\(finalHost)/d/ZZ9PLURAL/acme.vaultarchive")!)
            },
            publishers: { publishers },
            capability: { capability },
            policy: { policy },
            isOnCellular: { onCellular },
            installedManifest: { id in
                installedVersion.map {
                    VaultManifest(id: id, name: "Installed", version: $0, files: ["a.md"])
                }
            },
            install: installer.install,
            audit: { note, installed in audit.box.notes.append((note, installed)) },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            maximumBytes: maximumBytes,
            cellularWarningBytes: Config.vaultLinkCellularWarningBytes,
            staging: staging)
    }

    private var signedFixture: (data: Data, publisher: VaultPublisher, files: [String: Data],
                                header: VaultArchiveHeader) {
        VaultArchiveFixture.signedArchive()
    }

    private var unsignedArchive: Data {
        let files = VaultArchiveFixture.vaultFiles()
        return VaultArchiveFixture.archive(header: VaultArchiveFixture.header(for: files), files: files)
    }

    private func stagedDirectoryCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: staging.root.path))?.count ?? 0
    }

    // MARK: - Nothing happens from a link alone

    func testAPastedLinkOnlyEverReachesTheOfferStage() async {
        let installer = InstallRecorder()
        var fetched = false
        let service = VaultLinkService(
            download: { _, _, _ in fetched = true; throw URLError(.cancelled) },
            publishers: { [] }, capability: { .granted },
            policy: { .init(unsigned: .allowedWithAcknowledgement) },
            isOnCellular: { false }, installedManifest: { _ in nil },
            install: installer.install, audit: { _, _ in }, now: Date.init,
            maximumBytes: Config.vaultLinkMaxBytes,
            cellularWarningBytes: Config.vaultLinkCellularWarningBytes, staging: staging)

        service.open("https://manuals.example.com/d/ZZ9PLURAL/acme.vaultarchive")
        guard case .offer(let offer) = service.stage else { return XCTFail("expected an offer") }
        XCTAssertEqual(offer.host, "manuals.example.com")
        XCTAssertFalse(fetched, "a pasted link must not start a download on its own")
        XCTAssertFalse(offer.message.contains("ZZ9PLURAL"), "the offer shows the site, not the link")
        XCTAssertTrue(installer.requests.isEmpty)
    }

    func testARefusedLinkNeverReachesAnOffer() {
        let installer = InstallRecorder()
        let service = service(archive: unsignedArchive, installer: installer)
        service.open("http://manuals.example.com/acme.vaultarchive")
        guard case .failed(let message) = service.stage else { return XCTFail("expected a refusal") }
        XCTAssertTrue(message.contains("https://"))
    }

    func testTheSchemeRouteTakesOnlyItsSourceParameter() {
        let installer = InstallRecorder()
        let service = service(archive: unsignedArchive, installer: installer)
        service.open(URL(string: "openglasses://vault?src=https%3A%2F%2Fmanuals.example.com%2Fa&install=1")!)
        guard case .failed = service.stage else { return XCTFail("extra parameters must be refused") }
    }

    // MARK: - The capability

    func testReceivingAVaultNeedsTheOwnVaultsCapability() {
        let installer = InstallRecorder()
        for check: FieldAssistCapabilityCheck in [.notIncluded(held: [.bundledVaults]),
                                                   .denied(.noEvidence),
                                                   .denied(.expired(Date()))] {
            let service = service(archive: unsignedArchive, capability: check, installer: installer)
            service.open("https://manuals.example.com/a.vaultarchive")
            guard case .failed(let message) = service.stage else {
                return XCTFail("\(check) must not reach an offer")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    // MARK: - Review

    func testASignedArchiveReviewsAsSignedAndInstallsOnOneConfirmation() async {
        let fixture = signedFixture
        let installer = InstallRecorder()
        let audit = AuditRecorder()
        let service = service(archive: fixture.data, publishers: [fixture.publisher],
                              installer: installer, audit: audit)
        service.open("https://manuals.example.com/d/ZZ9PLURAL/acme.vaultarchive")
        await service.approveFetch()

        guard case .reviewing(let review) = service.stage else { return XCTFail("expected a review") }
        XCTAssertEqual(review.signedLine, "Signed by Acme Manuals")
        XCTAssertEqual(review.host, "manuals.example.com")
        XCTAssertEqual(review.manuals, ["RTU-500 Service Manual"])
        XCTAssertTrue(review.allowsInstall(acknowledged: false))

        await service.confirmInstall()
        guard case .installed(let name) = service.stage else { return XCTFail("expected an install") }
        XCTAssertEqual(name, "Acme RTU Service")
        XCTAssertEqual(installer.requests.count, 1)
        XCTAssertEqual(installer.requests.first?.receipt.verification, .signed)
        XCTAssertEqual(installer.requests.first?.receipt.publisherName, "Acme Manuals")
        XCTAssertEqual(installer.requests.first?.receipt.sourceHost, "manuals.example.com")
        // The header and the detached signature are never installed as vault content.
        XCTAssertNil(installer.requests.first?.files[VaultArchiveHeader.filename])
        XCTAssertNil(installer.requests.first?.files[VaultArchiveHeader.signatureFilename])

        XCTAssertEqual(audit.box.notes.count, 2)
        XCTAssertEqual(audit.box.notes.map(\.1), [false, true])
        for (note, _) in audit.box.notes {
            XCTAssertTrue(note.contains("manuals.example.com"))
            XCTAssertFalse(note.contains("ZZ9PLURAL"), "an audit note never carries the link")
        }
    }

    func testAnUnsignedArchiveNeedsTheSecondAcknowledgement() async {
        let installer = InstallRecorder()
        let service = service(archive: unsignedArchive, installer: installer)
        service.open("https://manuals.example.com/a.vaultarchive")
        await service.approveFetch()

        guard case .reviewing(let review) = service.stage else { return XCTFail("expected a review") }
        XCTAssertEqual(review.warningBlock, VaultLinkReview.unverifiedWarning)
        XCTAssertTrue(review.requiresAcknowledgement)

        await service.confirmInstall()
        XCTAssertTrue(installer.requests.isEmpty, "install must not run before the acknowledgement")
        guard case .reviewing = service.stage else { return XCTFail("the sheet must stay up") }

        service.acknowledgedUnverified = true
        await service.confirmInstall()
        XCTAssertEqual(installer.requests.count, 1)
        XCTAssertEqual(installer.requests.first?.receipt.verification, .unverified)
        XCTAssertNil(installer.requests.first?.receipt.publisherId)
    }

    func testARevokedPublisherIsRefusedAtTheReviewWithNoInstall() async {
        let fixture = VaultArchiveFixture.signedArchive(status: .revoked)
        let installer = InstallRecorder()
        let service = service(archive: fixture.data, publishers: [fixture.publisher],
                              installer: installer)
        service.open("https://manuals.example.com/a.vaultarchive")
        await service.approveFetch()

        guard case .reviewing(let review) = service.stage else { return XCTFail("expected a review") }
        XCTAssertNotNil(review.refusal)
        service.acknowledgedUnverified = true
        await service.confirmInstall()
        XCTAssertTrue(installer.requests.isEmpty, "a revoked publisher is not overridable")
    }

    func testMedicalModeRefusesAnUnsignedArchiveOutright() async {
        let installer = InstallRecorder()
        let service = service(archive: unsignedArchive,
                              policy: .init(unsigned: .forbiddenByMedicalMode),
                              installer: installer)
        service.open("https://manuals.example.com/a.vaultarchive")
        await service.approveFetch()
        guard case .reviewing(let review) = service.stage else { return XCTFail("expected a review") }
        XCTAssertEqual(review.refusal, VaultLinkInstallPolicy(unsigned: .forbiddenByMedicalMode).refusalMessage)
        service.acknowledgedUnverified = true
        await service.confirmInstall()
        XCTAssertTrue(installer.requests.isEmpty)
    }

    func testTheOrganizationProfileCanForbidUnsignedToo() async {
        let installer = InstallRecorder()
        let service = service(archive: unsignedArchive,
                              policy: .init(unsigned: .forbiddenByOrganizationProfile),
                              installer: installer)
        service.open("https://manuals.example.com/a.vaultarchive")
        await service.approveFetch()
        guard case .reviewing(let review) = service.stage else { return XCTFail("expected a review") }
        XCTAssertNotNil(review.refusal)
        service.acknowledgedUnverified = true
        await service.confirmInstall()
        XCTAssertTrue(installer.requests.isEmpty)
    }

    func testAnAlreadyInstalledIdReviewsAsAnUpdate() async {
        let fixture = signedFixture
        let installer = InstallRecorder()
        let service = service(archive: fixture.data, publishers: [fixture.publisher],
                              installedVersion: "0.9.0", installer: installer)
        service.open("https://manuals.example.com/a.vaultarchive")
        await service.approveFetch()
        guard case .reviewing(let review) = service.stage else { return XCTFail("expected a review") }
        XCTAssertEqual(review.installedVersion, "0.9.0")
        XCTAssertEqual(review.installButtonTitle, "Update from v0.9.0")
    }

    func testACellularReviewWarnsAboveTheThreshold() async {
        let files = VaultArchiveFixture.vaultFiles(
            manualText: String(repeating: "A", count: Config.vaultLinkCellularWarningBytes))
        let archive = VaultArchiveFixture.archive(header: VaultArchiveFixture.header(for: files),
                                                  files: files)
        let installer = InstallRecorder()
        let service = service(archive: archive, onCellular: true, installer: installer)
        service.open("https://manuals.example.com/a.vaultarchive")
        guard case .offer(let offer) = service.stage else { return XCTFail("expected an offer") }
        XCTAssertTrue(offer.isOnCellular)
        await service.approveFetch()
        guard case .reviewing(let review) = service.stage else { return XCTFail("expected a review") }
        XCTAssertNotNil(review.cellularWarning)
    }

    // MARK: - A tampered archive

    func testAnAlteredArchiveIsRefusedAtTheReview() async {
        let fixture = signedFixture
        var altered = fixture.files
        altered["fault-codes.md"] = Data("# Fault codes\n\nQZ7731 — vent the charge.".utf8)
        let extracted = VaultArchiveReader.extract(zipData: fixture.data,
                                                   maximumTotalBytes: Config.vaultLinkMaxBytes)
        let signature: String
        if case .success(let value) = extracted { signature = value.signature ?? "" } else { signature = "" }
        let data = VaultArchiveFixture.archive(header: fixture.header, files: altered,
                                               signature: signature)
        let installer = InstallRecorder()
        let service = service(archive: data, publishers: [fixture.publisher], installer: installer)
        service.open("https://manuals.example.com/a.vaultarchive")
        await service.approveFetch()
        guard case .reviewing(let review) = service.stage else { return XCTFail("expected a review") }
        XCTAssertNotNil(review.refusal)
        service.acknowledgedUnverified = true
        await service.confirmInstall()
        XCTAssertTrue(installer.requests.isEmpty)
    }

    // MARK: - Residue

    func testDismissingAReviewLeavesNothingStaged() async {
        let installer = InstallRecorder()
        let service = service(archive: unsignedArchive, installer: installer)
        service.open("https://manuals.example.com/a.vaultarchive")
        await service.approveFetch()
        guard case .reviewing = service.stage else { return XCTFail("expected a review") }
        XCTAssertEqual(stagedDirectoryCount(), 1, "the archive is staged while it is reviewed")

        service.dismiss()
        XCTAssertEqual(service.stage, .idle)
        XCTAssertEqual(stagedDirectoryCount(), 0, "a dismissed review leaves nothing on disk")
        XCTAssertTrue(installer.requests.isEmpty)
    }

    func testAFailedInstallLeavesNothingStagedAndNothingInstalled() async {
        let installer = InstallRecorder()
        installer.failure = VaultLinkInstaller.InstallError.failed("validation refused it")
        let service = service(archive: unsignedArchive, installer: installer)
        service.open("https://manuals.example.com/a.vaultarchive")
        await service.approveFetch()
        service.acknowledgedUnverified = true
        await service.confirmInstall()
        guard case .failed(let message) = service.stage else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("validation refused it"))
        XCTAssertEqual(stagedDirectoryCount(), 0)
    }

    func testAFailedDownloadLeavesNothingStaged() async {
        let installer = InstallRecorder()
        let service = service(archive: unsignedArchive, installer: installer,
                              downloadFailure: URLError(.networkConnectionLost))
        service.open("https://manuals.example.com/a.vaultarchive")
        await service.approveFetch()
        guard case .failed = service.stage else { return XCTFail("expected a failure") }
        XCTAssertEqual(stagedDirectoryCount(), 0)
    }

    func testAnArchiveOverTheCapIsRefusedAndSwept() async {
        let installer = InstallRecorder()
        let service = service(archive: unsignedArchive, installer: installer, maximumBytes: 64)
        service.open("https://manuals.example.com/a.vaultarchive")
        await service.approveFetch()
        guard case .failed = service.stage else { return XCTFail("the cap must refuse it") }
        XCTAssertEqual(stagedDirectoryCount(), 0)
        XCTAssertTrue(installer.requests.isEmpty)
    }

    func testLosingTheForegroundEndsAPendingReview() async {
        let installer = InstallRecorder()
        let service = service(archive: unsignedArchive, installer: installer)
        service.open("https://manuals.example.com/a.vaultarchive")
        await service.approveFetch()
        service.handleBackground()
        XCTAssertEqual(service.stage, .idle)
        XCTAssertEqual(stagedDirectoryCount(), 0)
    }

    // MARK: - The staging store itself

    func testTheStagingStoreRefusesToGrowPastTheCap() throws {
        let store = VaultLinkStagingStore(root: tempRoot.appendingPathComponent("cap"),
                                          maximumBytes: 8)
        let file = try store.create()
        try store.append(Data(repeating: 0, count: 8), to: file)
        XCTAssertThrowsError(try store.append(Data(repeating: 0, count: 1), to: file)) { error in
            XCTAssertEqual(error as? VaultLinkStagingError, .tooLarge)
        }
        store.remove(file)
    }

    func testAbandonedStagingDirectoriesAreSwept() throws {
        let store = VaultLinkStagingStore(root: tempRoot.appendingPathComponent("sweep"))
        let file = try store.create()
        try store.append(Data("x".utf8), to: file)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: store.root.path))?.count, 1)
        store.removeAbandonedSessions()
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: store.root.path))?.count, 0)
    }
}
