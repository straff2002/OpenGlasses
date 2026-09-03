import Foundation

/// Installs a customer-supplied vault (Plan H) as a **read-only baseline** so it loads through the
/// normal `VaultStore`/`VaultRegistry` path. Validates first via `VaultValidator`; only a clean pack
/// is installed. Source is a directory (already-unzipped) containing manifest.json + markdown +
/// optional procedures/.
///
/// An admin's pushed content lands in `Documents/Vaults/_baselines/{id}/` and is never mutated by
/// in-app editing — technician edits go to the `Documents/Vaults/{id}/` overlay, which `VaultStore`
/// merges *over* the baseline. So an admin can re-push a new vault version (updating the baseline)
/// without clobbering technician overlay edits.
enum VaultImporter {

    enum ImportError: LocalizedError {
        case invalid([String])
        case ioError(String)
        case notEntitled
        case documentFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let issues): return "Vault failed validation:\n• " + issues.joined(separator: "\n• ")
            case .ioError(let message): return "Install failed: \(message)"
            case .notEntitled: return "Importing manuals into a vault needs a Field Assist licence."
            case .documentFailed(let message): return "Manual import failed: \(message)"
            }
        }
    }

    /// What an install produced: the manifest plus any advisory warnings from validation.
    struct InstallReport {
        let manifest: VaultManifest
        let warnings: [String]
    }

    /// Progress of a document sync: (document title, completed chunks, total chunks).
    typealias DocumentProgress = (_ title: String, _ completed: Int, _ total: Int) -> Void

    /// `Documents/Vaults/_registry/` — where user vault manifests live for registry discovery.
    static var registryDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Vaults/_registry", isDirectory: true)
    }

    /// Overlay directory for a vault id (`Documents/Vaults/{id}/`) — where technician edits live.
    static func overlayDirectory(for id: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Vaults/\(id)", isDirectory: true)
    }

    /// Read-only baseline directory for an imported vault (`Documents/Vaults/_baselines/{id}/`) —
    /// where the admin's pushed content lives. `VaultStore` treats this as its baseline root and
    /// merges the overlay over it.
    static func baselineDirectory(for id: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Vaults/_baselines/\(id)", isDirectory: true)
    }

    /// Validate and install. Returns the installed manifest on success; throws with the issues otherwise.
    /// Reference documents are copied here; chunking them into the document store is a separate,
    /// async step — `syncDocuments(manifest:into:progress:)` — because ingest yields between chunks.
    @discardableResult
    static func install(from sourceDir: URL) throws -> VaultManifest {
        try installReporting(from: sourceDir).manifest
    }

    /// `install(from:)` plus the validator's advisory warnings (core over budget, and so on).
    static func installReporting(from sourceDir: URL) throws -> InstallReport {
        let result = VaultValidator.validate(directory: sourceDir)
        guard result.isValid, let manifest = result.manifest else {
            throw ImportError.invalid(result.issues)
        }

        let fm = FileManager.default
        let baseline = baselineDirectory(for: manifest.id)
        let overlay = overlayDirectory(for: manifest.id)
        // Whether this is the first time we're laying down a baseline for this id. Under the
        // baseline model a technician's overlay only ever holds genuine edits *after* a baseline
        // exists, so a pre-existing overlay here is legacy full-content from the old importer and
        // must be cleared so the new baseline is visible. Re-pushes (baseline already present)
        // never reach that branch, preserving overlay edits.
        let isFirstBaseline = !fm.fileExists(atPath: baseline.path)

        // Install into a temp dir first, then atomically swap — so a half-copy never goes live.
        let staging = baseline.appendingPathExtension("staging-\(UUID().uuidString.prefix(8))")
        do {
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            // Copy listed markdown files.
            for file in manifest.files {
                try fm.copyItem(at: sourceDir.appendingPathComponent(file), to: staging.appendingPathComponent(file))
            }
            // Copy procedures dir if present.
            if let dir = manifest.proceduresDir {
                let src = sourceDir.appendingPathComponent(dir, isDirectory: true)
                if fm.fileExists(atPath: src.path) {
                    try fm.copyItem(at: src, to: staging.appendingPathComponent(dir, isDirectory: true))
                }
            }
            // Copy the reference documents the manifest lists (validated present above).
            for document in manifest.documents {
                let relative = manifest.documentRelativePath(document)
                let dest = staging.appendingPathComponent(relative)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: sourceDir.appendingPathComponent(relative), to: dest)
            }
            // Swap staging → baseline (the read-only authoritative copy).
            try? fm.removeItem(at: baseline)
            try fm.createDirectory(at: baseline.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: staging, to: baseline)

            // Migrate legacy installs: clear a pre-existing overlay only on first baseline creation.
            if isFirstBaseline {
                try? fm.removeItem(at: overlay)
            }

            // Record the manifest for registry discovery.
            try fm.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(to: registryDirectory.appendingPathComponent("\(manifest.id).json"), options: .atomic)
        } catch let error as ImportError {
            try? fm.removeItem(at: staging)
            throw error
        } catch {
            try? fm.removeItem(at: staging)
            throw ImportError.ioError(error.localizedDescription)
        }
        return InstallReport(manifest: manifest, warnings: result.warnings)
    }

    // MARK: - Reference documents

    /// Bring the document store in line with the installed baseline's `documents`: forget what
    /// the manifest dropped or replaced, ingest what is new or changed, leave the rest alone.
    /// Idempotent — a second call with nothing changed does no work. Returns the updated ledger.
    ///
    /// Gated on the Field Assist entitlement: manuals are a paid capability, and the gate belongs
    /// at the boundary where the store is written, not only where a session starts.
    @MainActor
    @discardableResult
    static func syncDocuments(manifest: VaultManifest,
                              into store: DocumentStore,
                              baseline: URL? = nil,
                              ledgerDirectory: URL? = nil,
                              progress: DocumentProgress? = nil) async throws -> VaultDocumentLedger {
        guard FieldAssistEntitlement.shared.isGranted else { throw ImportError.notEntitled }
        let root = baseline ?? baselineDirectory(for: manifest.id)
        let ledgerDir = ledgerDirectory ?? overlayDirectory(for: manifest.id)
        let namespace = DocumentStore.vaultNamespace(manifest.id)

        var desired: [VaultDocumentLedger.Desired] = []
        for document in manifest.documents {
            let url = root.appendingPathComponent(manifest.documentRelativePath(document))
            guard let data = try? Data(contentsOf: url) else {
                throw ImportError.documentFailed("\(document.file) is missing from the installed vault")
            }
            desired.append(.init(file: document.file, title: document.title, contentHash: VaultDocumentLedger.hash(of: data)))
        }

        var ledger = VaultDocumentLedger.load(from: ledgerDir)
        let plan = VaultDocumentLedger.plan(current: ledger, desired: desired)
        guard !plan.isNoop else { return ledger }

        for entry in plan.toForget {
            store.forget(documentId: entry.documentId)
        }
        var entries = plan.unchanged
        for want in plan.toIngest {
            let url = root.appendingPathComponent(manifest.documentRelativePath(
                manifest.documents.first { $0.file == want.file } ?? VaultDocument(file: want.file, title: want.title)))
            let extracted: VaultDocumentExtractor.Extracted
            do {
                extracted = try VaultDocumentExtractor.extract(from: url)
            } catch {
                // Persist what succeeded so a partial sync is not repeated from scratch.
                ledger.entries = entries
                try? ledger.save(to: ledgerDir)
                throw ImportError.documentFailed(error.localizedDescription)
            }
            let ref = await store.ingest(name: want.title, text: extracted.text,
                                         sourceType: "vault_document", namespace: namespace) { done, total in
                progress?(want.title, done, total)
            }
            guard let ref else {
                ledger.entries = entries
                try? ledger.save(to: ledgerDir)
                throw ImportError.documentFailed("\(want.file) produced no chunks")
            }
            entries.append(.init(file: want.file, title: want.title, documentId: ref.id,
                                 contentHash: want.contentHash, chunkCount: ref.chunkCount))
        }
        ledger.entries = entries
        try ledger.save(to: ledgerDir)
        return ledger
    }

    /// The ledger for an installed vault (empty when it has never synced documents).
    static func documentLedger(for id: String) -> VaultDocumentLedger {
        VaultDocumentLedger.load(from: overlayDirectory(for: id))
    }

    /// Fully remove an installed user vault: baseline + overlay edits + registry entry, and every
    /// reference document it ingested into `documentStore`.
    @MainActor
    static func uninstall(id: String, documentStore: DocumentStore) {
        for entry in VaultDocumentLedger.load(from: overlayDirectory(for: id)).entries {
            documentStore.forget(documentId: entry.documentId)
        }
        // Backstop: anything in the vault's namespace the ledger lost track of.
        documentStore.clear(namespace: DocumentStore.vaultNamespace(id))
        uninstall(id: id)
    }

    /// Fully remove an installed user vault: baseline + overlay edits + registry entry. Ingested
    /// documents are left in the store — prefer the overload that takes the store.
    static func uninstall(id: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: baselineDirectory(for: id))
        try? fm.removeItem(at: overlayDirectory(for: id))
        try? fm.removeItem(at: registryDirectory.appendingPathComponent("\(id).json"))
    }

    /// Load all user-installed manifests from the registry directory.
    static func installedManifests() -> [VaultManifest] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: registryDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? decoder.decode(VaultManifest.self, from: $0) }
        }
    }
}
