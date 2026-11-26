import Foundation

/// Plan LR — the manuals an installed vault holds, carried across a change to its core files or to
/// its manual set.
///
/// A vault pack never ships manuals, and installing one lays down a new baseline whose manifest
/// lists none: without this, updating a company vault would drop the manuals the company delivered
/// and the ones the technician added. So a pack update lays the vault's current manuals in beside
/// the new core files (`VaultPackCatalogService.install(_:keepsInstalledManuals:)`), and a manual
/// added, replaced or removed re-lays the installed vault with its manual set changed (`relay`).
/// Both go through `VaultImporter.installReporting`, so validation, the atomic baseline swap and the
/// overlay rules are the importer's own, and `VaultImporter.syncDocuments` then indexes only what
/// changed.
///
/// Files are copied with `FileManager.copyItem`, which clones on APFS: a re-lay of a vault holding
/// a gigabyte of manuals does not write a gigabyte.
enum VaultDocumentCarry {

    /// One manual and where its files are now, by their names inside the documents folder.
    struct Kept: Equatable {
        let document: VaultDocument
        let files: [String: URL]
    }

    enum CarryError: LocalizedError, Equatable {
        case notInstalled(String)
        case missingFile(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: return String(localized: "The vault is not installed on this phone.")
            case .missingFile(let name): return String(localized: "\(name) is missing from the vault on this phone.")
            }
        }
    }

    /// The manuals the installed vault `vaultId` lists, with their files in its baseline. Empty
    /// for a vault that is not installed.
    static func current(vaultId: String) -> [Kept] {
        guard let manifest = VaultImporter.installedManifest(id: vaultId) else { return [] }
        let baseline = VaultImporter.baselineDirectory(for: vaultId)
        return manifest.documents.map { document in
            var files: [String: URL] = [document.file: baseline.appendingPathComponent(manifest.documentRelativePath(document))]
            if let source = document.source, let path = manifest.documentSourceRelativePath(document) {
                files[source] = baseline.appendingPathComponent(path)
            }
            return Kept(document: document, files: files)
        }
    }

    /// The folder new manuals go in for `manifest`: its own, or `documents` for a vault with no
    /// manuals yet, so a manual never lands beside — or on top of — a core file.
    static func documentsFolder(for manifest: VaultManifest) -> String? {
        if let dir = manifest.documentsDir, !dir.isEmpty { return dir }
        return manifest.documents.isEmpty ? "documents" : nil
    }

    /// Lay `documents` into the vault folder at `staging`, replacing any of the same name, and
    /// return `manifest` listing them after the manuals it already lists.
    @MainActor
    static func compose(_ documents: [Kept], into staging: URL, manifest: VaultManifest) throws -> VaultManifest {
        guard !documents.isEmpty else { return manifest }
        let fm = FileManager.default
        let folder = documentsFolder(for: manifest)
        let incoming = Set(documents.map(\.document.file))
        var listed = manifest.documents.filter { !incoming.contains($0.file) }
        for kept in documents {
            for (name, source) in kept.files {
                guard VaultManualRemoval.isContained(name, in: staging), !name.contains("/") else {
                    throw CarryError.missingFile(name)
                }
                guard fm.fileExists(atPath: source.path) else { throw CarryError.missingFile(name) }
                let destination = staging.appendingPathComponent(folder.map { "\($0)/\(name)" } ?? name)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: source, to: destination)
            }
            listed.append(kept.document)
        }
        return manifest.withDocuments(listed, documentsDir: folder)
    }

    /// Re-lay the installed vault `vaultId` with `removing` taken out and `adding` put in (a manual
    /// of the same name is replaced). Its core files, its pack record and the technician's overlay
    /// stay; the caller indexes the result with `VaultImporter.syncDocuments`.
    ///
    /// This validates the whole vault on the calling thread, which is the main thread. The app's
    /// own callers use `relayOffMain`; this one stays for tests that lay a vault out directly.
    @MainActor
    static func relay(vaultId: String, removing: Set<String>, adding: [Kept]) throws -> VaultManifest {
        let laid = try lay(vaultId: vaultId, removing: removing, adding: adding)
        defer { laid.discard() }
        return try finish(laid, report: VaultImporter.installReporting(from: laid.staging))
    }

    /// `relay`, with the vault's validation off the main thread
    /// (`VaultImporter.installReportingOffMain`): adding a long manual to a vault that names its
    /// tables in rule chains scans every page of every manual it holds. The caller holds
    /// `VaultOperationLock` for `vaultId` across the call, so nothing else re-lays the vault while
    /// the validation runs.
    @MainActor
    static func relayOffMain(vaultId: String, removing: Set<String>, adding: [Kept]) async throws -> VaultManifest {
        let laid = try lay(vaultId: vaultId, removing: removing, adding: adding)
        defer { laid.discard() }
        return try finish(laid, report: await VaultImporter.installReportingOffMain(from: laid.staging))
    }

    /// The vault laid out afresh in a staging folder, ready to install.
    struct Laid {
        let vaultId: String
        let staging: URL
        let pack: VaultPackManifest?

        func discard() { try? FileManager.default.removeItem(at: staging) }
    }

    @MainActor
    private static func finish(_ laid: Laid, report: VaultImporter.InstallReport) throws -> VaultManifest {
        // The importer lays the baseline from the manifest's own lists, which never name pack.json.
        if let pack = laid.pack { try VaultImporter.recordPack(pack, for: laid.vaultId) }
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        return report.manifest
    }

    @MainActor
    private static func lay(vaultId: String, removing: Set<String>, adding: [Kept]) throws -> Laid {
        guard let manifest = VaultImporter.installedManifest(id: vaultId) else { throw CarryError.notInstalled(vaultId) }
        let pack = VaultImporter.installedPack(for: vaultId)
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("VaultRelay-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let laid = Laid(vaultId: vaultId, staging: staging, pack: pack)
        do {
            try layOut(manifest: manifest, from: VaultImporter.baselineDirectory(for: vaultId), into: staging,
                       removing: removing, adding: adding)
        } catch {
            laid.discard()
            throw error
        }
        return laid
    }

    @MainActor
    private static func layOut(manifest: VaultManifest, from baseline: URL, into staging: URL,
                               removing: Set<String>, adding: [Kept]) throws {
        let fm = FileManager.default
        try fm.copyItem(at: baseline, to: staging)
        let replaced = Set(adding.map(\.document.file))
        let gone = manifest.documents.filter { removing.contains($0.file) || replaced.contains($0.file) }
        for document in gone {
            for path in [manifest.documentRelativePath(document), manifest.documentSourceRelativePath(document)].compactMap({ $0 })
            where VaultManualRemoval.isContained(path, in: staging) {
                try? fm.removeItem(at: staging.appendingPathComponent(path))
            }
        }
        let remaining = manifest.documents.filter { !removing.contains($0.file) && !replaced.contains($0.file) }
        let composed = try compose(adding, into: staging, manifest: manifest.withDocuments(remaining, documentsDir: manifest.documentsDir))
        try JSONEncoder().encode(composed).write(to: staging.appendingPathComponent("manifest.json"))
    }
}

extension VaultManifest {
    /// This manifest with another manual set, and everything else as it is.
    func withDocuments(_ documents: [VaultDocument], documentsDir: String?) -> VaultManifest {
        VaultManifest(id: id, name: name, version: version, files: files, proceduresDir: proceduresDir,
                      documentsDir: documentsDir, documents: documents, documentsIncluded: true,
                      gating: gating, promptRules: promptRules, sourceAttributionFormat: sourceAttributionFormat,
                      sourceAttributionRequired: sourceAttributionRequired, trades: trades, sites: sites,
                      vaultOnly: vaultOnly, equipmentTypes: equipmentTypes)
    }
}
