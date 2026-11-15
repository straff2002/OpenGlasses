import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto // swift-crypto: the same API on Linux (the service's containers)
#endif
@testable import LicenceIssuance

/// Plan LV P0 — published vaults: the additive catalog fields (`publisher`, `sealedCore`, `expects`,
/// `frozen`, `extends`), the sealed core and the company layer's add-only rule. The golden fixtures
/// under `Contracts/fixtures/company-vaults-v2/` are read here and by the app's
/// `CompanyVaultPublishedContractTests`. Invented identifiers only.
final class CompanyVaultV2Tests: XCTestCase {

    typealias Contract = CompanyVaultContract

    static let profileId = CompanyVaultTests.profileId
    static let otherProfileId = "fixture-other-company"
    static let otherSecretLabel = "Avenkin public fixture other company secret v2"
    static var companySecret: Data { CompanyVaultTests.companySecret }
    static var otherSecret: Data { Data(SHA256.hash(data: Data(otherSecretLabel.utf8))) }
    static let issued = CompanyVaultTests.issued

    static let baseId = "fixture-split-systems"
    static let layerId = "fixture-split-systems-company"

    static var fixtures: URL {
        CompanyVaultTests.fixtures.deletingLastPathComponent().appendingPathComponent("company-vaults-v2", isDirectory: true)
    }

    func fixture(_ name: String) throws -> Data { try Data(contentsOf: Self.fixtures.appendingPathComponent(name)) }

    static let digestA = String(repeating: "a", count: 64)

    func entry(_ vaultId: String = baseId, version: String = "7", publisher: Contract.Publisher? = nil,
               sealedCore: Bool? = nil, expects: [Contract.ExpectedManual]? = nil, frozen: Bool? = nil,
               extends: String? = nil) -> Contract.Vault {
        .init(id: Contract.packIdPrefix + vaultId, vaultId: vaultId, version: version, name: "Fixture Split Systems",
              sizeBytes: 2_048, downloadURL: "https://licence.example.test/c/opaque/v/\(vaultId)-\(version).zip",
              sha256: Self.digestA, packSignature: "c2lnbmF0dXJl", publisher: publisher, sealedCore: sealedCore,
              expects: expects, frozen: frozen, extends: extends)
    }

    static let publisher = Contract.Publisher(id: "p-fixture", name: "Fixture Publishing", version: 5)

    func catalog(_ vaults: [Contract.Vault], manuals: [Contract.Manual] = [], generation: Int = 12) -> Contract.Catalog {
        .init(profileId: Self.profileId, generation: generation, issued: Self.issued, vaults: vaults, manuals: manuals)
    }

    func signed(_ catalog: Contract.Catalog) throws -> Data {
        try Contract.sign(catalog, signer: CompanyVaultTests.packKey.signature(for:))
    }

    func refusal(_ catalog: Contract.Catalog) -> String? {
        do { try Contract.check(catalog); return nil } catch {
            guard case .invalid(let message)? = error as? Contract.Refusal else { return "\(error)" }
            return message
        }
    }

    // MARK: - v1 unchanged

    func testAV1EntryEncodesWithoutAnyNewKey() throws {
        let bytes = String(decoding: try Contract.encoder().encode(entry()), as: UTF8.self)
        for key in ["publisher", "sealedCore", "expects", "frozen", "extends"] {
            XCTAssertFalse(bytes.contains("\"\(key)\""), key)
        }
        XCTAssertEqual(bytes, #"{"downloadURL":"https://licence.example.test/c/opaque/v/fixture-split-systems-7.zip","id":"com.openglasses.vault.fixture-split-systems","name":"Fixture Split Systems","packSignature":"c2lnbmF0dXJl","sha256":"\#(Self.digestA)","sizeBytes":2048,"vaultId":"fixture-split-systems","version":"7"}"#)
        XCTAssertFalse(entry().isSealedCore)
        XCTAssertFalse(entry().isFrozen)
    }

    /// The v1 golden catalog's payload decodes into the v2 types and encodes back to its exact bytes.
    func testTheV1GoldenPayloadRoundTripsByteForByte() throws {
        let envelopeData = try Data(contentsOf: CompanyVaultTests.fixtures.appendingPathComponent("catalog-v7.json"))
        let envelope = try JSONDecoder().decode(Contract.Envelope.self, from: envelopeData)
        let payload = try XCTUnwrap(Data(base64Encoded: envelope.payload))
        let catalog = try Contract.decoder().decode(Contract.Catalog.self, from: payload)
        XCTAssertEqual(try Contract.encoder().encode(catalog), payload)
        XCTAssertTrue(catalog.vaults.allSatisfy { $0.publisher == nil && $0.sealedCore == nil && $0.expects == nil
            && $0.frozen == nil && $0.extends == nil })
        XCTAssertNoThrow(try Contract.check(catalog))
    }

    // MARK: - The new fields' checks

    func testAPublishedEntryAndItsCompanyLayerPass() {
        let expects: [Contract.ExpectedManual] = [.init(key: "install-manual", title: "Installation manual", edition: "Rev C",
                                                        revision: String(repeating: "b", count: 64)),
                                                  .init(key: "wiring-diagram", title: "Wiring diagram")]
        XCTAssertNil(refusal(catalog([entry(publisher: Self.publisher, sealedCore: true, expects: expects),
                                      entry(Self.layerId, version: "2", sealedCore: false, extends: Self.baseId)])))
        // The layer may be listed before the vault it extends.
        XCTAssertNil(refusal(catalog([entry(Self.layerId, version: "2", extends: Self.baseId),
                                      entry(publisher: Self.publisher, frozen: true)])))
    }

    func testTheServiceRefusesABrokenPublishedEntry() {
        let cases: [(Contract.Catalog, String)] = [
            (catalog([entry(Self.layerId, extends: "fixture-not-listed")]), "not a vault in this catalog"),
            (catalog([entry(), entry(Self.layerId, publisher: Self.publisher, extends: Self.baseId)]), "cannot also name a publisher"),
            (catalog([entry(), entry(Self.layerId, extends: Self.baseId), entry("fixture-layer-two", extends: Self.layerId)]),
             "itself a company layer"),
            (catalog([entry(Self.layerId, extends: Self.layerId)]), "must extend another vault"),
            (catalog([entry(expects: [.init(key: "install-manual", title: "Installation manual"),
                                      .init(key: "install-manual", title: "Installation manual", edition: "Rev D")])]), "twice"),
            (catalog([entry(expects: [.init(key: "../escape", title: "Installation manual")])]), "not a safe manual key"),
            (catalog([entry(expects: [.init(key: "install-manual", title: "")])]), "needs a title"),
            (catalog([entry(expects: [.init(key: "install-manual", title: "Installation manual", revision: "ABC")])]),
             "not a lowercase SHA-256"),
            (catalog([entry(expects: [.init(key: "install-manual", title: "Installation manual", edition: "")])]), "edition"),
            (catalog([entry(publisher: .init(id: "p fixture", name: "Fixture Publishing", version: 5))]), "publisher id"),
            (catalog([entry(publisher: .init(id: "p-fixture", name: "", version: 5))]), "publisher needs a name"),
            (catalog([entry(publisher: .init(id: "p-fixture", name: "Fixture Publishing", version: 0))]), "publisher version"),
            (catalog([entry(expects: (0...Contract.Limits.expectsPerVault).map { .init(key: "m\($0)", title: "Manual \($0)") })]),
             "at most"),
        ]
        for (bad, expected) in cases {
            let message = refusal(bad)
            XCTAssertTrue(message?.contains(expected) == true, "\(expected): \(message ?? "accepted")")
        }
    }

    // MARK: - The core seal

    func coreContext(version: String = "7", profileId: String = profileId) -> Contract.CoreSeal.Context {
        .init(profileId: profileId, vault: entry(version: version))
    }

    func testACoreSealsAndOpensOnlyForItsCompanyVaultAndVersion() throws {
        let seal = Contract.CoreSeal.self
        let pack = Data((0..<(Contract.ManualSeal.chunkSize + 3_000)).map { UInt8($0 % 239) })
        let sealed = try seal.seal(pack, context: coreContext(), companySecret: Self.companySecret)
        XCTAssertEqual(sealed.count, seal.sealedLength(plaintextBytes: pack.count))
        XCTAssertEqual(sealed.prefix(4), Data("OGCP".utf8))
        XCTAssertEqual(try seal.open(sealed, context: coreContext(), companySecret: Self.companySecret), pack)

        XCTAssertThrowsError(try seal.open(sealed, context: coreContext(), companySecret: Self.otherSecret)) {
            XCTAssertEqual($0 as? Contract.CoreSeal.Problem, .unreadable)
        }
        for wrong in [coreContext(version: "8"), coreContext(profileId: Self.otherProfileId),
                      .init(profileId: Self.profileId, vaultId: Self.layerId, packId: Contract.packIdPrefix + Self.baseId, version: "7"),
                      .init(profileId: Self.profileId, vaultId: Self.baseId, packId: Contract.packIdPrefix + Self.layerId, version: "7")] {
            XCTAssertThrowsError(try seal.open(sealed, context: wrong, companySecret: Self.companySecret), "\(wrong)")
        }
        XCTAssertThrowsError(try seal.open(Data(sealed.prefix(9 + Contract.ManualSeal.chunkSize + 28)), context: coreContext(),
                                           companySecret: Self.companySecret), "cut at a chunk boundary")
        XCTAssertThrowsError(try seal.seal(Data(), context: coreContext(), companySecret: Self.companySecret))
        XCTAssertThrowsError(try seal.seal(pack, context: coreContext(), companySecret: Data(count: 7)))
    }

    /// The two seals share one construction but neither domain's file opens as the other's, even
    /// with the same secret and fields that spell the same.
    func testACoreAndAManualNeverOpenAsEachOther() throws {
        let plain = Data("Invented fixture bytes for the domain test.".utf8)
        let digest = Contract.ManualSeal.digest(plain)
        let manualContext = Contract.ManualSeal.Context(profileId: Self.profileId, vaultId: Self.baseId, fileName: "x", revision: digest)
        let coreContext = Contract.CoreSeal.Context(profileId: Self.profileId, vaultId: Self.baseId, packId: "x", version: digest)
        let manual = try Contract.ManualSeal.seal(plain, context: manualContext, companySecret: Self.companySecret)
        let core = try Contract.CoreSeal.seal(plain, context: coreContext, companySecret: Self.companySecret)
        XCTAssertEqual(manual.count, core.count)
        XCTAssertThrowsError(try Contract.CoreSeal.open(manual, context: coreContext, companySecret: Self.companySecret))
        XCTAssertThrowsError(try Contract.ManualSeal.open(core, context: manualContext, companySecret: Self.companySecret))
        // Even with the header swapped, the key and the authenticated domain differ.
        var relabelled = manual
        relabelled.replaceSubrange(0..<4, with: Data("OGCP".utf8))
        XCTAssertThrowsError(try Contract.CoreSeal.open(relabelled, context: coreContext, companySecret: Self.companySecret))
        XCTAssertEqual(Contract.CoreSeal.domain, "openglasses.company-core.v1")
        XCTAssertNotEqual(Contract.CoreSeal.header(), Contract.ManualSeal.header())
    }

    func testSealingACoreFileStreamsToTheSameFormat() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CompanyVaultV2Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pack = Data((0..<(2 * Contract.ManualSeal.chunkSize + 5)).map { UInt8($0 % 7) })
        let input = directory.appendingPathComponent("pack.zip"), output = directory.appendingPathComponent("pack.sealed")
        try pack.write(to: input)
        let row = try Contract.CoreSeal.sealFile(at: input, to: output, context: coreContext(), companySecret: Self.companySecret)
        let sealed = try Data(contentsOf: output)
        XCTAssertEqual(row.sizeBytes, sealed.count)
        XCTAssertEqual(row.sha256, IssuanceWire.digest(sealed))
        XCTAssertEqual(row.plaintextSha256, IssuanceWire.digest(pack))
        XCTAssertEqual(try Contract.CoreSeal.open(sealed, context: coreContext(), companySecret: Self.companySecret), pack)
    }

    // MARK: - The company layer

    func testACompanyLayerMayAddFilesButNeverReplaceThePublishers() throws {
        let base = ["safety.md", "fault_codes.md"]
        XCTAssertEqual(VaultPackRules.layerCollisions(baseFiles: base, layerFiles: ["site_notes.md"]), [])
        XCTAssertEqual(VaultPackRules.layerCollisions(baseFiles: base, layerFiles: ["site_notes.md", "./Fault_Codes.md"]),
                       ["./Fault_Codes.md"])
        let collides = try XCTUnwrap(VaultPackRules.Manifest(json: try fixture("layer-collides-manifest.json")))
        let issues = VaultPackRules.layerIssues(collides, baseFiles: base)
        XCTAssertEqual(issues, ["a company layer may add files, not replace the vault's own: fault_codes.md"])
        let documents = VaultPackRules.Manifest(id: "l", name: "L", files: ["a.md"], documentCount: 1, hasSites: true)
        XCTAssertEqual(VaultPackRules.layerIssues(documents, baseFiles: base).count, 2)
    }

    // MARK: - Golden fixtures

    func testTheGoldenV2FixturesOpen() throws {
        let keys = try JSONSerialization.jsonObject(with: try fixture("fixture-keys.json")) as? [String: Any]
        XCTAssertEqual(keys?["packCatalogPublicKey"] as? String, CompanyVaultTests.publicKey)
        XCTAssertEqual(keys?["companySecretLabel"] as? String, CompanyVaultTests.secretLabel)
        XCTAssertEqual(keys?["otherCompanySecretLabel"] as? String, Self.otherSecretLabel)
        XCTAssertEqual(keys?["otherProfileId"] as? String, Self.otherProfileId)

        let catalog = try Contract.open(try fixture("catalog-v12.json"), publicKeyBase64: CompanyVaultTests.publicKey,
                                        profileId: Self.profileId, profileGeneration: 12)
        XCTAssertNoThrow(try Contract.check(catalog))
        XCTAssertEqual(catalog.vaults.map(\.vaultId), [Self.baseId, Self.layerId])
        let base = catalog.vaults[0], layer = catalog.vaults[1]
        XCTAssertEqual(base.publisher, Self.publisher)
        XCTAssertTrue(base.isSealedCore)
        XCTAssertFalse(base.isFrozen)
        XCTAssertNil(base.extends)
        XCTAssertEqual(base.expects?.map(\.key), ["install-manual", "service-manual", "wiring-diagram"])
        XCTAssertEqual(layer.extends, Self.baseId)
        XCTAssertNil(layer.publisher)
        XCTAssertFalse(layer.isSealedCore)

        // The sealed core: the row's checksum and size are the sealed file's; it opens to the pack.
        let sealed = try fixture("fixture-split-systems-7.zip.sealed")
        let pack = try fixture("fixture-split-systems-7.zip")
        XCTAssertEqual(base.sha256, IssuanceWire.digest(sealed))
        XCTAssertEqual(base.sizeBytes, sealed.count)
        XCTAssertEqual(try Contract.CoreSeal.open(sealed, context: .init(profileId: Self.profileId, vault: base),
                                                  companySecret: Self.companySecret), pack)
        XCTAssertThrowsError(try Contract.CoreSeal.open(sealed, context: .init(profileId: Self.profileId, vault: base),
                                                        companySecret: Self.otherSecret), "another company's secret")
        XCTAssertThrowsError(try Contract.CoreSeal.open(sealed, context: .init(profileId: Self.otherProfileId, vault: base),
                                                        companySecret: Self.otherSecret), "another company")
        // The layer is a plain pack, as in v1.
        let layerPack = try fixture("fixture-split-systems-company-2.zip")
        XCTAssertEqual(layer.sha256, IssuanceWire.digest(layerPack))
        XCTAssertEqual(layer.sizeBytes, layerPack.count)

        // The manuals: one at the expected revision, one at another.
        XCTAssertEqual(catalog.manuals.map(\.fileName), ["Installation manual.md", "Service manual.md"])
        for row in catalog.manuals {
            let plain = try Contract.ManualSeal.open(try fixture(row.fileName + ".sealed"),
                                                     context: .init(profileId: Self.profileId, manual: row),
                                                     companySecret: Self.companySecret)
            XCTAssertEqual(plain, try fixture(row.fileName))
        }
        XCTAssertEqual(base.expects?[0].revision, catalog.manuals[0].revision)
        XCTAssertNotNil(base.expects?[1].revision)
        XCTAssertNotEqual(base.expects?[1].revision, catalog.manuals[1].revision)
        XCTAssertNil(base.expects?[2].revision)

        // The frozen catalog: the same entry, marked frozen.
        let frozen = try Contract.open(try fixture("catalog-frozen-v13.json"), publicKeyBase64: CompanyVaultTests.publicKey,
                                       profileId: Self.profileId, highWater: 12, profileGeneration: 13)
        XCTAssertTrue(frozen.vaults[0].isFrozen)
        XCTAssertEqual(frozen.vaults[0].version, base.version)
    }

    /// Every negative catalog in the fixtures is refused by the service, with the words it names.
    func testTheNegativeFixturesAreRefused() throws {
        struct Case: Decodable { let name: String; let refusal: String; let catalog: Contract.Catalog }
        struct Cases: Decodable { let cases: [Case] }
        let cases = try Contract.decoder().decode(Cases.self, from: try fixture("negative-catalogs.json")).cases
        XCTAssertEqual(cases.map(\.name), ["extends-missing", "extends-with-publisher", "extends-a-layer", "expects-key-twice"])
        for item in cases {
            let message = refusal(item.catalog)
            XCTAssertTrue(message?.contains(item.refusal) == true, "\(item.name): \(message ?? "accepted")")
        }
    }

    /// Writes `Contracts/fixtures/company-vaults-v2/`. The sealed files' nonces are derived from a
    /// public label, the file and the chunk index, so they regenerate to the same bytes; the
    /// catalogs' signatures do not (randomised Ed25519). Set `REGENERATE_COMPANY_VAULT_V2_FIXTURES=1`.
    func testRegenerateV2Fixtures() throws {
        guard ProcessInfo.processInfo.environment["REGENERATE_COMPANY_VAULT_V2_FIXTURES"] == "1" else { return }
        try FileManager.default.createDirectory(at: Self.fixtures, withIntermediateDirectories: true)
        func write(_ data: Data, _ name: String) throws { try data.write(to: Self.fixtures.appendingPathComponent(name)) }
        func json(_ object: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]) + Data("\n".utf8)
        }
        func nonces(_ file: String) -> (UInt64) throws -> AES.GCM.Nonce {
            { index in try AES.GCM.Nonce(data: Data(SHA256.hash(data: Data("Avenkin public fixture v2 nonce \(file) \(index)".utf8))).prefix(12)) }
        }
        try write(json(["fixtureOnly": true,
                        "packCatalogKeyLabel": CompanyVaultTests.packKeyLabel,
                        "packCatalogPublicKey": CompanyVaultTests.publicKey,
                        "companySecretLabel": CompanyVaultTests.secretLabel,
                        "otherCompanySecretLabel": Self.otherSecretLabel,
                        "derivation": "private key and company secrets are SHA-256 of the UTF-8 label",
                        "profileId": Self.profileId,
                        "otherProfileId": Self.otherProfileId]), "fixture-keys.json")

        func pack(id vaultId: String, name: String, version: String, files: [String: Data], rules: [String]) throws
            -> (zip: Data, signature: String) {
            let packId = Contract.packIdPrefix + vaultId
            let manifest: [String: Any] = ["documents": [], "files": files.keys.sorted(), "gating": ["iap": packId],
                                           "id": vaultId, "name": name, "prompt_rules": rules, "version": version]
            var entries = files
            entries["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes])
            let packJSON = try JSONSerialization.data(withJSONObject: ["id": packId, "licensePack": vaultId, "name": name,
                                                                       "vaultId": vaultId, "version": version],
                                                      options: [.sortedKeys, .withoutEscapingSlashes])
            var message = packJSON
            for path in entries.keys.sorted() { message.append(Data("\nsha256(\(path))=\(IssuanceWire.digest(entries[path]!))".utf8)) }
            let signature = try CompanyVaultTests.packKey.signature(for: message).base64EncodedString()
            entries["pack.json"] = packJSON
            return (CompanyVaultTests.storedZip(entries), signature)
        }
        let grounding = ["Never fabricate a value.", "Cite the source file for every claim."]

        // The publisher's vault, sealed for the company.
        let base = try pack(id: Self.baseId, name: "Fixture Split Systems", version: "7", files: [
            "safety.md": Data("# Safety\n\nInvented fixture: isolate the QX-100 before opening any panel.\n".utf8),
            "fault_codes.md": Data("# Fault codes\n\n| Code | Meaning | Manual |\n|---|---|---|\n| QX1 | Invented fixture fault | install-manual p. 4 |\n".utf8),
        ], rules: ["Invented fixture content. Never use it on a real unit."] + grounding)
        try write(base.zip, "fixture-split-systems-7.zip")
        let baseContext = Contract.CoreSeal.Context(profileId: Self.profileId, vaultId: Self.baseId,
                                                    packId: Contract.packIdPrefix + Self.baseId, version: "7")
        let sealedCore = try Contract.CoreSeal.seal(base.zip, context: baseContext, companySecret: Self.companySecret,
                                                    nonce: nonces("fixture-split-systems-7.zip"))
        try write(sealedCore, "fixture-split-systems-7.zip.sealed")

        // The company's layer: one added file, a plain pack.
        let layer = try pack(id: Self.layerId, name: "Fixture Company Notes", version: "2", files: [
            "site_notes.md": Data("# Site notes\n\nInvented fixture: the company stocks part QX-100-F1 for this unit.\n".utf8),
        ], rules: ["Prefer the company's own part numbers from site_notes.md."] + grounding)
        try write(layer.zip, "fixture-split-systems-company-2.zip")
        try write(Data(#"{"documents":[],"files":["fault_codes.md","site_notes.md"],"gating":{"iap":"com.openglasses.vault.fixture-split-systems-company"},"id":"fixture-split-systems-company","name":"Fixture Company Notes","prompt_rules":["Never fabricate a value.","Cite the source file for every claim."],"version":"3"}"#.utf8) + Data("\n".utf8),
                  "layer-collides-manifest.json")

        // Two manuals the company uploaded: one at the revision the vault expects, one not.
        var manuals: [Contract.Manual] = []
        for (fileName, body) in [("Installation manual.md", "# Installation manual (invented fixture)\n\nPage 4\n\nQX1: check the invented fixture interlock. Never use anything here on a real unit.\n"),
                                 ("Service manual.md", "# Service manual (invented fixture)\n\nPage 12\n\nThe company's copy, at a revision other than the vault's. Invented.\n")] {
            let text = Data(body.utf8)
            try write(text, fileName)
            let revision = IssuanceWire.digest(text)
            let sealed = try Contract.ManualSeal.seal(text, context: .init(profileId: Self.profileId, vaultId: Self.baseId,
                                                                           fileName: fileName, revision: revision),
                                                      companySecret: Self.companySecret, nonce: nonces(fileName))
            try write(sealed, fileName + ".sealed")
            manuals.append(.init(vaultId: Self.baseId, fileName: fileName, revision: revision, sizeBytes: text.count,
                                 sealedSha256: IssuanceWire.digest(sealed),
                                 downloadURL: "https://licence.example.test/c/opaque/m/\(fileName.lowercased().replacingOccurrences(of: " ", with: "-"))",
                                 kind: .md))
        }
        let expects: [Contract.ExpectedManual] = [
            .init(key: "install-manual", title: "Installation manual", edition: "Rev C", revision: manuals[0].revision),
            .init(key: "service-manual", title: "Service manual", edition: "Rev B",
                  revision: IssuanceWire.digest(Data("Invented fixture: the revision the partner wrote against.".utf8))),
            .init(key: "wiring-diagram", title: "Wiring diagram", edition: "2024"),
        ]
        func baseEntry(frozen: Bool?) -> Contract.Vault {
            .init(id: Contract.packIdPrefix + Self.baseId, vaultId: Self.baseId, version: "7", name: "Fixture Split Systems",
                  summary: "Invented fixture published vault.", author: "Fixture Publishing", minAppBuild: 691,
                  sizeBytes: sealedCore.count, downloadURL: "https://licence.example.test/c/opaque/v/fixture-split-systems-7.sealed",
                  sha256: IssuanceWire.digest(sealedCore), packSignature: base.signature, publisher: Self.publisher,
                  sealedCore: true, expects: expects, frozen: frozen)
        }
        let layerEntry = Contract.Vault(id: Contract.packIdPrefix + Self.layerId, vaultId: Self.layerId, version: "2",
                                        name: "Fixture Company Notes", minAppBuild: 691, sizeBytes: layer.zip.count,
                                        downloadURL: "https://licence.example.test/c/opaque/v/fixture-split-systems-company-2.zip",
                                        sha256: IssuanceWire.digest(layer.zip), packSignature: layer.signature,
                                        extends: Self.baseId)
        try write(try signed(catalog([baseEntry(frozen: nil), layerEntry], manuals: manuals, generation: 12)),
                  "catalog-v12.json")
        try write(try signed(catalog([baseEntry(frozen: true), layerEntry], manuals: manuals, generation: 13)),
                  "catalog-frozen-v13.json")

        // Catalogs the service refuses to sign; a phone that receives one anyway leaves the entry out.
        let published = baseEntry(frozen: nil)
        func badLayer(_ vaultId: String, extends: String, publisher: Contract.Publisher? = nil) -> Contract.Vault {
            .init(id: Contract.packIdPrefix + vaultId, vaultId: vaultId, version: "2", name: "Fixture Company Notes",
                  sizeBytes: layer.zip.count, downloadURL: "https://licence.example.test/c/opaque/v/\(vaultId)-2.zip",
                  sha256: IssuanceWire.digest(layer.zip), packSignature: layer.signature, publisher: publisher, extends: extends)
        }
        let duplicated = Contract.Vault(id: published.id, vaultId: published.vaultId, version: published.version, name: published.name,
                                        sizeBytes: published.sizeBytes, downloadURL: published.downloadURL, sha256: published.sha256,
                                        packSignature: published.packSignature, publisher: Self.publisher, sealedCore: true,
                                        expects: [expects[0], .init(key: "install-manual", title: "Installation manual", edition: "Rev D")])
        let negatives: [(String, String, [Contract.Vault])] = [
            ("extends-missing", "not a vault in this catalog", [published, badLayer(Self.layerId, extends: "fixture-not-listed")]),
            ("extends-with-publisher", "cannot also name a publisher",
             [published, badLayer(Self.layerId, extends: Self.baseId, publisher: Self.publisher)]),
            ("extends-a-layer", "itself a company layer",
             [published, badLayer(Self.layerId, extends: Self.baseId), badLayer("fixture-layer-two", extends: Self.layerId)]),
            ("expects-key-twice", "twice", [duplicated]),
        ]
        var cases: [[String: Any]] = []
        for (name, refusal, vaults) in negatives {
            let bad = catalog(vaults, generation: 12)
            XCTAssertNotNil(self.refusal(bad), name)
            let object = try JSONSerialization.jsonObject(with: try Contract.encoder().encode(bad))
            cases.append(["name": name, "refusal": refusal, "catalog": object])
        }
        try write(json(["cases": cases]), "negative-catalogs.json")
    }
}
