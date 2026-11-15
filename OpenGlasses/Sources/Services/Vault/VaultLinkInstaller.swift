import Foundation

/// Plan FS §3 — verified archive bytes → an installed vault, or nothing at all.
///
/// The install itself is the one the folder picker uses: files are laid out as a vault folder and
/// handed to `VaultImporter.installReporting`, which validates first and swaps a staging directory
/// into place atomically. What this adds is the receive half — the per-vault lock, the receipt
/// beside the baseline, and the guarantee that a cancelled or failed install leaves no staging
/// directory and no half-written vault behind.
/// VaultLinkStagingStore owns downloaded archive bytes; this adapter also cleans its unpacked
/// temporary files on return, before handing durable ownership to the installed vault.
@MainActor
enum VaultLinkInstaller {

    struct Request: Equatable {
        let files: [String: Data]
        let receipt: VaultReceipt
        var personalLibrary: Bool = false
    }

    struct Outcome: Equatable {
        let vaultId: String
        let vaultName: String
        let warnings: [String]
        let needsDocumentSync: Bool
        let manifest: VaultManifest
    }

    enum InstallError: LocalizedError {
        case notEntitled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notEntitled:
                return FieldAssistPaywallCopy.ownVaultsLocked
            case .failed(let message):
                return message
            }
        }
    }

    /// Exact downloaded-review checks; installation repeats admission against current holdings.
    nonisolated static func personalPreflight(files: [String: Data]) throws {
        guard let bytes = files["manifest.json"] else { throw InstallError.failed(String(localized: "The manual list is unavailable.")) }
        let manifest = try JSONDecoder().decode(VaultManifest.self, from: bytes).personalProjection
        guard !manifest.documents.isEmpty else { throw InstallError.failed(String(localized: "This publisher set contains no manuals.")) }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ManualSetReview-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        defer { try? fm.removeItem(at: root) }
        for document in manifest.documents {
            let path = manifest.documentSourceRelativePath(document) ?? manifest.documentRelativePath(document)
            guard VaultArchiveReader.isSafeRelativePath(path), let data = files[path] else { throw InstallError.failed(String(localized: "This set is missing an original PDF.")) }
            var writes = [(path, data)]
            // The allowance fingerprints the original, which is the measured PDF unless a reading copy stands in.
            let original = ManualLibraryAdmission.originalRelativePath(manifest, document)
            if original != path {
                guard VaultArchiveReader.isSafeRelativePath(original), let bytes = files[original] else { throw InstallError.failed(String(localized: "This set is missing an original manual.")) }
                writes.append((original, bytes))
            }
            for (relative, bytes) in writes {
                let url = root.appendingPathComponent(relative)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        // A review: the same quota and new-manual allowance as the install, spending nothing.
        try ManualLibraryAdmission.install(manifest: manifest, root: root, recordsAdditions: false) { () }
    }

    /// Lay the archive out and install it, serialised against every other operation on that vault.
    ///
    /// The same id already installed goes down the path an explicit import always has: the import
    /// is authoritative, the baseline is replaced, and the reader's overlay edits to the core files
    /// survive because the overlay is not touched. A manual a removal took out (Plan FN) comes back
    /// if the new archive carries it, for the same reason a re-imported folder puts it back — no
    /// record of a removal is kept, and the newer import is the answer.
    static func install(_ request: Request) async throws -> Outcome {
        let fm = FileManager.default
        guard let manifestData = request.files["manifest.json"],
              let manifest = try? JSONDecoder().decode(VaultManifest.self, from: manifestData) else {
            throw InstallError.failed(String(localized: "The archive's manifest.json is unreadable."))
        }
        let targetID = request.personalLibrary ? manifest.personalProjection.id : manifest.id
        return try await VaultOperationLock.withLock(targetID) {
            let staging = fm.temporaryDirectory
                .appendingPathComponent("VaultLink-\(UUID().uuidString.prefix(8))", isDirectory: true)
            // Whatever happens next — a validation refusal, a write error, a cancellation — the
            // laid-out copy goes. `installReporting` owns the durable half and swaps atomically.
            defer { try? fm.removeItem(at: staging) }
            do {
                for (path, data) in request.files {
                    guard VaultArchiveReader.isSafeRelativePath(path) else {
                        throw InstallError.failed(String(localized: "The archive contains a file path that would write outside the vault."))
                    }
                    let url = staging.appendingPathComponent(path)
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                }
                let personal = request.personalLibrary
                if personal {
                    guard request.receipt.verification == .signed else {
                        throw InstallError.failed(String(localized: "Unverified archives need Field Assist. My Manuals accepts sets signed by a listed publisher."))
                    }
                    // Receipt continues to identify the verified ORIGINAL archive. This is a
                    // document-only projection, not a claim that rewritten bytes were signed.
                    let projected = manifest.personalProjection
                    try JSONEncoder().encode(projected).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
                }
                let report = try VaultImporter.installReporting(from: staging, origin: personal ? .receivedSigned : .folder)
                try VaultImporter.recordReceipt(request.receipt, for: report.manifest.id)
                VaultRegistry.shared.reloadUserManifests()
                VaultRegistry.shared.resetCache()
                return Outcome(vaultId: report.manifest.id, vaultName: report.manifest.name,
                               warnings: report.warnings,
                               needsDocumentSync: VaultImporter.needsDocumentSync(manifest: report.manifest),
                               manifest: report.manifest)
            } catch let error as InstallError {
                throw error
            } catch {
                throw InstallError.failed(error.localizedDescription)
            }
        }
    }
}
