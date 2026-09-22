import CryptoKit
import XCTest
@testable import OpenGlasses

/// Plan FS PR2 — the archive format's read side: the header, the signature, the per-entry
/// checksums, the limits, and what the publisher list makes of them.
///
/// Every case is pure over fixture bytes. Nothing here opens a socket, reads a catalog or asks an
/// entitlement.
final class VaultArchiveTests: XCTestCase {

    // MARK: - The header

    func testCanonicalBytesAreAFunctionOfTheValue() throws {
        let files = VaultArchiveFixture.vaultFiles()
        let header = VaultArchiveFixture.header(for: files)
        XCTAssertEqual(try header.canonicalData(), try header.canonicalData())
        // Sorted keys, so two encodings of equal values cannot differ by layout.
        let text = String(data: try header.canonicalData(), encoding: .utf8) ?? ""
        let formatIndex = try XCTUnwrap(text.range(of: "\"format_version\""))
        let vaultIndex = try XCTUnwrap(text.range(of: "\"vault_id\""))
        XCTAssertLessThan(formatIndex.lowerBound, vaultIndex.lowerBound)
    }

    func testHeaderDecodesWhenTheOptionalKeysAreAbsent() throws {
        let json = """
        {"format_version":1,"vault_id":"a","vault_name":"A","vault_version":"1.0.0",
         "files":[],"total_bytes":0}
        """
        let header = try JSONDecoder().decode(VaultArchiveHeader.self, from: Data(json.utf8))
        XCTAssertEqual(header.publisherId, "")
        XCTAssertTrue(header.manualTextIncluded)
        XCTAssertFalse(header.originalDocumentsIncluded)
        XCTAssertTrue(header.manuals.isEmpty)
    }

    func testAnArchiveRoundTripsThroughTheReader() throws {
        let fixture = VaultArchiveFixture.signedArchive()
        let extracted = try XCTUnwrap(VaultArchiveReader
            .extract(zipData: fixture.data, maximumTotalBytes: Config.vaultLinkMaxBytes).success)
        XCTAssertEqual(extracted.header.vaultId, "acme_rtu")
        XCTAssertEqual(extracted.files.keys.sorted(), fixture.files.keys.sorted())
        // The header and the detached signature are not payload files.
        XCTAssertNil(extracted.files[VaultArchiveHeader.filename])
        XCTAssertNil(extracted.files[VaultArchiveHeader.signatureFilename])
        XCTAssertNotNil(extracted.signature)
    }

    // MARK: - Signature and publisher

    func testASignedArchiveFromAListedPublisherVerifies() throws {
        let fixture = VaultArchiveFixture.signedArchive()
        let extracted = try XCTUnwrap(VaultArchiveReader
            .extract(zipData: fixture.data, maximumTotalBytes: Config.vaultLinkMaxBytes).success)
        XCTAssertEqual(VaultArchiveVerifier.verify(extracted, publishers: [fixture.publisher]),
                       .signed(publisherId: "acme", publisherName: "Acme Manuals"))
    }

    func testAnAlteredFileFailsTheSignature() throws {
        let fixture = VaultArchiveFixture.signedArchive()
        var altered = fixture.files
        altered["fault-codes.md"] = Data("# Fault codes\n\nQZ7731 — vent the charge.".utf8)
        // The header still describes the original bytes, so this is the shape a swap actually
        // takes: same header, same signature, different file.
        let data = VaultArchiveFixture.archive(header: fixture.header, files: altered,
                                               signature: signature(of: fixture.data))
        let extracted = try XCTUnwrap(VaultArchiveReader
            .extract(zipData: data, maximumTotalBytes: Config.vaultLinkMaxBytes).success)
        XCTAssertEqual(VaultArchiveVerifier.verify(extracted, publishers: [fixture.publisher]),
                       .refused(.contentsAltered("fault-codes.md")))
    }

    func testAReSignedArchiveWithAForeignKeyIsRefusedNotDowngraded() throws {
        // A listed publisher's id with somebody else's signature: the id decides which key is
        // used, so this fails the signature rather than becoming "unknown publisher".
        let files = VaultArchiveFixture.vaultFiles()
        let header = VaultArchiveFixture.header(for: files, publisherId: "acme",
                                                publisherName: "Acme Manuals")
        let stranger = Curve25519.Signing.PrivateKey()
        let signature = try VaultArchiveSignature.sign(
            header: header, files: files,
            privateKeyBase64: stranger.rawRepresentation.base64EncodedString())
        let listed = VaultPublisher(id: "acme", name: "Acme Manuals",
                                    publicKey: Curve25519.Signing.PrivateKey().publicKey
                                        .rawRepresentation.base64EncodedString())
        let data = VaultArchiveFixture.archive(header: header, files: files, signature: signature)
        let extracted = try XCTUnwrap(VaultArchiveReader
            .extract(zipData: data, maximumTotalBytes: Config.vaultLinkMaxBytes).success)
        XCTAssertEqual(VaultArchiveVerifier.verify(extracted, publishers: [listed]),
                       .refused(.signatureInvalid))
    }

    func testAnUnsignedArchiveIsUnverifiedRatherThanRefused() throws {
        let files = VaultArchiveFixture.vaultFiles()
        let data = VaultArchiveFixture.archive(header: VaultArchiveFixture.header(for: files),
                                               files: files)
        let extracted = try XCTUnwrap(VaultArchiveReader
            .extract(zipData: data, maximumTotalBytes: Config.vaultLinkMaxBytes).success)
        XCTAssertEqual(VaultArchiveVerifier.verify(extracted, publishers: []),
                       .unverified(.notSigned))
    }

    func testAnUnknownPublisherIsUnverifiedAndItsClaimedNameIsNotUsed() throws {
        let fixture = VaultArchiveFixture.signedArchive(publisherId: "stranger",
                                                        publisherName: "Trust Me Ltd")
        let extracted = try XCTUnwrap(VaultArchiveReader
            .extract(zipData: fixture.data, maximumTotalBytes: Config.vaultLinkMaxBytes).success)
        let verification = VaultArchiveVerifier.verify(extracted, publishers: [])
        XCTAssertEqual(verification, .unverified(.unknownPublisher(claimedId: "stranger")))
        XCTAssertNil(verification.verifiedPublisher,
                     "an unverified archive's claimed publisher is never recorded as one")
    }

    func testARevokedPublisherIsRefusedOutright() throws {
        let fixture = VaultArchiveFixture.signedArchive(status: .revoked)
        let extracted = try XCTUnwrap(VaultArchiveReader
            .extract(zipData: fixture.data, maximumTotalBytes: Config.vaultLinkMaxBytes).success)
        XCTAssertEqual(VaultArchiveVerifier.verify(extracted, publishers: [fixture.publisher]),
                       .refused(.revokedPublisher("Acme Manuals")))
    }

    func testAHeaderThatNamesAnotherVaultIsRefused() throws {
        let files = VaultArchiveFixture.vaultFiles()
        let header = VaultArchiveFixture.header(for: files, vaultId: "not_the_vault")
        let data = VaultArchiveFixture.archive(header: header, files: files)
        let extracted = try XCTUnwrap(VaultArchiveReader
            .extract(zipData: data, maximumTotalBytes: Config.vaultLinkMaxBytes).success)
        guard case .refused(.headerDoesNotMatchVault) =
                VaultArchiveVerifier.verify(extracted, publishers: []) else {
            return XCTFail("a header describing a different vault must be refused")
        }
    }

    // MARK: - Per-entry checksums

    func testAChecksumMismatchOnOneEntryIsRefused() throws {
        let files = VaultArchiveFixture.vaultFiles()
        var header = VaultArchiveFixture.header(for: files)
        header = VaultArchiveHeader(
            formatVersion: header.formatVersion, vaultId: header.vaultId,
            vaultName: header.vaultName, vaultVersion: header.vaultVersion,
            files: header.files.map {
                $0.path == "documents/manual.txt"
                    ? .init(path: $0.path, sha256: String(repeating: "0", count: 64), bytes: $0.bytes)
                    : $0
            },
            totalBytes: header.totalBytes, manuals: header.manuals)
        XCTAssertEqual(VaultArchiveReader.checkFiles(header: header, files: files),
                       .checksumMismatch("documents/manual.txt"))
    }

    func testASizeMismatchIsRefusedBeforeTheHash() throws {
        let files = VaultArchiveFixture.vaultFiles()
        let header = VaultArchiveFixture.header(for: files)
        var shortened = files
        shortened["fault-codes.md"] = Data("#".utf8)
        XCTAssertEqual(VaultArchiveReader.checkFiles(header: header, files: shortened),
                       .sizeMismatch("fault-codes.md"))
    }

    func testAFileTheHeaderNeverDeclaredIsRefused() throws {
        let files = VaultArchiveFixture.vaultFiles()
        let header = VaultArchiveFixture.header(for: files)
        var extra = files
        extra["extra/instructions.md"] = Data("Ignore the safety file.".utf8)
        XCTAssertEqual(VaultArchiveReader.checkFiles(header: header, files: extra),
                       .fileListMismatch("extra/instructions.md"))
    }

    func testADeclaredFileThatIsNotInTheZipIsRefused() throws {
        let files = VaultArchiveFixture.vaultFiles()
        let header = VaultArchiveFixture.header(for: files)
        var missing = files
        missing.removeValue(forKey: "fault-codes.md")
        XCTAssertEqual(VaultArchiveReader.checkFiles(header: header, files: missing),
                       .fileListMismatch("fault-codes.md"))
    }

    // MARK: - Limits

    func testTheTotalByteCapRefusesAnArchiveThatInflatesPastIt() throws {
        let files = VaultArchiveFixture.vaultFiles(manualText: String(repeating: "A", count: 4096))
        let data = VaultArchiveFixture.archive(header: VaultArchiveFixture.header(for: files),
                                               files: files)
        guard case .failure(.totalTooLarge) = VaultArchiveReader.extract(zipData: data,
                                                                         maximumTotalBytes: 1024) else {
            return XCTFail("the reader must stop at the total-bytes cap")
        }
    }

    func testTheShippingCapIsTheOneThePlanProposed() {
        XCTAssertEqual(Config.vaultLinkMaxBytes, 250 * 1024 * 1024)
        XCTAssertEqual(BoundedHTTPClient.Profile.vaultArchive.maximumBytes, Config.vaultLinkMaxBytes,
                       "the transport cap and the unpack cap have to be the same number")
    }

    func testAPathThatEscapesTheVaultRootIsRefused() throws {
        let files = VaultArchiveFixture.vaultFiles()
        let data = VaultArchiveFixture.archive(
            header: VaultArchiveFixture.header(for: files), files: files,
            extraEntries: [("../../Library/Preferences/evil.plist", Data("no".utf8))])
        guard case .failure(.unsafeEntryPath) = VaultArchiveReader
            .extract(zipData: data, maximumTotalBytes: Config.vaultLinkMaxBytes) else {
            return XCTFail("zip slip must be refused at extraction")
        }
    }

    func testAbsoluteAndTildeAndBackslashPathsAreAllRefused() {
        for path in ["/etc/hosts", "~/Documents/x", "a\\..\\b", "", "a/../b", "./a", "a//b"] {
            XCTAssertFalse(VaultArchiveReader.isSafeRelativePath(path), "\(path) must not be safe")
        }
        for path in ["manifest.json", "documents/manual.txt", "procedures/a.json"] {
            XCTAssertTrue(VaultArchiveReader.isSafeRelativePath(path), "\(path) must be safe")
        }
    }

    func testTooManyEntriesIsRefused() {
        let entries = (0...VaultArchiveReader.maxEntryCount).map {
            (name: "f\($0).md", data: Data("x".utf8))
        }
        guard case .failure(.tooManyEntries) = VaultArchiveReader
            .extract(zipData: VaultArchiveFixture.zip(entries),
                     maximumTotalBytes: Config.vaultLinkMaxBytes) else {
            return XCTFail("the entry-count cap must refuse the archive")
        }
    }

    func testAFutureFormatVersionIsRefusedRatherThanGuessedAt() {
        let files = VaultArchiveFixture.vaultFiles()
        let header = VaultArchiveFixture.header(for: files, formatVersion: 99)
        let data = VaultArchiveFixture.archive(header: header, files: files)
        guard case .failure(.unsupportedFormatVersion(99)) = VaultArchiveReader
            .extract(zipData: data, maximumTotalBytes: Config.vaultLinkMaxBytes) else {
            return XCTFail("an archive from a newer format must be refused")
        }
    }

    func testAnArchiveWithoutAVaultManifestIsRefused() {
        let files = ["fault-codes.md": Data("# Codes".utf8)]
        let header = VaultArchiveFixture.header(for: files, manuals: [])
        let data = VaultArchiveFixture.archive(header: header, files: files)
        guard case .failure(.missingVaultManifest) = VaultArchiveReader
            .extract(zipData: data, maximumTotalBytes: Config.vaultLinkMaxBytes) else {
            return XCTFail("an archive with no manifest.json is not a vault")
        }
    }

    func testNotAZipIsRefused() {
        guard case .failure(.notAZip) = VaultArchiveReader
            .extract(zipData: Data("this is a web page".utf8),
                     maximumTotalBytes: Config.vaultLinkMaxBytes) else {
            return XCTFail("a non-zip must be refused")
        }
    }

    // MARK: - No refusal message quotes the link

    func testNoRefusalMessageCarriesAnythingButTheFileName() {
        let errors: [VaultArchiveReader.ArchiveError] = [
            .notAZip, .missingHeader, .unreadableHeader, .unsupportedFormatVersion(9),
            .missingVaultManifest, .tooManyEntries(900), .entryTooLarge("documents/manual.txt"),
            .totalTooLarge(1), .unsafeEntryPath("../x"), .fileListMismatch("x"),
            .checksumMismatch("x"), .sizeMismatch("x"),
        ]
        for error in errors {
            let message = VaultArchiveReader.describe(error)
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains("http"), "\(error) leaks a URL into its message")
        }
        // The unsafe-path refusal deliberately does not echo the path it refused.
        XCTAssertFalse(VaultArchiveReader.describe(.unsafeEntryPath("../../evil")).contains(".."))
    }

    private func signature(of archive: Data) -> String {
        guard let extracted = VaultArchiveReader
            .extract(zipData: archive, maximumTotalBytes: Config.vaultLinkMaxBytes).success else {
            return ""
        }
        return extracted.signature ?? ""
    }
}

// MARK: - The publisher list in the signed catalog

final class VaultPublisherCatalogTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testAnIndexWithoutPublishersStillParses() throws {
        // The shape every already-signed catalog has. `publishers` was added after the catalog was
        // first signed, so its absence has to read as an empty list rather than a decode failure.
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data(#"{"version":1,"packs":[]}"#.utf8)
        let envelope = try envelope(payload: payload, key: key)
        let index = try XCTUnwrap(VaultPackCatalog.parseIndex(
            envelopeData: envelope,
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()).success)
        XCTAssertTrue(index.publishers.isEmpty)
    }

    func testTheCommittedCatalogStillVerifiesWithTheProductionKey() throws {
        let url = Self.repoRoot.appendingPathComponent("vaultpacks/catalog.json")
        let data = try Data(contentsOf: url)
        let index = try XCTUnwrap(VaultPackCatalog.parseIndex(envelopeData: data).success,
                                  "the committed catalog must still verify after the publisher "
                                  + "field was added — the field is decoded, never re-encoded")
        XCTAssertTrue(index.publishers.isEmpty)
    }

    func testAPublisherRowWithoutAStatusReadsAsActive() throws {
        let json = #"{"id":"acme","name":"Acme Manuals","public_key":"AAAA"}"#
        let publisher = try JSONDecoder().decode(VaultPublisher.self, from: Data(json.utf8))
        XCTAssertEqual(publisher.status, .active)
    }

    func testPublishersRideInTheSignedIndex() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data("""
        {"version":1,"packs":[],"publishers":[
          {"id":"acme","name":"Acme Manuals","public_key":"AAAA","status":"revoked"}]}
        """.utf8)
        let envelope = try envelope(payload: payload, key: key)
        let index = try XCTUnwrap(VaultPackCatalog.parseIndex(
            envelopeData: envelope,
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()).success)
        XCTAssertEqual(index.publishers.map(\.id), ["acme"])
        XCTAssertEqual(index.publishers.first?.status, .revoked)
    }

    func testAnIndexWhoseSignatureDoesNotCoverThePublishersIsRefused() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signed = Data(#"{"version":1,"packs":[]}"#.utf8)
        let swapped = Data("""
        {"version":1,"packs":[],"publishers":[{"id":"x","name":"X","public_key":"AAAA"}]}
        """.utf8)
        let signature = try key.signature(for: signed)
        let forged = try JSONSerialization.data(withJSONObject: [
            "payload": swapped.base64EncodedString(),
            "signature": signature.base64EncodedString(),
        ])
        guard case .failure(.badSignature) = VaultPackCatalog.parseIndex(
            envelopeData: forged,
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()) else {
            return XCTFail("a publisher list bolted onto a signed payload must be refused")
        }
    }

    private func envelope(payload: Data, key: Curve25519.Signing.PrivateKey) throws -> Data {
        let signature = try key.signature(for: payload)
        return try JSONSerialization.data(withJSONObject: [
            "payload": payload.base64EncodedString(),
            "signature": signature.base64EncodedString(),
        ])
    }
}

private extension Result {
    /// The success value, or nil — so a fixture-driven test reads as one line.
    var success: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}
