import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto // swift-crypto: the same API on Linux (the service's containers)
#endif
@testable import LicenceIssuance

/// Plan LV P3 — shared manuals: one encrypted copy (`SharedManualSeal`), the content key wrapped for
/// each company (`SharedManualKey`), the manual row's `shared` field and its checks. The golden
/// fixtures under `Contracts/fixtures/company-vaults-v3/` are read here and by the app's
/// `CompanySharedManualContractTests`. Invented identifiers only.
final class CompanyVaultV3Tests: XCTestCase {

    typealias Contract = CompanyVaultContract

    static let profileId = CompanyVaultTests.profileId
    static let otherProfileId = CompanyVaultV2Tests.otherProfileId
    static let thirdProfileId = "fixture-third-company"
    static let thirdSecretLabel = "Avenkin public fixture third company secret v3"
    static var companySecret: Data { CompanyVaultTests.companySecret }
    static var otherSecret: Data { CompanyVaultV2Tests.otherSecret }
    static var thirdSecret: Data { Data(SHA256.hash(data: Data(thirdSecretLabel.utf8))) }
    static let issued = CompanyVaultTests.issued

    static let vaultId = "fixture-split-systems"
    static let contentId = "c-fixture-installation-manual"
    static let fileName = "Installation manual.md"
    /// The first build that reads shared manuals, as the fixtures assume it.
    static let sharedBuild = 692

    static func contentKeyLabel(_ keyId: Int) -> String { "Avenkin public fixture shared content key v3 keyId \(keyId)" }
    static func contentKey(_ keyId: Int) -> Data { Data(SHA256.hash(data: Data(contentKeyLabel(keyId).utf8))) }

    static var fixtures: URL {
        CompanyVaultTests.fixtures.deletingLastPathComponent().appendingPathComponent("company-vaults-v3", isDirectory: true)
    }

    func fixture(_ name: String) throws -> Data { try Data(contentsOf: Self.fixtures.appendingPathComponent(name)) }

    static let digestA = String(repeating: "a", count: 64)

    func vault(minAppBuild: Int? = sharedBuild) -> Contract.Vault {
        .init(id: Contract.packIdPrefix + Self.vaultId, vaultId: Self.vaultId, version: "8", name: "Fixture Split Systems",
              minAppBuild: minAppBuild, sizeBytes: 2_048, downloadURL: "https://licence.example.test/c/opaque/v/fixture-split-systems-8.zip",
              sha256: Self.digestA, packSignature: "c2lnbmF0dXJl")
    }

    func sharedRow(_ shared: Contract.SharedManual?, fileName: String = fileName) -> Contract.Manual {
        .init(vaultId: Self.vaultId, fileName: fileName, revision: String(repeating: "b", count: 64), sizeBytes: 1_000,
              sealedSha256: String(repeating: "c", count: 64), downloadURL: "https://licence.example.test/s/\(Self.contentId)/1",
              kind: .md, shared: shared)
    }

    func validShared(keyId: Int = 1) throws -> Contract.SharedManual {
        .init(contentId: Self.contentId, keyId: keyId,
              wrappedKey: try Contract.SharedManualKey.wrap(Self.contentKey(keyId),
                                                            context: .init(profileId: Self.profileId, contentId: Self.contentId, keyId: keyId),
                                                            companySecret: Self.companySecret))
    }

    func catalog(_ vaults: [Contract.Vault], manuals: [Contract.Manual], profileId: String = profileId,
                 generation: Int = 20) -> Contract.Catalog {
        .init(profileId: profileId, generation: generation, issued: Self.issued, vaults: vaults, manuals: manuals)
    }

    func refusal(_ catalog: Contract.Catalog, floor: Int? = nil) -> String? {
        do { try Contract.check(catalog, sharedManualsMinAppBuild: floor); return nil } catch {
            guard case .invalid(let message)? = error as? Contract.Refusal else { return "\(error)" }
            return message
        }
    }

    // MARK: - Unchanged without `shared`

    func testACompanySealedRowEncodesWithoutShared() throws {
        let bytes = String(decoding: try Contract.encoder().encode(sharedRow(nil)), as: UTF8.self)
        XCTAssertFalse(bytes.contains("\"shared\""))
        XCTAssertEqual(bytes, #"{"downloadURL":"https://licence.example.test/s/c-fixture-installation-manual/1","fileName":"Installation manual.md","kind":"md","revision":"\#(String(repeating: "b", count: 64))","sealedSha256":"\#(String(repeating: "c", count: 64))","sizeBytes":1000,"vaultId":"fixture-split-systems"}"#)
        // The v1 and v2 golden payloads, manuals included, decode and encode back to their exact bytes.
        for url in [CompanyVaultTests.fixtures.appendingPathComponent("catalog-v7.json"),
                    CompanyVaultV2Tests.fixtures.appendingPathComponent("catalog-v12.json")] {
            let envelope = try JSONDecoder().decode(Contract.Envelope.self, from: try Data(contentsOf: url))
            let payload = try XCTUnwrap(Data(base64Encoded: envelope.payload))
            let decoded = try Contract.decoder().decode(Contract.Catalog.self, from: payload)
            XCTAssertEqual(try Contract.encoder().encode(decoded), payload, url.lastPathComponent)
            XCTAssertTrue(decoded.manuals.allSatisfy { $0.shared == nil })
        }
    }

    // MARK: - The seal and the key

    func testOneFileSealedOnceOpensForEveryCompanyHoldingItsKey() throws {
        let plain = Data((0..<(Contract.SharedManualSeal.contentKeyLength * 40_000)).map { UInt8($0 % 251) })
        let key = Contract.SharedManualSeal.newContentKey()
        XCTAssertEqual(key.count, 32)
        XCTAssertNotEqual(key, Contract.SharedManualSeal.newContentKey())
        let context = Contract.SharedManualSeal.Context(contentId: Self.contentId, keyId: 1)
        let sealed = try Contract.SharedManualSeal.seal(plain, context: context, contentKey: key)
        XCTAssertEqual(sealed.count, Contract.SharedManualSeal.sealedLength(plaintextBytes: plain.count))
        XCTAssertEqual(sealed.prefix(4), Data("OGSM".utf8))

        var wrapped: [String: String] = [:]
        for (profile, secret) in [(Self.profileId, Self.companySecret), (Self.otherProfileId, Self.otherSecret)] {
            let keyContext = Contract.SharedManualKey.Context(profileId: profile, contentId: Self.contentId, keyId: 1)
            let w = try Contract.SharedManualKey.wrap(key, context: keyContext, companySecret: secret)
            XCTAssertEqual(Data(base64Encoded: w)?.count, Contract.SharedManualKey.wrappedKeyLength)
            XCTAssertEqual(w.count, 80)
            wrapped[profile] = w
            let unwrapped = try Contract.SharedManualKey.unwrap(w, context: keyContext, companySecret: secret)
            XCTAssertEqual(unwrapped, key)
            XCTAssertEqual(try Contract.SharedManualSeal.open(sealed, context: context, contentKey: unwrapped,
                                                              revision: IssuanceWire.digest(plain)), plain)
        }
        XCTAssertNotEqual(wrapped[Self.profileId], wrapped[Self.otherProfileId])
    }

    func testAWrappedKeyUnwrapsOnlyForItsCompanyProfileFileAndKeyId() throws {
        let key = Self.contentKey(1)
        let right = Contract.SharedManualKey.Context(profileId: Self.profileId, contentId: Self.contentId, keyId: 1)
        let wrapped = try Contract.SharedManualKey.wrap(key, context: right, companySecret: Self.companySecret)
        func assertTampered(_ context: Contract.SharedManualKey.Context, _ secret: Data, _ message: String) {
            XCTAssertThrowsError(try Contract.SharedManualKey.unwrap(wrapped, context: context, companySecret: secret), message) {
                XCTAssertEqual($0 as? Contract.SharedManualKey.Problem, .unreadable, message)
            }
        }
        assertTampered(right, Self.otherSecret, "another company's secret")
        assertTampered(right, Self.thirdSecret, "a third company's secret")
        assertTampered(.init(profileId: Self.otherProfileId, contentId: Self.contentId, keyId: 1), Self.companySecret, "another profile")
        assertTampered(.init(profileId: Self.profileId, contentId: "c-fixture-service-manual", keyId: 1), Self.companySecret, "another file")
        assertTampered(.init(profileId: Self.profileId, contentId: Self.contentId, keyId: 2), Self.companySecret, "another keyId")
        var flipped = Data(base64Encoded: wrapped)!
        flipped[20] ^= 1
        XCTAssertThrowsError(try Contract.SharedManualKey.unwrap(flipped.base64EncodedString(), context: right, companySecret: Self.companySecret)) {
            XCTAssertEqual($0 as? Contract.SharedManualKey.Problem, .unreadable)
        }
        XCTAssertThrowsError(try Contract.SharedManualKey.unwrap("c2hvcnQ=", context: right, companySecret: Self.companySecret)) {
            XCTAssertEqual($0 as? Contract.SharedManualKey.Problem, .malformed)
        }
        XCTAssertThrowsError(try Contract.SharedManualKey.unwrap(wrapped, context: right, companySecret: Data(count: 7))) {
            XCTAssertEqual($0 as? Contract.SharedManualKey.Problem, .invalidSecret)
        }
        XCTAssertThrowsError(try Contract.SharedManualKey.wrap(Data(count: 16), context: right, companySecret: Self.companySecret))
        XCTAssertEqual(Contract.SharedManualKey.domain, "openglasses.shared-manual-key.v1")
    }

    /// A shared file opens under its own content key, context and domain only: never as a company's
    /// sealed manual or core, never under another `keyId`, and the revision is checked.
    func testTheSharedSealIsItsOwnDomain() throws {
        let plain = Data("Invented fixture bytes for the shared domain test.".utf8)
        let key = Self.contentKey(1)
        let context = Contract.SharedManualSeal.Context(contentId: Self.contentId, keyId: 1)
        let sealed = try Contract.SharedManualSeal.seal(plain, context: context, contentKey: key)
        let revision = IssuanceWire.digest(plain)
        XCTAssertThrowsError(try Contract.SharedManualSeal.open(sealed, context: .init(contentId: Self.contentId, keyId: 2),
                                                                contentKey: key, revision: revision))
        XCTAssertThrowsError(try Contract.SharedManualSeal.open(sealed, context: context, contentKey: Self.contentKey(2), revision: revision))
        XCTAssertThrowsError(try Contract.SharedManualSeal.open(sealed, context: context, contentKey: key, revision: Self.digestA)) {
            XCTAssertEqual($0 as? Contract.SharedManualSeal.Problem, .wrongRevision)
        }
        // Even keyed with the same 32 bytes, a company manual and a shared file never open as each other.
        let manualContext = Contract.ManualSeal.Context(profileId: Self.contentId, vaultId: "1", fileName: "x", revision: revision)
        let manual = try Contract.ManualSeal.seal(plain, context: manualContext, companySecret: key)
        XCTAssertThrowsError(try Contract.SharedManualSeal.open(manual, context: context, contentKey: key, revision: revision))
        XCTAssertThrowsError(try Contract.ManualSeal.open(sealed, context: manualContext, companySecret: key))
        var relabelled = manual
        relabelled.replaceSubrange(0..<4, with: Data("OGSM".utf8))
        XCTAssertThrowsError(try Contract.SharedManualSeal.open(relabelled, context: context, contentKey: key, revision: revision))
        XCTAssertEqual(Contract.SharedManualSeal.domain, "openglasses.shared-manual.v1")
        XCTAssertNotEqual(Contract.SharedManualSeal.header(), Contract.ManualSeal.header())
        XCTAssertNotEqual(Contract.SharedManualSeal.header(), Contract.CoreSeal.header())
        XCTAssertThrowsError(try Contract.SharedManualSeal.seal(plain, context: context, contentKey: Data(count: 31)))
    }

    func testSealingASharedFileStreamsToTheSameFormat() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CompanyVaultV3Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plain = Data((0..<(2 * Contract.ManualSeal.chunkSize + 11)).map { UInt8($0 % 13) })
        let input = directory.appendingPathComponent("manual.pdf"), output = directory.appendingPathComponent("manual.sealed")
        try plain.write(to: input)
        let context = Contract.SharedManualSeal.Context(contentId: Self.contentId, keyId: 3)
        let row = try Contract.SharedManualSeal.sealFile(at: input, to: output, context: context, contentKey: Self.contentKey(3))
        let sealed = try Data(contentsOf: output)
        XCTAssertEqual(row.sizeBytes, plain.count)
        XCTAssertEqual(row.revision, IssuanceWire.digest(plain))
        XCTAssertEqual(row.sealedSha256, IssuanceWire.digest(sealed))
        XCTAssertEqual(sealed.count, Contract.SharedManualSeal.sealedLength(plaintextBytes: plain.count))
        XCTAssertEqual(try Contract.SharedManualSeal.open(sealed, context: context, contentKey: Self.contentKey(3), revision: row.revision), plain)
    }

    // MARK: - The row's checks

    func testASharedRowPassesUnderAVaultThatNamesAMinimumBuild() throws {
        XCTAssertNil(refusal(catalog([vault()], manuals: [sharedRow(try validShared())])))
        XCTAssertNil(refusal(catalog([vault()], manuals: [sharedRow(try validShared())]), floor: Self.sharedBuild))
        XCTAssertNil(refusal(catalog([vault(minAppBuild: nil)], manuals: [sharedRow(nil)])), "a company-sealed row needs no minimum")
    }

    func testTheServiceRefusesABrokenSharedRow() throws {
        let good = try validShared()
        let cases: [(Contract.Catalog, Int?, String)] = [
            (catalog([vault(minAppBuild: nil)], manuals: [sharedRow(good)]), nil, "needs a minAppBuild"),
            (catalog([vault(minAppBuild: Self.sharedBuild - 1)], manuals: [sharedRow(good)]), Self.sharedBuild, "must be at least 692"),
            (catalog([vault()], manuals: [sharedRow(.init(contentId: "../escape", keyId: 1, wrappedKey: good.wrappedKey))]), nil,
             "contentId is not a safe identifier"),
            (catalog([vault()], manuals: [sharedRow(.init(contentId: Self.contentId, keyId: 0, wrappedKey: good.wrappedKey))]), nil,
             "keyId must be 1 or more"),
            (catalog([vault()], manuals: [sharedRow(.init(contentId: Self.contentId, keyId: 1, wrappedKey: "c2hvcnQ="))]), nil,
             "wrapped key is not 60 bytes"),
            (catalog([vault()], manuals: [sharedRow(.init(contentId: Self.contentId, keyId: 1, wrappedKey: "not base64!"))]), nil,
             "wrapped key"),
        ]
        for (bad, floor, expected) in cases {
            let message = refusal(bad, floor: floor)
            XCTAssertTrue(message?.contains(expected) == true, "\(expected): \(message ?? "accepted")")
        }
        XCTAssertThrowsError(try Contract.sign(catalog([vault(minAppBuild: nil)], manuals: [sharedRow(good)]),
                                               signer: CompanyVaultTests.packKey.signature(for:)), "sign checks first")
    }

    // MARK: - Golden fixtures

    func open(_ name: String, profileId: String, generation: Int) throws -> Contract.Catalog {
        try Contract.open(try fixture(name), publicKeyBase64: CompanyVaultTests.publicKey, profileId: profileId,
                          profileGeneration: generation)
    }

    /// Unwrap the row's key with `secret` and open `file` with it.
    func openShared(_ row: Contract.Manual, profileId: String, secret: Data, file: String) throws -> Data {
        let shared = try XCTUnwrap(row.shared)
        let key = try Contract.SharedManualKey.unwrap(shared.wrappedKey, context: .init(profileId: profileId, shared: shared),
                                                      companySecret: secret)
        return try Contract.SharedManualSeal.open(try fixture(file), context: .init(shared: shared), contentKey: key,
                                                  revision: row.revision)
    }

    func testTheGoldenV3FixturesOpenForBothCompaniesAndNotForAThird() throws {
        let keys = try JSONSerialization.jsonObject(with: try fixture("fixture-keys.json")) as? [String: Any]
        XCTAssertEqual(keys?["packCatalogPublicKey"] as? String, CompanyVaultTests.publicKey)
        XCTAssertEqual(keys?["thirdCompanySecretLabel"] as? String, Self.thirdSecretLabel)
        XCTAssertEqual(keys?["thirdProfileId"] as? String, Self.thirdProfileId)
        XCTAssertEqual(keys?["contentKeyLabels"] as? [String: String], ["1": Self.contentKeyLabel(1), "2": Self.contentKeyLabel(2)])

        let plain = try fixture(Self.fileName)
        let mine = try open("catalog-fixture-company-v20.json", profileId: Self.profileId, generation: 20)
        let theirs = try open("catalog-fixture-other-company-v20.json", profileId: Self.otherProfileId, generation: 20)
        XCTAssertNoThrow(try Contract.check(mine, sharedManualsMinAppBuild: Self.sharedBuild))
        XCTAssertNoThrow(try Contract.check(theirs, sharedManualsMinAppBuild: Self.sharedBuild))
        XCTAssertEqual(mine.vaults.first?.minAppBuild, Self.sharedBuild)
        let a = try XCTUnwrap(mine.manuals.first), b = try XCTUnwrap(theirs.manuals.first)
        // One file, one address, one digest: only the wrapped key differs.
        XCTAssertEqual(a.downloadURL, b.downloadURL)
        XCTAssertEqual(a.sealedSha256, b.sealedSha256)
        XCTAssertEqual(a.revision, IssuanceWire.digest(plain))
        XCTAssertEqual(a.sizeBytes, plain.count)
        XCTAssertEqual(a.sealedSha256, IssuanceWire.digest(try fixture("installation-manual.k1.sealed")))
        XCTAssertEqual(a.shared?.contentId, Self.contentId)
        XCTAssertEqual(a.shared?.keyId, 1)
        XCTAssertNotEqual(a.shared?.wrappedKey, b.shared?.wrappedKey)
        XCTAssertEqual(try openShared(a, profileId: Self.profileId, secret: Self.companySecret, file: "installation-manual.k1.sealed"), plain)
        XCTAssertEqual(try openShared(b, profileId: Self.otherProfileId, secret: Self.otherSecret, file: "installation-manual.k1.sealed"), plain)
        // A third company: neither row's key unwraps with its secret, under its profile or theirs.
        for (row, profile) in [(a, Self.profileId), (b, Self.otherProfileId), (a, Self.thirdProfileId)] {
            XCTAssertThrowsError(try openShared(row, profileId: profile, secret: Self.thirdSecret, file: "installation-manual.k1.sealed"))
        }

        // The rotation: keyId 2, a new file; both companies open it; the old key opens nothing still served.
        let mineAfter = try open("catalog-fixture-company-v21.json", profileId: Self.profileId, generation: 21)
        let theirsAfter = try open("catalog-fixture-other-company-v21.json", profileId: Self.otherProfileId, generation: 21)
        let a2 = try XCTUnwrap(mineAfter.manuals.first), b2 = try XCTUnwrap(theirsAfter.manuals.first)
        XCTAssertEqual(a2.shared?.keyId, 2)
        XCTAssertEqual(a2.revision, a.revision, "the same manual, re-encrypted")
        XCTAssertNotEqual(a2.sealedSha256, a.sealedSha256)
        XCTAssertNotEqual(a2.downloadURL, a.downloadURL)
        XCTAssertEqual(a2.sealedSha256, IssuanceWire.digest(try fixture("installation-manual.k2.sealed")))
        XCTAssertEqual(try openShared(a2, profileId: Self.profileId, secret: Self.companySecret, file: "installation-manual.k2.sealed"), plain)
        XCTAssertEqual(try openShared(b2, profileId: Self.otherProfileId, secret: Self.otherSecret, file: "installation-manual.k2.sealed"), plain)
        XCTAssertThrowsError(try openShared(a, profileId: Self.profileId, secret: Self.companySecret, file: "installation-manual.k2.sealed"),
                             "a key kept from before the rotation opens nothing still served")
    }

    func testTheNegativeFixturesAreRefused() throws {
        struct Case: Decodable { let name: String; let refusal: String; let catalog: Contract.Catalog }
        struct Cases: Decodable { let cases: [Case] }
        let cases = try Contract.decoder().decode(Cases.self, from: try fixture("negative-catalogs.json")).cases
        XCTAssertEqual(cases.map(\.name), ["shared-without-min-app-build", "shared-key-id-zero", "shared-content-id-unsafe",
                                           "shared-wrapped-key-short"])
        for item in cases {
            let message = refusal(item.catalog)
            XCTAssertTrue(message?.contains(item.refusal) == true, "\(item.name): \(message ?? "accepted")")
        }
    }

    func testTheNegativeKeysNeverOpenTheManual() throws {
        struct Case: Decodable {
            let name: String; let profileId: String; let secretLabel: String
            let shared: Contract.SharedManual; let file: String; let revision: String; let fails: String
        }
        struct Cases: Decodable { let cases: [Case] }
        let cases = try JSONDecoder().decode(Cases.self, from: try fixture("negative-keys.json")).cases
        XCTAssertEqual(cases.map(\.name), ["another-company-secret", "wrapped-for-another-profile", "stale-key-against-rotated-file",
                                           "new-key-named-with-stale-key-id"])
        for item in cases {
            let secret = Data(SHA256.hash(data: Data(item.secretLabel.utf8)))
            let context = Contract.SharedManualKey.Context(profileId: item.profileId, shared: item.shared)
            switch item.fails {
            case "unwrap":
                XCTAssertThrowsError(try Contract.SharedManualKey.unwrap(item.shared.wrappedKey, context: context, companySecret: secret),
                                     item.name) { XCTAssertEqual($0 as? Contract.SharedManualKey.Problem, .unreadable, item.name) }
            case "open":
                let key = try Contract.SharedManualKey.unwrap(item.shared.wrappedKey, context: context, companySecret: secret)
                XCTAssertThrowsError(try Contract.SharedManualSeal.open(try fixture(item.file), context: .init(shared: item.shared),
                                                                        contentKey: key, revision: item.revision), item.name) {
                    XCTAssertEqual($0 as? Contract.SharedManualSeal.Problem, .unreadable, item.name)
                }
            default:
                XCTFail("\(item.name): \(item.fails)")
            }
        }
    }

    /// Writes `Contracts/fixtures/company-vaults-v3/`. The content keys and every nonce are derived
    /// from public labels, so the sealed files and wrapped keys regenerate to the same bytes; the
    /// catalogs' signatures do not (randomised Ed25519). Set `REGENERATE_COMPANY_VAULT_V3_FIXTURES=1`.
    func testRegenerateV3Fixtures() throws {
        guard ProcessInfo.processInfo.environment["REGENERATE_COMPANY_VAULT_V3_FIXTURES"] == "1" else { return }
        try FileManager.default.createDirectory(at: Self.fixtures, withIntermediateDirectories: true)
        func write(_ data: Data, _ name: String) throws { try data.write(to: Self.fixtures.appendingPathComponent(name)) }
        func json(_ object: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]) + Data("\n".utf8)
        }
        func label(_ text: String) -> Data { Data(SHA256.hash(data: Data(("Avenkin public fixture v3 nonce " + text).utf8))) }
        func chunkNonces(_ file: String) -> (UInt64) throws -> AES.GCM.Nonce {
            { index in try AES.GCM.Nonce(data: label("\(file) \(index)").prefix(12)) }
        }
        func wrapNonce(_ profileId: String, _ keyId: Int) throws -> AES.GCM.Nonce {
            try AES.GCM.Nonce(data: label("wrap \(profileId) \(keyId)").prefix(12))
        }
        try write(json(["fixtureOnly": true,
                        "packCatalogKeyLabel": CompanyVaultTests.packKeyLabel,
                        "packCatalogPublicKey": CompanyVaultTests.publicKey,
                        "companySecretLabel": CompanyVaultTests.secretLabel,
                        "otherCompanySecretLabel": CompanyVaultV2Tests.otherSecretLabel,
                        "thirdCompanySecretLabel": Self.thirdSecretLabel,
                        "contentKeyLabels": ["1": Self.contentKeyLabel(1), "2": Self.contentKeyLabel(2)],
                        "derivation": "private key, company secrets and content keys are SHA-256 of the UTF-8 label",
                        "profileId": Self.profileId,
                        "otherProfileId": Self.otherProfileId,
                        "thirdProfileId": Self.thirdProfileId,
                        "sharedManualsMinAppBuild": Self.sharedBuild]), "fixture-keys.json")

        // The vault the shared manual belongs to: a plain pack, the same for both companies.
        let packId = Contract.packIdPrefix + Self.vaultId
        let manifest: [String: Any] = ["documents": [], "files": ["safety.md"], "gating": ["iap": packId], "id": Self.vaultId,
                                       "name": "Fixture Split Systems",
                                       "prompt_rules": ["Invented fixture content. Never use it on a real unit.",
                                                        "Never fabricate a value.", "Cite the source file for every claim."],
                                       "version": "8"]
        var entries: [String: Data] = [
            "safety.md": Data("# Safety\n\nInvented fixture: isolate the QX-100 before opening any panel.\n".utf8),
            "manifest.json": try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .withoutEscapingSlashes]),
        ]
        let packJSON = try JSONSerialization.data(withJSONObject: ["id": packId, "licensePack": Self.vaultId, "name": "Fixture Split Systems",
                                                                   "vaultId": Self.vaultId, "version": "8"],
                                                  options: [.sortedKeys, .withoutEscapingSlashes])
        var message = packJSON
        for path in entries.keys.sorted() { message.append(Data("\nsha256(\(path))=\(IssuanceWire.digest(entries[path]!))".utf8)) }
        let packSignature = try CompanyVaultTests.packKey.signature(for: message).base64EncodedString()
        entries["pack.json"] = packJSON
        let zip = CompanyVaultTests.storedZip(entries)
        try write(zip, "fixture-split-systems-8.zip")
        let vaultRow = Contract.Vault(id: packId, vaultId: Self.vaultId, version: "8", name: "Fixture Split Systems",
                                      summary: "Invented fixture vault with a shared manual.", author: "Fixture Publishing",
                                      minAppBuild: Self.sharedBuild, sizeBytes: zip.count,
                                      downloadURL: "https://licence.example.test/c/opaque/v/fixture-split-systems-8.zip",
                                      sha256: IssuanceWire.digest(zip), packSignature: packSignature)

        // The one shared manual, sealed under keyId 1 and, after a rotation, keyId 2.
        let plain = Data("# Installation manual (invented fixture)\n\nPage 4\n\nQX1: check the invented fixture interlock. One copy, shared by every company the partner chose. Never use anything here on a real unit.\n".utf8)
        try write(plain, Self.fileName)
        let revision = IssuanceWire.digest(plain)
        var sealedDigest: [Int: String] = [:]
        for keyId in [1, 2] {
            let sealed = try Contract.SharedManualSeal.seal(plain, context: .init(contentId: Self.contentId, keyId: keyId),
                                                            contentKey: Self.contentKey(keyId),
                                                            nonce: chunkNonces("installation-manual.k\(keyId).sealed"))
            try write(sealed, "installation-manual.k\(keyId).sealed")
            sealedDigest[keyId] = IssuanceWire.digest(sealed)
        }
        func shared(_ profileId: String, secret: Data, keyId: Int) throws -> Contract.SharedManual {
            .init(contentId: Self.contentId, keyId: keyId,
                  wrappedKey: try Contract.SharedManualKey.wrap(Self.contentKey(keyId),
                                                                context: .init(profileId: profileId, contentId: Self.contentId, keyId: keyId),
                                                                companySecret: secret, nonce: try wrapNonce(profileId, keyId)))
        }
        func row(_ shared: Contract.SharedManual) -> Contract.Manual {
            .init(vaultId: Self.vaultId, fileName: Self.fileName, revision: revision, sizeBytes: plain.count,
                  sealedSha256: sealedDigest[shared.keyId]!,
                  downloadURL: "https://licence.example.test/s/\(Self.contentId)/\(shared.keyId)", kind: .md, shared: shared)
        }
        let companies = [(Self.profileId, Self.companySecret), (Self.otherProfileId, Self.otherSecret)]
        var rows: [String: [Int: Contract.Manual]] = [:]
        for (profileId, secret) in companies {
            for (keyId, generation) in [(1, 20), (2, 21)] {
                let manual = row(try shared(profileId, secret: secret, keyId: keyId))
                rows[profileId, default: [:]][keyId] = manual
                try write(try Contract.sign(catalog([vaultRow], manuals: [manual], profileId: profileId, generation: generation),
                                            signer: CompanyVaultTests.packKey.signature(for:), sharedManualsMinAppBuild: Self.sharedBuild),
                          "catalog-\(profileId)-v\(generation).json")
            }
        }

        // Catalogs the service refuses to sign; a phone that receives one anyway leaves the row out.
        let good = rows[Self.profileId]![1]!
        let goodShared = good.shared!
        func variant(_ shared: Contract.SharedManual) -> Contract.Manual {
            .init(vaultId: good.vaultId, fileName: good.fileName, revision: good.revision, sizeBytes: good.sizeBytes,
                  sealedSha256: good.sealedSha256, downloadURL: good.downloadURL, kind: good.kind, shared: shared)
        }
        let noMinimum = Contract.Vault(id: vaultRow.id, vaultId: vaultRow.vaultId, version: vaultRow.version, name: vaultRow.name,
                                       summary: vaultRow.summary, author: vaultRow.author, sizeBytes: vaultRow.sizeBytes,
                                       downloadURL: vaultRow.downloadURL, sha256: vaultRow.sha256, packSignature: vaultRow.packSignature)
        let negatives: [(String, String, Contract.Vault, Contract.Manual)] = [
            ("shared-without-min-app-build", "needs a minAppBuild", noMinimum, good),
            ("shared-key-id-zero", "keyId must be 1 or more", vaultRow,
             variant(.init(contentId: goodShared.contentId, keyId: 0, wrappedKey: goodShared.wrappedKey))),
            ("shared-content-id-unsafe", "contentId is not a safe identifier", vaultRow,
             variant(.init(contentId: "../\(Self.contentId)", keyId: 1, wrappedKey: goodShared.wrappedKey))),
            ("shared-wrapped-key-short", "wrapped key is not 60 bytes", vaultRow,
             variant(.init(contentId: goodShared.contentId, keyId: 1, wrappedKey: String(goodShared.wrappedKey.prefix(40))))),
        ]
        var cases: [[String: Any]] = []
        for (name, refusal, vault, manual) in negatives {
            let bad = catalog([vault], manuals: [manual])
            XCTAssertNotNil(self.refusal(bad), name)
            let object = try JSONSerialization.jsonObject(with: try Contract.encoder().encode(bad))
            cases.append(["name": name, "refusal": refusal, "catalog": object])
        }
        try write(json(["cases": cases]), "negative-catalogs.json")

        // Keys that never open the manual.
        func object(_ shared: Contract.SharedManual) -> [String: Any] {
            ["contentId": shared.contentId, "keyId": shared.keyId, "wrappedKey": shared.wrappedKey]
        }
        let other = rows[Self.otherProfileId]![1]!.shared!
        let rotated = rows[Self.profileId]![2]!.shared!
        let keyCases: [[String: Any]] = [
            ["name": "another-company-secret", "profileId": Self.profileId, "secretLabel": Self.thirdSecretLabel,
             "shared": object(goodShared), "file": "installation-manual.k1.sealed", "revision": revision, "fails": "unwrap"],
            ["name": "wrapped-for-another-profile", "profileId": Self.profileId, "secretLabel": CompanyVaultTests.secretLabel,
             "shared": object(other), "file": "installation-manual.k1.sealed", "revision": revision, "fails": "unwrap"],
            ["name": "stale-key-against-rotated-file", "profileId": Self.profileId, "secretLabel": CompanyVaultTests.secretLabel,
             "shared": object(goodShared), "file": "installation-manual.k2.sealed", "revision": revision, "fails": "open"],
            ["name": "new-key-named-with-stale-key-id", "profileId": Self.profileId, "secretLabel": CompanyVaultTests.secretLabel,
             "shared": object(.init(contentId: rotated.contentId, keyId: 1, wrappedKey: rotated.wrappedKey)),
             "file": "installation-manual.k2.sealed", "revision": revision, "fails": "unwrap"],
        ]
        try write(json(["cases": keyCases]), "negative-keys.json")
    }
}
