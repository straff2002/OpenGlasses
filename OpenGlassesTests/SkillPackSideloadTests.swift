import XCTest
import CryptoKit
@testable import OpenGlasses

/// Plan BX P3 — the sideload link parser's source policy and the fetch → preview → confirm flow.
@MainActor
final class SkillPackSideloadTests: XCTestCase {

    // Reuses the P2 real-zip fixture (com.example.barista).
    private var fixtureZip: Data {
        Data(base64Encoded:
            "UEsDBBQAAAAIAPeu/1yV9I+SMgEAAAACAAAOAAAAc2tpbGxwYWNrLmpzb25NkM1OwzAQhO88xcrnEgHH3ADxAkicUBVt7FVj" +
            "6j95Ny1VlHdn3VCpN3vn88x6FuOd6Y3NsaNfjCVQN2L1LGh25kSVfU6qP3cv3ZNOEkbS69uGwHtGO+mY5xixXlT54FKJOYPz" +
            "GB59gsPsHSZLSqEVdWPTfy83o0YNPg08ZVHCEdvqi2yhX0xwniiBTAQzU4UzJmGYKJSrv08H0Aj6z+zUoWBVZ9HFTb8YuZSW" +
            "kscfss2/1Fyoiqer2kIH8ZGGezjNcaRq1nXdmdEnpyFNPepRVXWIpVkJaVko7cWrO3ldNSdAWJY713UFJpuTgzYElCaTiFp2" +
            "NSPLEOhEQbHrrdPQvZa5EVtPR2qt3sEteluUKWy/CjjqvDefjYIblcutbRP8YWpgJOfn2HrGejT7db8+/AFQSwMECgAAAAAA" +
            "967/XAAAAAAAAAAAAAAAAAgAAABwcm9tcHRzL1BLAwQKAAAAAAD3rv9ccHp5iBgAAAAYAAAAEgAAAHByb21wdHMvcGVyc29u" +
            "YS5tZFlvdSBhcmUgYSBiYXJpc3RhIGNvYWNoLlBLAQIeAxQAAAAIAPeu/1yV9I+SMgEAAAACAAAOAAAAAAAAAAEAAACkgQAA" +
            "AABza2lsbHBhY2suanNvblBLAQIeAwoAAAAAAPeu/1wAAAAAAAAAAAAAAAAIAAAAAAAAAAAAEADtQV4BAABwcm9tcHRzL1BL" +
            "AQIeAwoAAAAAAPeu/1xwenmIGAAAABgAAAASAAAAAAAAAAEAAACkgYQBAABwcm9tcHRzL3BlcnNvbmEubWRQSwUGAAAAAAMA" +
            "AwCyAAAAzAEAAAAA")!
    }

    private func makeStore(publicKey: String = SkillPackSignature.productionPublicKeyBase64) -> SkillPackStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("skillpack-side-tests-\(UUID().uuidString)", isDirectory: true)
        return SkillPackStore(directory: dir, currentBuild: 331,
                              nativeToolNames: { [] }, publicKeyBase64: publicKey)
    }

    private func setDevMode(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "skillPackDevModeEnabled")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "skillPackDevModeEnabled")
        super.tearDown()
    }

    // MARK: - Link parsing + source policy

    func testParsesLANLinkWithSignature() throws {
        let url = URL(string: "openglasses://skillpack?url=http%3A%2F%2F192.168.1.10%3A8787%2Fpack.zip&sig=QUJD")!
        guard case .success(let request) = SkillPackSideload.parse(url) else { return XCTFail() }
        XCTAssertEqual(request.packURL.absoluteString, "http://192.168.1.10:8787/pack.zip")
        XCTAssertEqual(request.signature, "QUJD")
    }

    func testRefusesPublicPlainHTTP() {
        let url = URL(string: "openglasses://skillpack?url=http%3A%2F%2Fevil.example%2Fpack.zip")!
        guard case .failure(.insecureSource) = SkillPackSideload.parse(url) else {
            return XCTFail("public plain-HTTP must refuse — LAN-only is the whole policy")
        }
        // HTTPS to the same host is fine.
        let https = URL(string: "openglasses://skillpack?url=https%3A%2F%2Fevil.example%2Fpack.zip")!
        guard case .success = SkillPackSideload.parse(https) else { return XCTFail("https anywhere") }
    }

    func testPrivateHostTable() {
        for host in ["localhost", "mymac.local", "127.0.0.1", "10.0.0.5", "192.168.1.2",
                     "172.16.0.1", "172.31.255.254", "169.254.1.1"] {
            XCTAssertTrue(SkillPackSideload.isPrivateHost(host), host)
        }
        for host in ["8.8.8.8", "172.32.0.1", "192.169.0.1", "example.com", "1.2.3.4.5", "300.1.1.1"] {
            XCTAssertFalse(SkillPackSideload.isPrivateHost(host), host)
        }
    }

    func testRejectsMalformedLinks() {
        XCTAssertEqual(SkillPackSideload.parse(URL(string: "openglasses://skillpack")!).failure,
                       .missingURL)
        XCTAssertEqual(SkillPackSideload.parse(URL(string: "openglasses://action/photo")!).failure,
                       .notASideloadLink)
        XCTAssertEqual(
            SkillPackSideload.parse(URL(string: "openglasses://skillpack?url=ftp%3A%2F%2Fx%2Fp.zip")!).failure,
            .insecureSource)
        XCTAssertEqual(
            SkillPackSideload.parse(URL(string: "openglasses://skillpack?url=https%3A%2F%2Fu%3Ap%40x%2Fp.zip")!).failure,
            .insecureSource)
        XCTAssertEqual(
            SkillPackSideload.parse(URL(string: "openglasses://skillpack?url=https%3A%2F%2Fx%2Fp.zip%23fragment")!).failure,
            .insecureSource)
    }

    // MARK: - Service flow

    private func request(sig: String? = nil) -> SkillPackSideloadRequest {
        SkillPackSideloadRequest(packURL: URL(string: "http://192.168.1.10:8787/pack.zip")!,
                                 signature: sig)
    }

    func testReleaseContainmentRefusesBeforeFetch() async {
        struct UnexpectedFetch: Error {}
        var fetchCount = 0
        let service = SkillPackSideloadService(
            store: makeStore(),
            fetch: { _ in
                fetchCount += 1
                throw UnexpectedFetch()
            },
            networkDecision: .refuseUntilHardenedClient
        )

        await service.handle(request(sig: "unused"))

        XCTAssertEqual(fetchCount, 0)
        guard case .error(let message)? = service.prompt else {
            return XCTFail("release containment must show an error without fetching")
        }
        XCTAssertEqual(message, UntrustedNetworkFeaturePolicy.unavailableMessage)
    }

    func testLinkPresentsConsentWithoutStartingTransport() async {
        var fetchCount = 0
        let service = SkillPackSideloadService(
            store: makeStore(),
            fetch: { _ in fetchCount += 1; return self.fixtureZip },
            networkDecision: .allowHardenedFetch
        )

        await service.handle(request(sig: "unused"))

        XCTAssertEqual(fetchCount, 0)
        guard case .downloadConsent(let offer)? = service.prompt else {
            return XCTFail("the link must stop at a non-network consent prompt")
        }
        XCTAssertEqual(offer.origin, "http://192.168.1.10:8787")
        XCTAssertFalse(offer.consentMessage.contains("pack.zip"))
    }

    func testDownloadConsentIsSingleUse() async {
        setDevMode(true)
        var fetchCount = 0
        let zip = fixtureZip
        let service = SkillPackSideloadService(
            store: makeStore(),
            fetch: { _ in fetchCount += 1; return zip },
            networkDecision: .allowHardenedFetch
        )
        await service.handle(request())
        guard case .downloadConsent(let offer)? = service.prompt else { return XCTFail() }

        await service.approveDownload(offer)
        XCTAssertEqual(fetchCount, 1)
        await service.approveDownload(offer)
        XCTAssertEqual(fetchCount, 1, "a consumed approval must not be replayable")
    }

    func testExpiredConsentDoesNotFetch() async {
        var instant = Date(timeIntervalSince1970: 1_000)
        var fetchCount = 0
        let service = SkillPackSideloadService(
            store: makeStore(),
            fetch: { _ in fetchCount += 1; return self.fixtureZip },
            networkDecision: .allowHardenedFetch,
            now: { instant }
        )
        await service.handle(request(sig: "unused"))
        guard case .downloadConsent(let offer)? = service.prompt else { return XCTFail() }
        instant = instant.addingTimeInterval(SkillPackSideloadService.consentLifetime + 1)

        await service.approveDownload(offer)

        XCTAssertEqual(fetchCount, 0)
        guard case .error(let message)? = service.prompt else { return XCTFail() }
        XCTAssertTrue(message.contains("expired"))
    }

    func testApprovedDownloadUsesProtectedStagingAndDismissCleansIt() async {
        setDevMode(true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skillpack-staging-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var protectedPaths: [String] = []
        let staging = SkillPackStagingStore(root: root, protect: { protectedPaths.append($0.path) })
        let zip = fixtureZip
        let service = SkillPackSideloadService(
            store: makeStore(), fetch: { _ in zip },
            networkDecision: .allowHardenedFetch, stagingStore: staging)

        await service.handle(request())
        guard case .downloadConsent(let offer)? = service.prompt else { return XCTFail() }
        await service.approveDownload(offer)
        guard case .confirm(let pending)? = service.prompt else { return XCTFail() }

        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.stagedArchive.fileURL.path))
        XCTAssertEqual(protectedPaths.count, 3, "root, session directory and empty archive are protected before content write")
        service.dismiss()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.stagedArchive.directory.path))
    }

    func testServiceStartupRemovesOnlyAbandonedStagingSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skillpack-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let abandoned = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let unrelated = root.appendingPathComponent("keep-me", isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: abandoned.appendingPathComponent("archive.zip"))
        let staging = SkillPackStagingStore(root: root, protect: { _ in })

        _ = SkillPackSideloadService(
            store: makeStore(), fetch: { _ in self.fixtureZip },
            networkDecision: .allowHardenedFetch, stagingStore: staging)

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testStagingRejectsAggregateBytesBeyondArchiveLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skillpack-bounded-stage-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = SkillPackStagingStore(root: root, protect: { _ in })
        let archive = try staging.createArchive()
        try staging.append(Data(repeating: 0, count: SkillPackArchive.maxArchiveBytes), to: archive)

        XCTAssertThrowsError(try staging.append(Data([1]), to: archive)) { error in
            XCTAssertEqual(error as? SkillPackStagingError, .archiveTooLarge)
        }
        XCTAssertEqual(try staging.load(archive).count, SkillPackArchive.maxArchiveBytes)
    }

    func testBackgroundInvalidatesConsentBeforeFetch() async {
        var fetchCount = 0
        let service = SkillPackSideloadService(
            store: makeStore(),
            fetch: { _ in fetchCount += 1; return self.fixtureZip },
            networkDecision: .allowHardenedFetch)
        await service.handle(request(sig: "unused"))
        guard case .downloadConsent(let offer)? = service.prompt else { return XCTFail() }

        service.handleBackground()
        await service.approveDownload(offer)

        XCTAssertEqual(fetchCount, 0)
        guard case .error(let message)? = service.prompt else { return XCTFail() }
        XCTAssertTrue(message.contains("no longer valid"))
    }

    func testInstallRefusesTamperedStagedArchiveAndCleansIt() async {
        setDevMode(true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skillpack-tamper-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = SkillPackStagingStore(root: root, protect: { _ in })
        let zip = fixtureZip
        let store = makeStore()
        let service = SkillPackSideloadService(
            store: store, fetch: { _ in zip },
            networkDecision: .allowHardenedFetch, stagingStore: staging)
        await service.handle(request())
        guard case .downloadConsent(let offer)? = service.prompt else { return XCTFail() }
        await service.approveDownload(offer)
        guard case .confirm(let pending)? = service.prompt else { return XCTFail() }
        try? Data("tampered".utf8).write(to: pending.stagedArchive.fileURL)

        service.confirm(pending)

        XCTAssertTrue(store.installedPacks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.stagedArchive.directory.path))
        guard case .error(let message)? = service.prompt else { return XCTFail() }
        XCTAssertTrue(message.contains("changed"))
    }

    func testUnsignedSideloadNeedsDevMode() async {
        setDevMode(false)
        let zip = fixtureZip
        let service = SkillPackSideloadService(store: makeStore(), fetch: { _ in zip })
        await service.handle(request())
        guard case .downloadConsent(let offer)? = service.prompt else { return XCTFail() }
        await service.approveDownload(offer)
        guard case .error(let message)? = service.prompt else {
            return XCTFail("unsigned without dev mode must error, got \(String(describing: service.prompt))")
        }
        XCTAssertTrue(message.lowercased().contains("developer mode"))
    }

    func testPreviewNeverInstallsUntilConfirmed() async {
        setDevMode(true)
        let zip = fixtureZip
        let store = makeStore()
        var refreshed = false
        let service = SkillPackSideloadService(store: store, fetch: { _ in zip },
                                               onInstalled: { refreshed = true })
        await service.handle(request())
        guard case .downloadConsent(let offer)? = service.prompt else { return XCTFail() }
        await service.approveDownload(offer)

        guard case .confirm(let pending)? = service.prompt else {
            return XCTFail("dev-mode unsigned sideload must reach the confirmation")
        }
        XCTAssertEqual(pending.name, "Barista Coach")
        XCTAssertFalse(pending.signed)
        XCTAssertTrue(pending.confirmationMessage.contains("UNSIGNED"))
        XCTAssertTrue(pending.confirmationMessage.contains("Source: http://192.168.1.10:8787"))
        XCTAssertTrue(pending.confirmationMessage.contains("Archive SHA-256:"))
        XCTAssertTrue(pending.confirmationMessage.contains("Actions (1): dial_in_shot"))
        XCTAssertTrue(pending.confirmationMessage.contains("Capabilities: model prompt generation"))
        XCTAssertTrue(pending.confirmationMessage.contains("Settings: roast_level"))
        XCTAssertTrue(store.installedPacks.isEmpty, "the link must never act — preview only")
        XCTAssertFalse(refreshed)

        service.confirm(pending)
        guard case .installed? = service.prompt else { return XCTFail("confirm installs") }
        XCTAssertEqual(store.installedPacks.first?.id, "com.example.barista")
        XCTAssertEqual(store.installedPacks.first?.signatureVerified, false)
        XCTAssertTrue(refreshed, "the registry re-merge hook fires on install")
    }

    func testSignedSideloadVerifiesAndRecordsSigned() async throws {
        setDevMode(false)   // a signed pack must not need dev mode
        guard case .success(let (manifestData, files)) = SkillPackArchive.extract(zipData: fixtureZip) else {
            return XCTFail()
        }
        let key = Curve25519.Signing.PrivateKey()
        let signature = try SkillPackSignature.sign(
            manifestData: manifestData, payloadFiles: files,
            privateKeyBase64: key.rawRepresentation.base64EncodedString())
        let store = makeStore(publicKey: key.publicKey.rawRepresentation.base64EncodedString())
        let zip = fixtureZip
        let service = SkillPackSideloadService(store: store, fetch: { _ in zip })

        await service.handle(request(sig: signature))
        guard case .downloadConsent(let offer)? = service.prompt else { return XCTFail() }
        await service.approveDownload(offer)
        guard case .confirm(let pending)? = service.prompt else { return XCTFail() }
        XCTAssertTrue(pending.signed)

        service.confirm(pending)
        guard case .installed? = service.prompt else { return XCTFail() }
        XCTAssertEqual(store.installedPacks.first?.signatureVerified, true)
    }

    func testBadSignatureSideloadIsRefusedBeforeInstallReview() async {
        setDevMode(false)
        let store = makeStore()   // production key; our garbage sig won't verify
        let zip = fixtureZip
        let service = SkillPackSideloadService(store: store, fetch: { _ in zip })
        await service.handle(request(sig: Data(repeating: 7, count: 64).base64EncodedString()))
        guard case .downloadConsent(let offer)? = service.prompt else { return XCTFail() }
        await service.approveDownload(offer)
        guard case .error(let message)? = service.prompt else {
            return XCTFail("bad signature must refuse before install review")
        }
        XCTAssertTrue(message.contains("signature"))
        XCTAssertTrue(store.installedPacks.isEmpty)
    }

    func testUnreadableArchiveIsAnHonestError() async {
        setDevMode(true)
        let service = SkillPackSideloadService(store: makeStore(), fetch: { _ in Data("junk".utf8) })
        await service.handle(request())
        guard case .downloadConsent(let offer)? = service.prompt else { return XCTFail() }
        await service.approveDownload(offer)
        guard case .error(let message)? = service.prompt else { return XCTFail() }
        XCTAssertTrue(message.contains("archive"))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
