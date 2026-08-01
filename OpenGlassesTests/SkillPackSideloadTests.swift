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
            .insecureSource("ftp://x/p.zip"))
    }

    // MARK: - Service flow

    private func request(sig: String? = nil) -> SkillPackSideloadRequest {
        SkillPackSideloadRequest(packURL: URL(string: "http://192.168.1.10:8787/pack.zip")!,
                                 signature: sig)
    }

    func testUnsignedSideloadNeedsDevMode() async {
        setDevMode(false)
        let zip = fixtureZip
        let service = SkillPackSideloadService(store: makeStore(), fetch: { _ in zip })
        await service.handle(request())
        guard case .error(let message)? = service.prompt else {
            return XCTFail("unsigned without dev mode must error, got \(String(describing: service.prompt))")
        }
        XCTAssertTrue(message.contains("Developer Mode"))
    }

    func testPreviewNeverInstallsUntilConfirmed() async {
        setDevMode(true)
        let zip = fixtureZip
        let store = makeStore()
        var refreshed = false
        let service = SkillPackSideloadService(store: store, fetch: { _ in zip },
                                               onInstalled: { refreshed = true })
        await service.handle(request())

        guard case .confirm(let pending)? = service.prompt else {
            return XCTFail("dev-mode unsigned sideload must reach the confirmation")
        }
        XCTAssertEqual(pending.name, "Barista Coach")
        XCTAssertFalse(pending.signed)
        XCTAssertTrue(pending.confirmationMessage.contains("UNSIGNED"))
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
        guard case .confirm(let pending)? = service.prompt else { return XCTFail() }
        XCTAssertTrue(pending.signed)

        service.confirm(pending)
        guard case .installed? = service.prompt else { return XCTFail() }
        XCTAssertEqual(store.installedPacks.first?.signatureVerified, true)
    }

    func testBadSignatureSideloadIsRefusedAtConfirm() async {
        setDevMode(false)
        let store = makeStore()   // production key; our garbage sig won't verify
        let zip = fixtureZip
        let service = SkillPackSideloadService(store: store, fetch: { _ in zip })
        await service.handle(request(sig: Data(repeating: 7, count: 64).base64EncodedString()))
        guard case .confirm(let pending)? = service.prompt else { return XCTFail() }

        service.confirm(pending)
        guard case .error(let message)? = service.prompt else {
            return XCTFail("bad signature must refuse at install")
        }
        XCTAssertTrue(message.contains("signature"))
        XCTAssertTrue(store.installedPacks.isEmpty)
    }

    func testUnreadableArchiveIsAnHonestError() async {
        setDevMode(true)
        let service = SkillPackSideloadService(store: makeStore(), fetch: { _ in Data("junk".utf8) })
        await service.handle(request())
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
