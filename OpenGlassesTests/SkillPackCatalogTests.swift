import XCTest
import CryptoKit
@testable import OpenGlasses

/// Plan BX P2 — signed catalog parsing, the zip → install pipeline over fixture bytes, hardware
/// gating, and settings-as-schema substitution.
@MainActor
final class SkillPackCatalogTests: XCTestCase {

    /// A real zip built with `zip -X`: `skillpack.json` (Barista Coach, one prompt action using
    /// `{{setting.roast_level}}`, one select setting) + `prompts/persona.md`. Exercises the actual
    /// `ZipArchiveReader`, not a stand-in.
    private static let fixtureZipBase64 = """
        UEsDBBQAAAAIAPeu/1yV9I+SMgEAAAACAAAOAAAAc2tpbGxwYWNrLmpzb25NkM1OwzAQhO88xcrnEgHH3ADxAkicUBVt7FVj\
        6j95Ny1VlHdn3VCpN3vn88x6FuOd6Y3NsaNfjCVQN2L1LGh25kSVfU6qP3cv3ZNOEkbS69uGwHtGO+mY5xixXlT54FKJOYPz\
        GB59gsPsHSZLSqEVdWPTfy83o0YNPg08ZVHCEdvqi2yhX0xwniiBTAQzU4UzJmGYKJSrv08H0Aj6z+zUoWBVZ9HFTb8YuZSW\
        kscfss2/1Fyoiqer2kIH8ZGGezjNcaRq1nXdmdEnpyFNPepRVXWIpVkJaVko7cWrO3ldNSdAWJY713UFJpuTgzYElCaTiFp2\
        NSPLEOhEQbHrrdPQvZa5EVtPR2qt3sEteluUKWy/CjjqvDefjYIblcutbRP8YWpgJOfn2HrGejT7db8+/AFQSwMECgAAAAAA\
        967/XAAAAAAAAAAAAAAAAAgAAABwcm9tcHRzL1BLAwQKAAAAAAD3rv9ccHp5iBgAAAAYAAAAEgAAAHByb21wdHMvcGVyc29u\
        YS5tZFlvdSBhcmUgYSBiYXJpc3RhIGNvYWNoLlBLAQIeAxQAAAAIAPeu/1yV9I+SMgEAAAACAAAOAAAAAAAAAAEAAACkgQAA\
        AABza2lsbHBhY2suanNvblBLAQIeAwoAAAAAAPeu/1wAAAAAAAAAAAAAAAAIAAAAAAAAAAAAEADtQV4BAABwcm9tcHRzL1BL\
        AQIeAwoAAAAAAPeu/1xwenmIGAAAABgAAAASAAAAAAAAAAEAAACkgYQBAABwcm9tcHRzL3BlcnNvbmEubWRQSwUGAAAAAAMA\
        AwCyAAAAzAEAAAAA
        """

    private var fixtureZip: Data { Data(base64Encoded: Self.fixtureZipBase64)! }

    private func makeStore(publicKey: String = SkillPackSignature.productionPublicKeyBase64) -> SkillPackStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("skillpack-cat-tests-\(UUID().uuidString)", isDirectory: true)
        return SkillPackStore(directory: dir, currentBuild: 330,
                              nativeToolNames: { [] }, publicKeyBase64: publicKey)
    }

    // MARK: - Archive extraction (real zip, real reader)

    func testFixtureZipExtracts() throws {
        guard case .success(let (manifestData, files)) = SkillPackArchive.extract(zipData: fixtureZip) else {
            return XCTFail("fixture must extract")
        }
        let (manifest, report) = SkillPackManifest.lossyDecode(manifestData)
        XCTAssertEqual(manifest?.id, "com.example.barista")
        XCTAssertTrue(report.isClean)
        XCTAssertEqual(files["prompts/persona.md"], Data("You are a barista coach.".utf8))
        XCTAssertNil(files["skillpack.json"], "the manifest is not a payload file")
        XCTAssertNil(files["prompts/"], "directory entries are skipped")
    }

    func testGarbageAndManifestlessArchivesAreTypedFailures() {
        XCTAssertEqual(SkillPackArchive.extract(zipData: Data("not a zip".utf8)).failureError, .notAZip)
        // An empty-but-valid zip: EOCD only.
        var eocd = Data(count: 22)
        eocd.replaceSubrange(0..<4, with: [0x50, 0x4B, 0x05, 0x06])
        XCTAssertEqual(SkillPackArchive.extract(zipData: eocd).failureError, .missingManifest)
    }

    func testSha256HexMatchesKnownVector() {
        XCTAssertEqual(SkillPackArchive.sha256Hex(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - Catalog envelope

    private func makeSignedCatalog(entries: [SkillPackCatalogEntry]) throws -> (envelope: Data, publicKey: String) {
        let key = Curve25519.Signing.PrivateKey()
        let envelope = try SkillPackCatalog.makeEnvelope(
            index: .init(version: 1, packs: entries),
            privateKeyBase64: key.rawRepresentation.base64EncodedString())
        return (envelope, key.publicKey.rawRepresentation.base64EncodedString())
    }

    private func entry(sha256: String = "", packSignature: String = "") -> SkillPackCatalogEntry {
        SkillPackCatalogEntry(
            id: "com.example.barista", version: "1.2.0", name: "Barista Coach",
            summary: "Espresso dial-in guidance",
            hardware: [.init(type: .camera, level: .optional)],
            downloadURL: "https://packs.example/barista.zip",
            sha256: sha256, packSignature: packSignature)
    }

    func testCatalogRoundTripsThroughSignedEnvelope() throws {
        let (envelope, publicKey) = try makeSignedCatalog(entries: [entry(sha256: "aa")])
        guard case .success(let parsed) = SkillPackCatalog.parse(envelopeData: envelope,
                                                                publicKeyBase64: publicKey) else {
            return XCTFail("valid envelope must parse")
        }
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].id, "com.example.barista")
    }

    func testCatalogRefusesTamperAndForeignKeys() throws {
        let (envelope, publicKey) = try makeSignedCatalog(entries: [entry()])

        // Foreign key.
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertEqual(SkillPackCatalog.parse(envelopeData: envelope, publicKeyBase64: otherKey).failureError,
                       .badSignature)

        // Payload tampered inside a re-built envelope: flip one byte of the payload.
        var dict = try JSONSerialization.jsonObject(with: envelope) as! [String: Any]
        var payload = Data(base64Encoded: dict["payload"] as! String)!
        payload[payload.count / 2] ^= 0xFF
        dict["payload"] = payload.base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: dict)
        XCTAssertEqual(SkillPackCatalog.parse(envelopeData: tampered, publicKeyBase64: publicKey).failureError,
                       .badSignature)

        // Not an envelope at all.
        XCTAssertEqual(SkillPackCatalog.parse(envelopeData: Data("[]".utf8), publicKeyBase64: publicKey).failureError,
                       .notAnEnvelope)
    }

    func testCatalogRefusesNewerIndexVersionExplicitly() throws {
        let key = Curve25519.Signing.PrivateKey()
        let envelope = try SkillPackCatalog.makeEnvelope(
            index: .init(version: 99, packs: []),
            privateKeyBase64: key.rawRepresentation.base64EncodedString())
        XCTAssertEqual(
            SkillPackCatalog.parse(envelopeData: envelope,
                                   publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()).failureError,
            .unsupportedVersion(99),
            "a newer index is 'update the app', never a partial parse")
    }

    /// The envelope actually committed at `skillpacks/catalog.json` must verify against the
    /// embedded production key. Byte-for-byte copy here: if either the published catalog or
    /// `productionPublicKeyBase64` changes without the other, this fails — the drift this test
    /// exists to catch. Update both together (sign with `Scripts/skillpack-sign.swift`).
    func testCommittedCatalogVerifiesAgainstProductionKey() {
        let committed = #"{"payload":"eyJ2ZXJzaW9uIjoxLCJwYWNrcyI6W119","signature":"GLNPI2mrxy791gLlHMtD24vIAnNla0fnxJGMiZUCE5UwOSeELF9HVX4IC287FKAgdZ49wP0z6EMErZVNZFCjDQ=="}"#
        guard case .success(let packs) = SkillPackCatalog.parse(envelopeData: Data(committed.utf8)) else {
            return XCTFail("the committed catalog must verify against the embedded production key")
        }
        XCTAssertTrue(packs.isEmpty, "first published catalog is the empty index")
    }

    // MARK: - Hardware gate

    func testHardwareGateTable() {
        typealias Req = SkillPackManifest.HardwareRequirement
        let camReq = Req(type: .camera, level: .required)
        let camOpt = Req(type: .camera, level: .optional)
        let dispReq = Req(type: .display, level: .required)

        XCTAssertEqual(SkillPackHardwareGate.availability(requirements: [], hasCamera: false, hasDisplay: false),
                       .ready, "no requirements — always ready")
        XCTAssertEqual(SkillPackHardwareGate.availability(requirements: [camOpt], hasCamera: false, hasDisplay: false),
                       .degraded(missing: ["camera"]), "optional missing = shown, not hidden")
        XCTAssertEqual(SkillPackHardwareGate.availability(requirements: [camReq], hasCamera: false, hasDisplay: false),
                       .blocked(missing: ["camera"]))
        XCTAssertEqual(SkillPackHardwareGate.availability(requirements: [camReq, dispReq], hasCamera: true, hasDisplay: false),
                       .blocked(missing: ["display"]), "required beats optional in the verdict")
        XCTAssertEqual(SkillPackHardwareGate.availability(requirements: [camReq, dispReq], hasCamera: true, hasDisplay: true),
                       .ready)
    }

    // MARK: - Install pipeline (injected fetch, end to end)

    func testPipelineInstallsFixtureEndToEnd() async throws {
        // Sign the fixture's manifest + payload with an ephemeral key, catalog carries the pack
        // signature and the zip hash — the full P2 path with zero network.
        guard case .success(let (manifestData, files)) = SkillPackArchive.extract(zipData: fixtureZip) else {
            return XCTFail()
        }
        let key = Curve25519.Signing.PrivateKey()
        let packSignature = try SkillPackSignature.sign(
            manifestData: manifestData, payloadFiles: files,
            privateKeyBase64: key.rawRepresentation.base64EncodedString())
        let store = makeStore(publicKey: key.publicKey.rawRepresentation.base64EncodedString())

        var installedFired = false
        let zip = fixtureZip
        let service = SkillPackCatalogService(
            store: store,
            catalogURL: { URL(string: "https://example.test/catalog.json") },
            fetch: { _ in zip },
            onInstalled: { installedFired = true })

        await service.install(entry(sha256: SkillPackArchive.sha256Hex(zip),
                                    packSignature: packSignature))

        guard case .installed(let warnings)? = service.installStates["com.example.barista"] else {
            return XCTFail("pipeline must install, got \(String(describing: service.installStates["com.example.barista"]))")
        }
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertTrue(installedFired, "the registry re-merge hook must fire")
        XCTAssertEqual(store.installedPacks.first?.signatureVerified, true)
        // Payload file landed on disk under the pack's version directory.
        XCTAssertEqual(store.activeManifests().first?.settings.first?.key, "roast_level")
    }

    func testPipelineRefusesChecksumMismatchBeforeExtraction() async {
        let store = makeStore()
        let zip = fixtureZip
        let service = SkillPackCatalogService(
            store: store, catalogURL: { URL(string: "https://example.test/c.json") },
            fetch: { _ in zip })

        await service.install(entry(sha256: String(repeating: "0", count: 64), packSignature: ""))

        guard case .failed(let reason)? = service.installStates["com.example.barista"] else {
            return XCTFail("hash mismatch must fail")
        }
        XCTAssertTrue(reason.contains("checksum"))
        XCTAssertTrue(store.installedPacks.isEmpty, "nothing partial reaches the store")
    }

    func testPipelineSurfacesDownloadFailure() async {
        struct Offline: Error {}
        let store = makeStore()
        let service = SkillPackCatalogService(
            store: store, catalogURL: { URL(string: "https://example.test/c.json") },
            fetch: { _ in throw Offline() })

        await service.install(entry(sha256: "aa", packSignature: ""))
        guard case .failed(let reason)? = service.installStates["com.example.barista"] else {
            return XCTFail()
        }
        XCTAssertTrue(reason.contains("download failed"))
    }

    func testCatalogLoadRefusesBadSignatureLoudly() async throws {
        // Catalog signed by a key that is NOT the store's — the fleet-attack case. Developer mode
        // must not loosen this.
        Config.setSkillPackDevModeEnabled(true)
        defer { UserDefaults.standard.removeObject(forKey: "skillPackDevModeEnabled") }

        let (envelope, _) = try makeSignedCatalog(entries: [entry()])
        let service = SkillPackCatalogService(
            store: makeStore(), catalogURL: { URL(string: "https://example.test/c.json") },
            fetch: { _ in envelope })   // parse uses the production placeholder key → mismatch

        await service.loadCatalog()
        guard case .failed(let reason) = service.catalogState else {
            return XCTFail("foreign-signed catalog must refuse")
        }
        XCTAssertTrue(reason.contains("signature"))
    }

    // MARK: - Settings-as-schema

    func testSettingSubstitutionReachesBindings() {
        SkillPackSettings.setValue("dark", packId: "com.example.barista", key: "roast_level")
        defer { SkillPackSettings.setValue(nil, packId: "com.example.barista", key: "roast_level") }

        let out = SkillPackToolWrapper.substitute(
            template: "Advise at {{setting.roast_level}} roast for {{shot_time_s}}s.",
            args: ["shot_time_s": 18],
            settings: ["roast_level": "dark"])
        XCTAssertEqual(out, "Advise at dark roast for 18s.")
    }

    func testSettingsValuesReadOnlyDeclaredKeys() {
        let packId = "com.example.pack"
        SkillPackSettings.setValue("yes", packId: packId, key: "declared")
        UserDefaults.standard.set("sneaky", forKey: "skillpack.\(packId).undeclared")
        defer {
            SkillPackSettings.setValue(nil, packId: packId, key: "declared")
            UserDefaults.standard.removeObject(forKey: "skillpack.\(packId).undeclared")
        }
        let values = SkillPackSettings.values(
            packId: packId,
            declarations: [.init(key: "declared", type: "text", label: nil, options: nil)])
        XCTAssertEqual(values, ["declared": "yes"],
                       "only declared keys flow into substitution — the schema is the contract")
    }
}

private extension Result {
    var failureError: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
