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
            case .invalid(let issues): return String(localized: "Vault failed validation:\n• \(issues.joined(separator: "\n• "))")
            case .ioError(let message): return String(localized: "Install failed: \(message)")
            case .notEntitled: return String(localized: "Importing manuals into a vault needs a Field Assist subscription, or a team licence from your organisation. A one-time unlock covers the bundled vaults only.")
            case .documentFailed(let message): return String(localized: "Manual import failed: \(message)")
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

    /// The reader for tables printed as pictures (Plan JN P1). Vision by default; nil reads tables
    /// from the text layer only, as before. Tests inject a fake or nil.
    nonisolated(unsafe) static var defaultPictureReader: PictureTableReader? = VisionTableReader()

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
    enum InstallOrigin { case folder, personalPDF, receivedSigned }

    static func installReporting(from sourceDir: URL, origin: InstallOrigin = .folder,
                                 reservation: UUID? = nil) throws -> InstallReport {
        let entitlement = FieldAssistEntitlement.shared
        if entitlement.has(.personalManuals) && !entitlement.has(.ownVaults) {
            guard origin != .folder else {
                throw ImportError.documentFailed(String(localized: "Importing a folder or a manifest needs Field Assist. Upload a manual in My Manuals instead."))
            }
        }
        if origin == .personalPDF || origin == .receivedSigned {
            let data = try Data(contentsOf: sourceDir.appendingPathComponent("manifest.json"))
            let manifest = try JSONDecoder().decode(VaultManifest.self, from: data)
            guard origin != .personalPDF || manifest.id == "my-manuals",
                  manifest.files.isEmpty, manifest.proceduresDir == nil, manifest.promptRules.isEmpty,
                  manifest.siteFiles.isEmpty, manifest.trades == nil,
                  !manifest.documents.isEmpty,
                  manifest.isPersonalLibrary else {
                throw ImportError.documentFailed(String(localized: "My Manuals accepts document content only."))
            }
            return try ManualLibraryAdmission.install(manifest: manifest, root: sourceDir, reservation: reservation) {
                try installValidated(from: sourceDir, manualOnly: true)
            }
        }
        let proposed = try JSONDecoder().decode(VaultManifest.self, from: Data(contentsOf: sourceDir.appendingPathComponent("manifest.json")))
        guard !proposed.isPersonalLibrary else { throw ImportError.notEntitled }
        return try installValidated(from: sourceDir)
    }

    private static func installValidated(from sourceDir: URL, manualOnly: Bool = false) throws -> InstallReport {
        let result = VaultValidator.validate(directory: sourceDir, manualOnly: manualOnly)
        guard result.isValid, let validated = result.manifest else {
            throw ImportError.invalid(result.issues)
        }
        // Validation has just confirmed every listed manual is in the folder, so an installed
        // manifest always says its manuals are present — even when the folder came from an export
        // that said they were not and the reader supplied them (Plan FS).
        let manifest = validated.markingDocumentsIncluded()
        if let existing = installedManifest(id: manifest.id), existing.isPersonalLibrary != manifest.isPersonalLibrary {
            throw ImportError.documentFailed(String(localized: "This identifier belongs to the other manual service. Use a different identifier; its manuals were kept."))
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
            // Site documents (Plan HV), validated above with the rest. Baseline content only: no
            // phone editor and no overlay.
            for path in manifest.siteFiles {
                let dest = staging.appendingPathComponent(path)
                guard !fm.fileExists(atPath: dest.path) else { continue }
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: sourceDir.appendingPathComponent(path), to: dest)
            }
            // The checks of the vault's pictured tables (Plan JN P3), at the folder's root whether or
            // not `files` lists them: bounded, and copied as they are — the validator has already
            // said what in them does not read, and the reader skips it again.
            let checksSource = sourceDir.appendingPathComponent(TableChecksFile.fileName)
            let checksDest = staging.appendingPathComponent(TableChecksFile.fileName)
            if !fm.fileExists(atPath: checksDest.path),
               let size = (try? checksSource.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])),
               size.isRegularFile == true, (size.fileSize ?? 0) <= TableChecksFile.maximumBytes {
                try fm.copyItem(at: checksSource, to: checksDest)
            }
            // Receipts are app-written trust records, never author-supplied payload files. Even
            // a folder that lists this reserved path cannot forge a signed Office review handoff.
            let suppliedReceipt = staging.appendingPathComponent(VaultReceipt.filename)
            if fm.fileExists(atPath:suppliedReceipt.path) {try fm.removeItem(at:suppliedReceipt)}
            // Preserve the old baseline until its replacement and registry record both succeed.
            // A failed copy/registry write must not destroy a previously admitted manual set.
            try fm.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
            let manifestData = try JSONEncoder().encode(manifest)
            let backup = baseline.appendingPathExtension("rollback-\(UUID().uuidString)")
            try fm.createDirectory(at: baseline.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !isFirstBaseline { try fm.moveItem(at: baseline, to: backup) }
            var installedReplacement = false
            do {
                try fm.moveItem(at: staging, to: baseline)
                installedReplacement = true
                try manifestData.write(to: registryDirectory.appendingPathComponent("\(manifest.id).json"), options: .atomic)
            } catch {
                let installError = error
                do {
                    if installedReplacement { try fm.removeItem(at: baseline) }
                    if !isFirstBaseline { try fm.moveItem(at: backup, to: baseline) }
                } catch {
                    throw ImportError.ioError(String(localized: "Installation failed and its previous files need recovery from \(backup.lastPathComponent): \(error.localizedDescription)"))
                }
                throw installError
            }
            try? fm.removeItem(at: backup)

            // Migrate legacy installs: clear a pre-existing overlay only on first baseline creation.
            if isFirstBaseline {
                try? fm.removeItem(at: overlay)
            }
            // Checks this phone already wrote into the vault keep their place beside the ones the
            // folder brings, so a check that disagrees shows rather than one hiding the other.
            if let data = try? Data(contentsOf: baseline.appendingPathComponent(TableChecksFile.fileName)) {
                try? VaultTableChecks.mergeImported(TableChecksFile.parse(data).checks, overlay: overlay)
            }

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
                              pictureReader: PictureTableReader? = defaultPictureReader,
                              renderPolicy: ScanRenderPolicy = ScanRenderPolicy(),
                              progress: DocumentProgress? = nil,
                              recognitionProgress: RecognitionProgress? = nil,
                              capturedCatalog:CapturedManualCatalog? = nil) async throws -> VaultDocumentLedger {
        try await VaultOperationLock.withLock(manifest.id) {
            // An interrupted removal is finished before anything is diffed. Skipped when the caller
            // injected its own directories, because then this is not the installed vault's layout
            // and there is no journal of its own to read.
            if baseline == nil, ledgerDirectory == nil {
                VaultManualRemoval.recoverLocked(vaultId: manifest.id, documentStore: store)
            }
            return try await syncDocumentsLocked(
                manifest: manifest, into: store, baseline: baseline, ledgerDirectory: ledgerDirectory,
                scanReader: scanReader, pictureReader: pictureReader, renderPolicy: renderPolicy,
                progress: progress, recognitionProgress: recognitionProgress,capturedCatalog:capturedCatalog ?? .shared)
        }
    }

    @MainActor
    private static func syncDocumentsLocked(manifest: VaultManifest,
                                            into store: DocumentStore,
                                            baseline: URL?,
                                            ledgerDirectory: URL?,
                                            scanReader: ScannedPageReader?,
                                            pictureReader: PictureTableReader?,
                                            renderPolicy: ScanRenderPolicy,
                                            progress: DocumentProgress?,
                                            recognitionProgress: RecognitionProgress?,capturedCatalog:CapturedManualCatalog) async throws -> VaultDocumentLedger {
        // A removal that completed since this call was queued has already reduced the manifest in
        // the registry; re-reading it here is what stops a queued re-index re-ingesting the manual
        // the removal just took out.
        let manifest = (ledgerDirectory == nil && baseline == nil
            ? installedManifests().first { $0.id == manifest.id } : nil) ?? manifest
        let root = baseline ?? baselineDirectory(for: manifest.id)
        let ledgerDir = ledgerDirectory ?? overlayDirectory(for: manifest.id)
        let namespace = DocumentStore.vaultNamespace(manifest.id)
        capturedCatalog.documents = store

        var desired: [VaultDocumentLedger.Desired] = []
        for document in manifest.documents {
            let url = root.appendingPathComponent(manifest.documentRelativePath(document))
            guard let data = try? Data(contentsOf: url) else {
                throw ImportError.documentFailed(String(localized: "\(document.file) is missing from the installed vault"))
            }
            // The original is hashed, not read: it is the thing "unmodified since import" is
            // checked against later, and it never becomes chunks.
            let originalHash = manifest.documentSourceRelativePath(document)
                .flatMap { try? Data(contentsOf: root.appendingPathComponent($0)) }
                .map(VaultDocumentLedger.hash(of:))
            var binding:String?
            if let review = document.capturedManual {
                guard let receipt = receipt(for:manifest.id),receipt.verification == .signed,
                      receipt.capturedOrganizationID == review.organizationID,
                      let sourcePath = manifest.documentSourceRelativePath(document) else {
                    throw ImportError.documentFailed(String(localized: "Photographed-manual approval requires its authenticated Office assignment and signed archive."))
                }
                let pdfURL = root.appendingPathComponent(sourcePath)
                binding = try await Task.detached(priority:.utility) {
                    guard let size = try pdfURL.resourceValues(forKeys:[.fileSizeKey]).fileSize,
                          size <= CapturedManualContract.maximumPDFBytes else {throw CapturedManualStore.Failure.limits}
                    let pdf = try Data(contentsOf:pdfURL)
                    guard try CapturedManualMedia.pageCount(pdf) == review.pageCount else {throw CapturedManualStore.Failure.invalidRequest}
                    return try document.capturedBinding(text:data,pdf:pdf)
                }.value
                guard receipt.capturedDocumentBindings?[document.file] == binding else {
                    throw ImportError.documentFailed(String(localized: "Reviewed manual metadata or source files changed after authentication."))
                }
            }
            desired.append(.init(file: document.file, title: document.capturedManual?.citationName(title:document.title) ?? document.title,
                                 contentHash: VaultDocumentLedger.hash(of: data),
                                 sourceContentHash: originalHash,capturedManual:document.capturedManual,capturedBinding:binding))
        }

        var ledger = VaultDocumentLedger.load(from: ledgerDir)
        let plan = VaultDocumentLedger.plan(current: ledger, desired: desired)
        guard !plan.isNoop else {
            try capturedCatalog.reconcileReviewedVault(manifest.id)
            return ledger
        }
        // The gate sits here rather than at the top: work that only forgets is cleanup, and a
        // vault whose licence lapsed still has to be able to shed manuals it no longer lists.
        let mayIngest = FieldAssistEntitlement.shared.has(manifest.isPersonalLibrary ? .personalManuals : .ownVaults)
        guard plan.toIngest.isEmpty || mayIngest else {
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
            if let review = want.capturedManual {
                let data = try Data(contentsOf:url)
                let id = UUID().uuidString
                let allowed = {
                    FieldAssistEntitlement.shared.has(.ownVaults) && capturedCatalog.accessAllowed()
                        && capturedCatalog.scopeForVault(manifest.id).organizationID == review.organizationID
                }
                guard await store.ingestPages(documentId:id,name:want.title,pages:try review.pageTexts(data),
                    sourceType:recognisedSourceType,namespace:namespace,stillAllowed:allowed),
                    let ref = store.documents.first(where:{$0.id == id}),ref.chunkCount > 0 else {
                    ledger.entries = entries;try? ledger.save(to:ledgerDir)
                    throw ImportError.documentFailed(String(localized: "Reviewed photographed manual did not reach Ready indexing."))
                }
                entries.append(.init(file:want.file,title:want.title,documentId:ref.id,contentHash:want.contentHash,
                    chunkCount:ref.chunkCount,ocrPages:review.ocrPages,lowConfidencePages:review.lowConfidencePages,
                    sourceContentHash:want.sourceContentHash,capturedManual:review,capturedBinding:want.capturedBinding))
                continue
            }
            let extracted: VaultDocumentExtractor.Extracted
            let personalScan = manifest.documents.first { $0.file == want.file }?.personalCapture == true
            let effectiveReader: (any ScannedPageReader)? = personalScan
                ? scanReader.map { PersonalManualPageReader(reader: $0) } : scanReader
            do {
                // Recognised pages are checkpointed under the content hash so an interrupted
                // 300-page scan resumes where it stopped on the next sync.
                let readingDocument = manifest.documents.first { $0.file == want.file }
                let readingURL = readingDocument?.personalReadingCopy == true
                    ? readingDocument.flatMap { manifest.documentSourceRelativePath($0) }.map { root.appendingPathComponent($0) } : nil
                extracted = try await VaultDocumentExtractor.extract(
                    from: readingURL ?? url, reader: effectiveReader, policy: renderPolicy,
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
            // The document's tables (Plan JJ P0), read from its PDF — the document itself, or the
            // original a text import was made from — off the main actor. A page with no text layer
            // has none to read; a vault with no PDF at all has no tables, and the log says so.
            let document = manifest.documents.first { $0.file == want.file }
            let original = document.flatMap { manifest.documentSourceRelativePath($0) }
                .map { root.appendingPathComponent($0) }
            let tablesPDF = VaultDocumentExtractor.tablesSource(document: url, original: original)
            // A table printed as a picture is read too (Plan JN P1), its regions checkpointed under
            // the hash of the PDF they were drawn from, as recognised pages are.
            let tablesHash = tablesPDF == url ? want.contentHash : (want.sourceContentHash ?? want.contentHash)
            let tables: PDFTableReader.Result? = await Task.detached(priority: .utility) {
                guard let tablesPDF else { return nil }
                return await VaultDocumentExtractor.tables(from: tablesPDF, pictures: pictureReader.map {
                    PictureTableReading.context($0, checkpointIn: ledgerDir, contentHash: tablesHash)
                })
            }.value
            // A one-page PDF has no form feed to establish pagination. Its physical page is
            // known, so establish it explicitly instead of returning a citation without a page.
            let indexedText = extracted.pageCount == 1 ? "Page 1\n" + extracted.text : extracted.text
            let ref = await store.ingest(name: want.title, text: indexedText,
                                         sourceType: sourceType, namespace: namespace,
                                         pageLabels: extracted.pageLabels,
                                         tables: tables?.stored ?? []) { done, total in
                progress?(want.title, done, total)
            }
            VaultDocumentExtractor.logTables(tables, rowsDropped: store.lastTableRowsDropped)
            guard let ref else {
                ledger.entries = entries
                try? ledger.save(to: ledgerDir)
                throw ImportError.documentFailed(String(localized: "\(want.file) produced no chunks"))
            }
            // The recognised pages are kept (Plan JY P5a): they are the only copy of those pages'
            // text, and a later re-read of the manual's structure takes them from here rather than
            // recognising the scan again. Removed with the manual (`VaultManualRemoval`).
            if !extracted.usedRecognition { OCRCheckpoint.remove(from: ledgerDir, contentHash: want.contentHash) }
            PictureTableCheckpoint.remove(from: ledgerDir, contentHash: tablesHash)
            entries.append(.init(file: want.file, title: want.title, documentId: ref.id,
                                 contentHash: want.contentHash, chunkCount: ref.chunkCount,
                                 ocrPages: extracted.ocrPages, lowConfidencePages: extracted.lowConfidencePages,
                                 structuredHeadings: extracted.structuredHeadings,
                                 diagramPages: extracted.diagramPages,
                                 sourceContentHash: want.sourceContentHash,
                                 physicalPageCount: extracted.pageCount))
        }
        ledger.entries = entries
        try ledger.save(to: ledgerDir)
        try capturedCatalog.reconcileReviewedVault(manifest.id)
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
    ///
    /// Its team-learning namespace (`learning:<id>`) is forgotten too, at once — a vault that is not
    /// installed answers nothing. The approved entries stay in `LearningEntryStore`; if the vault
    /// comes back, `LearningReviewService.republish()` puts their documents back (Plan FP P3).
    @MainActor
    static func uninstall(id: String, documentStore: DocumentStore) async {
        await VaultOperationLock.withLock(id) {
            for entry in VaultDocumentLedger.load(from: overlayDirectory(for: id)).entries {
                documentStore.forget(documentId: entry.documentId)
            }
            // Backstop: anything in the vault's namespace the ledger lost track of.
            documentStore.clear(namespace: DocumentStore.vaultNamespace(id))
            documentStore.clear(namespace: DocumentStore.learningNamespace(id))
            // The checks this phone made of the vault's tables (Plan JN P3) go with it; those it
            // wrote into the vault's own file go with the overlay below.
            TableCheckStore().removeAll(vaultId: id)
            uninstall(id: id)
        }
    }

    // MARK: - Team learnings in an import folder (Plan FP P3)

    /// The learnings bundle an exported vault folder carries (`learnings/team-learnings.json`), or
    /// nil. Read, never installed: the caller hands it to `LearningBundleIntake`, which stages it
    /// for acceptance entry by entry. Refused unread when it is over the bundle limit.
    static func learningsBundleData(in sourceDir: URL) -> Data? {
        let url = sourceDir.appendingPathComponent(VaultExporter.learningsDirectory, isDirectory: true)
            .appendingPathComponent(VaultExporter.learningsFile)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0, size <= LearningBundle.maximumBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Fully remove an installed user vault: baseline + overlay edits + registry entry. Ingested
    /// documents are left in the store — prefer the overload that takes the store.
    static func uninstall(id: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: baselineDirectory(for: id))
        // Plan LV: a company layer goes with the vault it extends.
        try? fm.removeItem(at: VaultCompanyLayer.directory(baseId: id))
        try? fm.removeItem(at: overlayDirectory(for: id))
        try? fm.removeItem(at: registryDirectory.appendingPathComponent("\(id).json"))
    }

    /// One user-installed manifest by id, or nil. Reads the one registry file rather than all of
    /// them; an id that is not a plain file name is never turned into a path.
    static func installedManifest(id: String) -> VaultManifest? {
        guard !id.isEmpty, id.count <= 128, !id.hasPrefix("."),
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0) })
        else { return nil }
        let url = registryDirectory.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VaultManifest.self, from: data)
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
