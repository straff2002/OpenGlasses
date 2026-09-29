import Foundation

/// A transport-neutral preflight, run off the UI thread after a guarded download. Transport
/// authentication never substitutes for either the office assignment or publisher signature.
/// This returns an import request, not an installed/indexed or business-accepted receipt.
enum OfficeManualImport {
    struct Prepared {
        let assignment: OfficeManualAssignment.Verified
        let files: [String: Data]
        let verification: VaultArchiveVerification
        let archiveSHA256: String
        let receivedAt: Date
        let manifest: VaultManifest
        fileprivate init(assignment: OfficeManualAssignment.Verified, files: [String: Data],
                         verification: VaultArchiveVerification, archiveSHA256: String,
                         receivedAt: Date, manifest: VaultManifest) {
            self.assignment = assignment
            self.files = files
            self.verification = verification
            self.archiveSHA256 = archiveSHA256
            self.receivedAt = receivedAt
            self.manifest = manifest
        }
    }

    enum Refusal: Error, Equatable {
        case replayRequiresCommitLookup
        case assignmentNotCurrentlyValid
        case archiveDoesNotMatchAssignment
        case invalidArchive
        case wrongVaultOrPublisher
        case publisherNotVerified
        case unsafeManifest
    }

    static func prepare(assignment: OfficeManualAssignment.Verified, archive: Data,
                        publishers: [VaultPublisher], maximumInflatedBytes: Int,
                        receivedAt: Date) throws -> Prepared {
        // Exact replays must consult the durable installation record rather than re-importing
        // (which could otherwise restore a manual that the technician deliberately removed).
        guard !assignment.isReplay else { throw Refusal.replayRequiresCommitLookup }
        let p = assignment.payload
        let receivedSeconds = receivedAt.timeIntervalSince1970
        guard receivedSeconds.isFinite, receivedSeconds >= Double(p.issuedAt),
              receivedSeconds < Double(p.expiresAt) else { throw Refusal.assignmentNotCurrentlyValid }
        guard Int64(archive.count) == p.archiveBytes,
              VaultArchiveReader.sha256Hex(archive) == p.archiveSHA256 else {
            throw Refusal.archiveDoesNotMatchAssignment
        }
        // Count the entire ZIP budget, including header/signature and ignored entries, before
        // decoding the header. The legacy reader's payload budget alone excludes those bytes.
        guard maximumInflatedBytes > 0, let zip = ZipArchiveReader(data: archive),
              zip.entryMetadata.count <= VaultArchiveReader.maxEntryCount else { throw Refusal.invalidArchive }
        var inflated = 0
        for entry in zip.entryMetadata {
            let (next, overflow) = inflated.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, next <= maximumInflatedBytes else { throw Refusal.invalidArchive }
            inflated = next
        }
        guard case .success(let extracted) = VaultArchiveReader.extract(
                zipData: archive, maximumTotalBytes: maximumInflatedBytes),
              extracted.header.formatVersion == 1,
              extracted.header.totalBytes == extracted.files.values.reduce(0, { $0 + $1.count }),
              let data = extracted.files["manifest.json"],
              let manifest = try? JSONDecoder().decode(VaultManifest.self, from: data) else {
            throw Refusal.invalidArchive
        }
        guard extracted.header.vaultId == p.vaultID, manifest.id == p.vaultID,
              extracted.header.vaultVersion == p.vaultVersion, manifest.version == p.vaultVersion,
              extracted.header.publisherId == p.publisherID else { throw Refusal.wrongVaultOrPublisher }
        let verification = VaultArchiveVerifier.verify(extracted, publishers: publishers)
        guard verification.isSigned else { throw Refusal.publisherNotVerified }
        // Signed authors still cannot cause an importer to follow a manifest path outside the
        // validated file map. Config/procedure files and document originals are all included.
        let requiredFiles = manifest.files + manifest.documents.flatMap { document in
                [manifest.documentRelativePath(document), manifest.documentSourceRelativePath(document)].compactMap { $0 }
            }
        let paths = requiredFiles + [manifest.proceduresDir, manifest.documentsDir].compactMap { $0 }
        guard paths.allSatisfy(VaultArchiveReader.isSafeRelativePath),
              requiredFiles.allSatisfy({ extracted.files[$0] != nil }), manifest.documentsIncluded else {
            throw Refusal.unsafeManifest
        }
        return Prepared(assignment: assignment, files: extracted.files,
                        verification: verification, archiveSHA256: p.archiveSHA256,
                        receivedAt: receivedAt, manifest: manifest)
    }
}
