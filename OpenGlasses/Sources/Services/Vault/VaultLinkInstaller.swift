import Foundation

/// Plan FS §3 — verified archive bytes → an installed vault, or nothing at all.
///
/// The install itself is the one the folder picker uses: files are laid out as a vault folder and
/// handed to `VaultImporter.installReporting`, which validates first and swaps a staging directory
/// into place atomically. What this adds is the receive half — the per-vault lock, the receipt
/// beside the baseline, and the guarantee that a cancelled or failed install leaves no staging
/// directory and no half-written vault behind.
@MainActor
enum VaultLinkInstaller {

    struct Request: Equatable {
        let files: [String: Data]
        let receipt: VaultReceipt
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
            throw InstallError.failed("The archive's manifest.json is unreadable.")
        }
        return try await VaultOperationLock.withLock(manifest.id) {
            let staging = fm.temporaryDirectory
                .appendingPathComponent("VaultLink-\(UUID().uuidString.prefix(8))", isDirectory: true)
            // Whatever happens next — a validation refusal, a write error, a cancellation — the
            // laid-out copy goes. `installReporting` owns the durable half and swaps atomically.
            defer { try? fm.removeItem(at: staging) }
            do {
                for (path, data) in request.files {
                    guard VaultArchiveReader.isSafeRelativePath(path) else {
                        throw InstallError.failed("The archive contains a file path that would write outside the vault.")
                    }
                    let url = staging.appendingPathComponent(path)
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                }
                let report = try VaultImporter.installReporting(from: staging)
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
