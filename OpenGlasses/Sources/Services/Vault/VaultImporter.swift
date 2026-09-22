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
///
/// **One operation does write to the baseline: removing a single manual** ([[VaultManualRemoval]],
/// Plan FN). That is deliberate and is not editing — it is installation management, the same kind of
/// act as uninstalling the vault, and it is why the rule above is about *editing*. It deletes the
/// installed copy of one document and reduces the installed manifest; it never touches the reader's
/// original import folder, a signed pack, or the core-file overlay. A later import containing that
/// manual is authoritative and puts it back, because no record of the removal is kept.
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
            case .notEntitled: return "Importing manuals into a vault needs a Field Assist subscription, or a team licence from your organisation. A one-time unlock covers the bundled vaults only."
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
    /// Progress of recognising a scanned document's pages: (document title, pages done, pages to do).
    typealias RecognitionProgress = (_ title: String, _ pagesDone: Int, _ pagesToDo: Int) -> Void

    /// Source type recorded in the document store for a document any page of which was read by
    /// recognition. Retrieval reads it back to mark those passages' provenance.
    static let recognisedSourceType = "vault_document_ocr"

    /// The reader used for pages without a text layer. Vision by default; nil disables recognition
    /// (a scan then fails import the way it did before scanned import existed). Tests inject a fake.
    nonisolated(unsafe) static var defaultScanReader: ScannedPageReader? = VisionScannedPageReader()

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
        guard result.isValid, let validated = result.manifest else {
            throw ImportError.invalid(result.issues)
        }
        // Validation has just confirmed every listed manual is in the folder, so an installed
        // manifest always says its manuals are present — even when the folder came from an export
        // that said they were not and the reader supplied them (Plan FS).
        let manifest = validated.markingDocumentsIncluded()

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
            // Copy the reference documents the manifest lists (validated present above), and the
            // manufacturer's original beside any that names one — never indexed, but the page a
            // technician following an SOP has to be able to see (Plan EK P3).
            for document in manifest.documents {
                for relative in [manifest.documentRelativePath(document),
                                 manifest.documentSourceRelativePath(document)].compactMap({ $0 }) {
                    let dest = staging.appendingPathComponent(relative)
                    // Two documents may name the same original — one manufacturer's PDF behind an
                    // installation and a service extract is an ordinary shape — and copying it a
                    // second time failed the whole install on "an item with the same name already
                    // exists". The same path is the same file, so the first copy is the answer.
                    guard !fm.fileExists(atPath: dest.path) else { continue }
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: sourceDir.appendingPathComponent(relative), to: dest)
                }
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
    /// Gated on the `ownVaults` capability: *ingesting* manuals is a paid capability, and the gate
    /// belongs at the boundary where the store is written, not only where a session starts. A sync
    /// with nothing to ingest is cleanup — forgetting manuals the manifest dropped — and is not
    /// gated: a lapsed licence must not be able to leave indexed passages behind that the vault no
    /// longer lists and the reader can no longer get rid of.
    ///
    /// Serialised per vault against import, individual manual removal and uninstall, and finishes
    /// any interrupted removal before diffing (Plan FN §1).
    @MainActor
    @discardableResult
    static func syncDocuments(manifest: VaultManifest,
                              into store: DocumentStore,
                              baseline: URL? = nil,
                              ledgerDirectory: URL? = nil,
                              scanReader: ScannedPageReader? = defaultScanReader,
                              renderPolicy: ScanRenderPolicy = ScanRenderPolicy(),
                              progress: DocumentProgress? = nil,
                              recognitionProgress: RecognitionProgress? = nil) async throws -> VaultDocumentLedger {
        try await VaultOperationLock.withLock(manifest.id) {
            // An interrupted removal is finished before anything is diffed. Skipped when the caller
            // injected its own directories, because then this is not the installed vault's layout
            // and there is no journal of its own to read.
            if baseline == nil, ledgerDirectory == nil {
                VaultManualRemoval.recoverLocked(vaultId: manifest.id, documentStore: store)
            }
            return try await syncDocumentsLocked(
                manifest: manifest, into: store, baseline: baseline, ledgerDirectory: ledgerDirectory,
                scanReader: scanReader, renderPolicy: renderPolicy,
                progress: progress, recognitionProgress: recognitionProgress)
        }
    }

    @MainActor
    private static func syncDocumentsLocked(manifest: VaultManifest,
                                            into store: DocumentStore,
                                            baseline: URL?,
                                            ledgerDirectory: URL?,
                                            scanReader: ScannedPageReader?,
                                            renderPolicy: ScanRenderPolicy,
                                            progress: DocumentProgress?,
                                            recognitionProgress: RecognitionProgress?) async throws -> VaultDocumentLedger {
        // A removal that completed since this call was queued has already reduced the manifest in
        // the registry; re-reading it here is what stops a queued re-index re-ingesting the manual
        // the removal just took out.
        let manifest = (ledgerDirectory == nil && baseline == nil
            ? installedManifests().first { $0.id == manifest.id } : nil) ?? manifest
        let root = baseline ?? baselineDirectory(for: manifest.id)
        let ledgerDir = ledgerDirectory ?? overlayDirectory(for: manifest.id)
        let namespace = DocumentStore.vaultNamespace(manifest.id)

        var desired: [VaultDocumentLedger.Desired] = []
        for document in manifest.documents {
            let url = root.appendingPathComponent(manifest.documentRelativePath(document))
            guard let data = try? Data(contentsOf: url) else {
                throw ImportError.documentFailed("\(document.file) is missing from the installed vault")
            }
            // The original is hashed, not read: it is the thing "unmodified since import" is
            // checked against later, and it never becomes chunks.
            let originalHash = manifest.documentSourceRelativePath(document)
                .flatMap { try? Data(contentsOf: root.appendingPathComponent($0)) }
                .map(VaultDocumentLedger.hash(of:))
            desired.append(.init(file: document.file, title: document.title,
                                 contentHash: VaultDocumentLedger.hash(of: data),
                                 sourceContentHash: originalHash))
        }

        var ledger = VaultDocumentLedger.load(from: ledgerDir)
        let plan = VaultDocumentLedger.plan(current: ledger, desired: desired)
        guard !plan.isNoop else { return ledger }
        // The gate sits here rather than at the top: work that only forgets is cleanup, and a
        // vault whose licence lapsed still has to be able to shed manuals it no longer lists.
        guard plan.toIngest.isEmpty || FieldAssistEntitlement.shared.has(.ownVaults) else {
            throw ImportError.notEntitled
        }

        for entry in plan.toForget {
            // Checked and namespace-scoped: a forget that SQLite refused used to pass silently and
            // leave retrievable chunks behind a ledger that said they were gone.
            do {
                try store.forget(documentId: entry.documentId, inNamespace: namespace)
            } catch {
                throw ImportError.documentFailed(error.localizedDescription)
            }
        }
        var entries = plan.unchanged
        for want in plan.toIngest {
            let url = root.appendingPathComponent(manifest.documentRelativePath(
                manifest.documents.first { $0.file == want.file } ?? VaultDocument(file: want.file, title: want.title)))
            let extracted: VaultDocumentExtractor.Extracted
            do {
                // Recognised pages are checkpointed under the content hash so an interrupted
                // 300-page scan resumes where it stopped on the next sync.
                extracted = try await VaultDocumentExtractor.extract(
                    from: url, reader: scanReader, policy: renderPolicy,
                    checkpoint: (
                        load: { OCRCheckpoint.load(from: ledgerDir, contentHash: want.contentHash) },
                        save: { try $0.save(to: ledgerDir) }
                    ),
                    progress: { done, total in recognitionProgress?(want.title, done, total) })
            } catch {
                // Persist what succeeded so a partial sync is not repeated from scratch.
                ledger.entries = entries
                try? ledger.save(to: ledgerDir)
                throw ImportError.documentFailed(error.localizedDescription)
            }
            let sourceType = extracted.usedRecognition ? recognisedSourceType : "vault_document"
            let ref = await store.ingest(name: want.title, text: extracted.text,
                                         sourceType: sourceType, namespace: namespace) { done, total in
                progress?(want.title, done, total)
            }
            guard let ref else {
                ledger.entries = entries
                try? ledger.save(to: ledgerDir)
                throw ImportError.documentFailed("\(want.file) produced no chunks")
            }
            OCRCheckpoint.remove(from: ledgerDir, contentHash: want.contentHash)
            entries.append(.init(file: want.file, title: want.title, documentId: ref.id,
                                 contentHash: want.contentHash, chunkCount: ref.chunkCount,
                                 ocrPages: extracted.ocrPages, lowConfidencePages: extracted.lowConfidencePages,
                                 structuredHeadings: extracted.structuredHeadings,
                                 diagramPages: extracted.diagramPages,
                                 sourceContentHash: want.sourceContentHash))
        }
        ledger.entries = entries
        try ledger.save(to: ledgerDir)
        return ledger
    }

    // MARK: - Packs (Plan EG)

    /// Record the pack a vault was installed from, beside its baseline, so the registry can
    /// resolve the pack's licence key and the Packs list can tell an update from a reinstall.
    ///
    /// Where a *received* vault goes (Plan FS PR2): the same shape — a sidecar written beside the
    /// baseline naming the publisher and whether the archive's signature verified — read back by
    /// the same `installedPack(for:)` pattern, so a badge ("Unverified source") and the job record
    /// can say where a vault came from without another registry. Nothing is written for it yet;
    /// adding the sidecar is additive and leaves every already-installed vault reading as it does
    /// now, which is what makes it safe to leave until the receive path exists to write it.
    static func recordPack(_ pack: VaultPackManifest, for id: String) throws {
        let url = baselineDirectory(for: id).appendingPathComponent(VaultPackManifest.filename)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(pack).write(to: url, options: .atomic)
    }

    // MARK: - Received vaults (Plan FS PR2)

    /// Record where a vault received from a link came from, beside its baseline and in the same
    /// shape as the pack sidecar: the publisher when a signature verified, whether it verified at
    /// all, and the **host** — never the link, which may carry a purchase token.
    ///
    /// Written after `installReporting` has swapped the baseline into place, so a vault is never
    /// badged as received before it exists, and a failed install leaves no receipt behind.
    static func recordReceipt(_ receipt: VaultReceipt, for id: String) throws {
        let url = baselineDirectory(for: id).appendingPathComponent(VaultReceipt.filename)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipt).write(to: url, options: .atomic)
    }

    /// The receipt for a received vault, or nil for every other kind — a hand-imported folder, a
    /// bundled vault, a signed pack.
    static func receipt(for id: String) -> VaultReceipt? {
        let url = baselineDirectory(for: id).appendingPathComponent(VaultReceipt.filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VaultReceipt.self, from: data)
    }

    /// The pack an installed vault came from, or nil for a customer folder or a bundled vault.
    static func installedPack(for id: String) -> VaultPackManifest? {
        let url = baselineDirectory(for: id).appendingPathComponent(VaultPackManifest.filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VaultPackManifest.self, from: data)
    }

    /// The ledger for an installed vault (empty when it has never synced documents).
    static func documentLedger(for id: String) -> VaultDocumentLedger {
        VaultDocumentLedger.load(from: overlayDirectory(for: id))
    }

    /// Whether an install needs a document sync at all.
    ///
    /// Not the same question as `manifest.hasDocuments`, and that difference was a bug: a manifest
    /// re-imported with its manuals taken out listed nothing to ingest, so the import skipped the
    /// sync entirely and the previously indexed passages stayed retrievable for a vault that no
    /// longer claimed them. A sync is needed whenever the manifest lists manuals *or* the ledger
    /// still holds entries — the second case is cleanup-only, and runs without the ingest gate.
    static func needsDocumentSync(manifest: VaultManifest) -> Bool {
        manifest.hasDocuments || !documentLedger(for: manifest.id).entries.isEmpty
    }

    /// Fully remove an installed user vault: baseline + overlay edits + registry entry, and every
    /// reference document it ingested into `documentStore`. Serialised against import, re-index and
    /// individual manual removal for the same vault.
    @MainActor
    static func uninstall(id: String, documentStore: DocumentStore) async {
        await VaultOperationLock.withLock(id) {
            for entry in VaultDocumentLedger.load(from: overlayDirectory(for: id)).entries {
                documentStore.forget(documentId: entry.documentId)
            }
            // Backstop: anything in the vault's namespace the ledger lost track of.
            documentStore.clear(namespace: DocumentStore.vaultNamespace(id))
            uninstall(id: id)
        }
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
