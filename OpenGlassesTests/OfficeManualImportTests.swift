import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

final class OfficeManualImportTests: XCTestCase {
    private let now: Int64 = 1_800_000_000
    private func fixture(_ name: String, extension ext: String) throws -> Data {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
        #else
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: ext)
        #endif
        return try Data(contentsOf: XCTUnwrap(url))
    }
    private func publisher(status: VaultPublisher.Status = .active) throws -> VaultPublisher {
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("manual-fixture-keys", extension: "json")) as? [String: Any])
        return .init(id: "fixture-publisher", name: "Fictional Publisher",
                     publicKey: try XCTUnwrap(keys["publisherPublicKey"] as? String), status: status)
    }
    private func assignment(archive: Data? = nil, mutation: ((inout [String: Any]) -> Void)? = nil,
                            highWater: OfficeManualAssignment.HighWater? = nil) throws -> OfficeManualAssignment.Verified {
        var envelope = try fixture("manual-assignment-v1", extension: "json")
        let seed = Data(SHA256.hash(data: Data("Avenkin public fixture office key v1".utf8)))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        if archive != nil || mutation != nil {
            let e = try JSONDecoder().decode(OfficeManualAssignment.Envelope.self, from: envelope)
            var p = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: e.payload))) as? [String: Any])
            if let archive { p["archiveBytes"] = archive.count; p["archiveSHA256"] = VaultArchiveReader.sha256Hex(archive) }
            mutation?(&p)
            let raw = try JSONSerialization.data(withJSONObject: p, options: [.sortedKeys])
            let signature = try key.signature(for: OfficeManualAssignment.domain + raw)
            envelope = try JSONEncoder().encode(OfficeManualAssignment.Envelope(payload: raw.base64EncodedString(), signature: signature.base64EncodedString()))
        }
        let trust = OfficeManualAssignment.Trust(organizationID: "fixture-org", enrolmentID: "fixture-phone",
            officeID: "fixture-office", generation: 1, setID: "fixture-set", publicKey: key.publicKey.rawRepresentation,
            maximumArchiveBytes: 1_048_576)
        return try OfficeManualAssignment.verify(envelope, trust: trust, now: now, highWater: highWater)
    }
    private func prepare(_ archive: Data, assignment: OfficeManualAssignment.Verified? = nil,
                         publishers: [VaultPublisher]? = nil, maximum: Int = 1_048_576) throws -> OfficeManualImport.Prepared {
        try OfficeManualImport.prepare(assignment: assignment ?? self.assignment(), archive: archive,
            publishers: publishers ?? [publisher()], maximumInflatedBytes: maximum,
            receivedAt: Date(timeIntervalSince1970: TimeInterval(now)))
    }
    private func signedArchive(files: [String: Data], headerVersion: String = "1.0.0", signed: Bool = true) throws -> Data {
        let header = VaultArchiveFixture.header(for: files, vaultId: "fixture-vault", vaultVersion: headerVersion,
            publisherId: "fixture-publisher", publisherName: "Fictional Publisher")
        let seed = Data(SHA256.hash(data: Data("Avenkin public fixture publisher key v1".utf8)))
        let signature = signed ? try VaultArchiveSignature.sign(header: header, files: files, privateKeyBase64: seed.base64EncodedString()) : nil
        return VaultArchiveFixture.archive(header: header, files: files, signature: signature)
    }
    func testSharedSignedArchivePreparesExistingVaultFiles() throws {
        let archive = try fixture("manual-vault-v1", extension: "zip")
        let prepared = try prepare(archive)
        XCTAssertEqual(prepared.manifest.id, "fixture-vault")
        XCTAssertTrue(prepared.verification.isSigned)
        XCTAssertEqual(prepared.files.count, 3)
        XCTAssertTrue(String(data: try XCTUnwrap(prepared.files["documents/manual.txt"]), encoding: .utf8)?.contains("FICTIONAL TEST ONLY") == true)
    }
    #if !SWIFT_PACKAGE
    @MainActor
    func testAppVaultHandoffRetainsVerifiedPublisherProvenance() throws {
        let prepared = try prepare(fixture("manual-vault-v1", extension: "zip"))
        let request = prepared.vaultImportRequest
        XCTAssertEqual(request.files, prepared.files)
        XCTAssertEqual(request.receipt.verification, .signed)
        XCTAssertEqual(request.receipt.publisherId, "fixture-publisher")
        XCTAssertEqual(request.receipt.archiveSHA256, prepared.archiveSHA256)
        XCTAssertEqual(request.receipt.sourceHost, "Avenkin Office")
        XCTAssertFalse(request.receipt.sourceHost.contains("://"))
    }
    #endif
    func testModifiedOrTruncatedArchiveIsRefusedBeforeExtraction() throws {
        var archive = try fixture("manual-vault-v1", extension: "zip")
        archive[archive.count / 2] ^= 1
        XCTAssertThrowsError(try prepare(archive)) { XCTAssertEqual($0 as? OfficeManualImport.Refusal, .archiveDoesNotMatchAssignment) }
        XCTAssertThrowsError(try prepare(archive.dropLast())) { XCTAssertEqual($0 as? OfficeManualImport.Refusal, .archiveDoesNotMatchAssignment) }
    }
    func testUnknownRevokedOrWrongPublisherKeyCannotInstall() throws {
        let archive = try fixture("manual-vault-v1", extension: "zip")
        let wrong = VaultPublisher(id: "fixture-publisher", name: "Fictional Publisher", publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())
        for publishers in [[], [try publisher(status: .revoked)], [wrong]] {
            XCTAssertThrowsError(try prepare(archive, publishers: publishers)) { XCTAssertEqual($0 as? OfficeManualImport.Refusal, .publisherNotVerified) }
        }
    }
    func testOfficeSignatureDoesNotAuthorizeAnUnsignedPublisherArchive() throws {
        let archive = try signedArchive(files: VaultArchiveFixture.vaultFiles(vaultId: "fixture-vault"), signed: false)
        XCTAssertThrowsError(try prepare(archive, assignment: assignment(archive: archive))) {
            XCTAssertEqual($0 as? OfficeManualImport.Refusal, .publisherNotVerified)
        }
    }
    func testWrongVaultVersionOrPublisherIsRefused() throws {
        let archive = try fixture("manual-vault-v1", extension: "zip")
        for field in ["vaultID", "vaultVersion", "publisherID"] {
            let v = try assignment(mutation: { $0[field] = "different" })
            XCTAssertThrowsError(try prepare(archive, assignment: v)) { XCTAssertEqual($0 as? OfficeManualImport.Refusal, .wrongVaultOrPublisher) }
        }
    }
    func testSignedUnsafeManifestCannotEscapeValidatedFiles() throws {
        var files = VaultArchiveFixture.vaultFiles(vaultId: "fixture-vault")
        let unsafe = VaultManifest(id: "fixture-vault", name: "Fictional", version: "1.0.0", files: ["../outside.md"], promptRules: ["Never fabricate.", "Cite files."])
        files["manifest.json"] = try JSONEncoder().encode(unsafe)
        let archive = try signedArchive(files: files)
        XCTAssertThrowsError(try prepare(archive, assignment: assignment(archive: archive))) { XCTAssertEqual($0 as? OfficeManualImport.Refusal, .unsafeManifest) }
    }
    func testMissingDeclaredManualAndInflationLimitAreRefused() throws {
        var files = VaultArchiveFixture.vaultFiles(vaultId: "fixture-vault")
        files.removeValue(forKey: "documents/manual.txt")
        let archive = try signedArchive(files: files)
        XCTAssertThrowsError(try prepare(archive, assignment: assignment(archive: archive))) { XCTAssertEqual($0 as? OfficeManualImport.Refusal, .unsafeManifest) }
        XCTAssertThrowsError(try prepare(fixture("manual-vault-v1", extension: "zip"), maximum: 1)) { XCTAssertEqual($0 as? OfficeManualImport.Refusal, .invalidArchive) }
    }
    func testAssignmentExpiryIsRecheckedAfterTheDownload() throws {
        let verified = try assignment()
        let archive = try fixture("manual-vault-v1", extension: "zip")
        XCTAssertThrowsError(try OfficeManualImport.prepare(assignment: verified, archive: archive,
            publishers: [publisher()], maximumInflatedBytes: 1_048_576,
            receivedAt: Date(timeIntervalSince1970: TimeInterval(verified.payload.expiresAt)))) {
            XCTAssertEqual($0 as? OfficeManualImport.Refusal, .assignmentNotCurrentlyValid)
        }
    }
    func testInflationBudgetIncludesTheHeaderAndSignature() throws {
        let archive = try fixture("manual-vault-v1", extension: "zip")
        let zip = try XCTUnwrap(ZipArchiveReader(data: archive))
        let payloadOnly = zip.entryMetadata.filter {
            $0.name != VaultArchiveHeader.filename && $0.name != VaultArchiveHeader.signatureFilename
        }.reduce(0) { $0 + $1.uncompressedSize }
        XCTAssertThrowsError(try prepare(archive, maximum: payloadOnly)) {
            XCTAssertEqual($0 as? OfficeManualImport.Refusal, .invalidArchive)
        }
    }
    func testExactReplayRequiresCommitLookupRatherThanReimport() throws {
        let accepted = try assignment()
        let replay = try assignment(highWater: accepted.highWater)
        XCTAssertThrowsError(try prepare(fixture("manual-vault-v1", extension: "zip"), assignment: replay)) { XCTAssertEqual($0 as? OfficeManualImport.Refusal, .replayRequiresCommitLookup) }
    }
}
