import Foundation

/// Removing one manual from an installed vault, without re-importing the vault or deleting it.
///
/// A vault manual is four things at once: a row in the installed manifest, an entry in
/// [[VaultDocumentLedger]], a document and its chunks in `DocumentStore`, and one or two files in
/// the vault's read-only baseline. Removing it means all four go, and the promise the UI makes —
/// "new retrievals cannot return this manual, including after a restart or a re-index" — is only
/// true if that is *all four or none*. Erasing any one of them alone leaves a state the next sync
/// resurrects the others from.
///
/// Since no single write can cover a SQLite delete, three file writes and a manifest, the honest
/// mechanism is a small forward-only journal rather than a transaction: the target is recorded as
/// *pending* before anything durable changes, everything that reads the vault treats a pending
/// target as already gone, cleanup is idempotent so a retry finishes rather than fails, and the
/// record is cleared only once every step has succeeded. An interrupted removal therefore leaves a
/// manual that is unreachable and will be finished on the next attempt — never one that has half
/// disappeared and still answers questions.
///
/// Scope is deliberately this operation. Vault persistence is not redesigned here; the journal
/// knows about manual removal and nothing else.
@MainActor
enum VaultManualRemoval {

    // MARK: - Errors

    enum RemovalError: LocalizedError, Equatable {
        /// No user-installed vault with this id. Bundled vaults are not user-installed.
        case notInstalled(String)
        /// A signed pack's content belongs to its vendor; removing a manual from it would make the
        /// installed vault disagree with the pack it claims to be.
        case protectedPack(String)
        /// The manifest lists no document with this file name — including a manual whose removal
        /// already finished, because nothing of it is left to address and no tombstone is kept
        /// (an explicit later import is authoritative, so an exclusion list would be a lie).
        /// An *unfinished* removal is a different case and completes rather than throwing this.
        case unknownDocument(file: String, vaultId: String)
        /// The file name resolves outside the vault's own directory.
        case invalidPath(String)
        /// Ownership cannot be established: the ledger is unreadable, or the index holds documents
        /// for this vault that no ledger entry accounts for. Guessing identity from the displayed
        /// title is exactly what must not happen here, so this asks for a repair instead.
        case repairRequired(String)
        /// Cleanup failed part-way. The target stays unavailable and the operation can be retried.
        case cleanupFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let id):
                return "No installed vault with id \(id)."
            case .protectedPack(let name):
                return "“\(name)” is a signed pack. Manuals can only be removed from vaults you imported yourself."
            case .unknownDocument(let file, _):
                return "This vault lists no manual called \(file)."
            case .invalidPath(let file):
                return "\(file) is not a path inside this vault."
            case .repairRequired(let message):
                return "This vault's manual index needs repairing before a manual can be removed: \(message)"
            case .cleanupFailed(let message):
                return "Removing the manual did not finish: \(message). The manual stays unavailable; try again."
            }
        }

        /// Whether trying again can succeed without the vault being repaired or re-imported.
        var isRetryable: Bool {
            if case .cleanupFailed = self { return true }
            return false
        }
    }

    /// Whether this vault accepts manual removal at all, answered without performing one — what a
    /// row needs to decide between offering the action and saying why it cannot.
    enum Eligibility: Equatable {
        case allowed
        case notInstalled
        case protectedPack(name: String)

        var isAllowed: Bool { self == .allowed }
    }

    /// What a completed removal did. Counts and identifiers only: enough for a caller to report
    /// the outcome and for a test to assert it, with no manual text in it.
    struct RemovalResult: Equatable {
        let vaultId: String
        /// The manifest file name the removal was addressed by.
        let file: String
        let title: String
        /// The document the manual was ingested as, or nil when it had never been indexed.
        let documentId: String?
        /// Chunks deleted from the document store.
        let chunksRemoved: Int
        /// Manuals the vault still lists afterwards.
        let remainingDocuments: Int
        /// Baseline files deleted, relative to the vault root.
        let removedFiles: [String]
        /// Files left alone because a remaining manual still points at them.
        let keptSharedFiles: [String]
    }

    // MARK: - Policy

    /// Whether the entitlement permits removing installed content.
    ///
    /// It always does, and that is the decision rather than an oversight (plan FN, product decision
    /// 5): importing manuals is the paid capability, deleting your own installed content is not,
    /// and a team whose licence lapsed would otherwise be unable to take a superseded manual out of
    /// a vault its technicians are still working from. Import and re-index keep their gate.
    static var isPermittedByEntitlement: Bool { true }

    /// Whether `vaultId` is a vault whose manuals may be removed individually.
    static func eligibility(of vaultId: String) -> Eligibility {
        guard let manifest = VaultImporter.installedManifests().first(where: { $0.id == vaultId }) else {
            return .notInstalled
        }
        if VaultImporter.installedPack(for: vaultId) != nil {
            return .protectedPack(name: manifest.name)
        }
        return .allowed
    }

    // MARK: - Pending removals

    /// Manual file names this vault has a removal in flight for. Everything that reads the vault
    /// treats these as already gone, which is what makes an interrupted removal safe.
    static func pendingFiles(for vaultId: String) -> Set<String> {
        Set(VaultRemovalJournal.load(from: VaultImporter.overlayDirectory(for: vaultId)).pending.map(\.file))
    }

    /// Document ids with a removal in flight, for the retrieval-side availability check.
    static func pendingDocumentIds(for vaultId: String) -> Set<String> {
        Set(VaultRemovalJournal.load(from: VaultImporter.overlayDirectory(for: vaultId))
            .pending.compactMap(\.documentId))
    }

    static func isPending(file: String, vaultId: String) -> Bool {
        pendingFiles(for: vaultId).contains(file)
    }

    // MARK: - Removal

    /// Remove one manual from an installed vault, addressed by the manifest's file name.
    ///
    /// The file name — not the title — is the identity throughout: two manuals may share a title,
    /// a title may be edited between import and removal, and a citation's title is the one thing a
    /// model can get wrong. Works whether the manual was fully indexed, never indexed, or left
    /// half-indexed by an interrupted sync.
    ///
    /// Serialised against import, re-index and uninstall for the same vault: indexing yields
    /// between chunks, so a disabled button is not a guarantee that a sync cannot be running.
    @discardableResult
    static func remove(file: String, fromVault vaultId: String,
                       documentStore: DocumentStore) async throws -> RemovalResult {
        try await VaultOperationLock.withLock(vaultId) {
            try await perform(file: file, vaultId: vaultId, documentStore: documentStore)
        }
    }

    /// Finish any removal this vault was interrupted part-way through. Safe to call when there is
    /// nothing pending, and safe to call twice. Returns what it completed.
    @discardableResult
    static func recoverPendingRemovals(vaultId: String,
                                       documentStore: DocumentStore) async -> [RemovalResult] {
        await VaultOperationLock.withLock(vaultId) {
            recoverLocked(vaultId: vaultId, documentStore: documentStore)
        }
    }

    /// Recovery without taking the lock, for a caller that already holds it — `syncDocuments` does,
    /// and has to finish an interrupted removal *before* it diffs, or a manual whose index rows are
    /// already gone but whose manifest row is not would be re-ingested by the very next sync.
    @discardableResult
    static func recoverLocked(vaultId: String, documentStore: DocumentStore) -> [RemovalResult] {
        let overlay = VaultImporter.overlayDirectory(for: vaultId)
        var completed: [RemovalResult] = []
        for entry in VaultRemovalJournal.load(from: overlay).pending {
            guard let result = try? cleanUp(pending: entry, vaultId: vaultId,
                                            documentStore: documentStore) else { continue }
            completed.append(result)
        }
        if !completed.isEmpty { VaultRegistry.shared.reloadUserManifests() }
        return completed
    }

    /// Finish interrupted removals across every installed vault. Called once at launch, before the
    /// vaults are worked from; a vault whose recovery fails keeps its pending record, and its
    /// target stays unavailable until a later attempt succeeds.
    @discardableResult
    static func recoverPendingRemovals(documentStore: DocumentStore) async -> [RemovalResult] {
        var completed: [RemovalResult] = []
        for manifest in VaultImporter.installedManifests() {
            completed += await recoverPendingRemovals(vaultId: manifest.id, documentStore: documentStore)
        }
        return completed
    }

    // MARK: - Implementation

    private static func perform(file: String, vaultId: String,
                                documentStore: DocumentStore) async throws -> RemovalResult {
        guard let manifest = VaultImporter.installedManifests().first(where: { $0.id == vaultId }) else {
            throw RemovalError.notInstalled(vaultId)
        }
        if VaultImporter.installedPack(for: vaultId) != nil {
            throw RemovalError.protectedPack(manifest.name)
        }
        guard let document = manifest.documents.first(where: { $0.file == file }) else {
            // Already removed and the pending record cleared: idempotent rather than an error, so
            // a retry of a removal that actually finished reports success.
            if let finished = try alreadyRemoved(file: file, manifest: manifest,
                                                 documentStore: documentStore) {
                return finished
            }
            throw RemovalError.unknownDocument(file: file, vaultId: vaultId)
        }

        let baseline = VaultImporter.baselineDirectory(for: vaultId)
        for relative in [manifest.documentRelativePath(document),
                         manifest.documentSourceRelativePath(document)].compactMap({ $0 }) {
            guard isContained(relative, in: baseline) else { throw RemovalError.invalidPath(relative) }
        }

        let overlay = VaultImporter.overlayDirectory(for: vaultId)
        let documentId = try resolveDocumentId(file: file, vaultId: vaultId, overlay: overlay,
                                               documentStore: documentStore)
        let pending = VaultRemovalJournal.Pending(file: file, title: document.title,
                                                  documentId: documentId, startedAt: Date())
        do {
            try VaultRemovalJournal.record(pending, in: overlay)
        } catch {
            throw RemovalError.cleanupFailed(error.localizedDescription)
        }

        let result = try cleanUp(pending: pending, vaultId: vaultId, documentStore: documentStore)
        VaultRegistry.shared.reloadUserManifests()
        return result
    }

    /// Every durable step, in the order that keeps the manual unreachable throughout, and each one
    /// a no-op when it has already happened. This is what a retry and the launch-time recovery both
    /// run, which is why it takes the journal entry rather than the caller's arguments.
    private static func cleanUp(pending: VaultRemovalJournal.Pending, vaultId: String,
                                documentStore: DocumentStore) throws -> RemovalResult {
        let overlay = VaultImporter.overlayDirectory(for: vaultId)
        let baseline = VaultImporter.baselineDirectory(for: vaultId)
        let namespace = DocumentStore.vaultNamespace(vaultId)
        let manifest = VaultImporter.installedManifests().first { $0.id == vaultId }
        let fm = FileManager.default

        var chunksRemoved = 0
        var removedFiles: [String] = []
        var keptSharedFiles: [String] = []

        do {
            // 1. The index. Checked and namespace-scoped: returning means the rows are gone.
            if let documentId = pending.documentId {
                chunksRemoved = try documentStore.forget(documentId: documentId, inNamespace: namespace)
            }

            // 2. The ledger entry — by document id when there is one, else by file, so a manual
            //    that was never indexed still loses whatever the ledger recorded for it.
            var ledger = VaultDocumentLedger.load(from: overlay)
            let removedEntry = pending.documentId.flatMap { ledger.remove(documentId: $0) }
                ?? ledger.remove(file: pending.file)
            if removedEntry != nil || VaultDocumentLedger.exists(in: overlay) {
                try ledger.save(to: overlay)
            }

            // 3. The installed manifest, reduced and saved atomically. Written before the files go,
            //    so a crash between the two leaves a manifest that no longer lists a file that is
            //    still on disk — harmless — rather than a manifest listing a file that is not.
            let reduced = manifest.map { reducedManifest($0, removing: pending.file) }
            if let reduced, manifest?.documents.count != reduced.documents.count {
                try saveInstalledManifest(reduced)
            }

            // 4. The installed files, but only the ones nothing else points at. A vault may bundle
            //    one manufacturer's PDF behind two extracted documents, and a removal that deleted
            //    it would break the manual that stayed.
            let survivors = reduced ?? manifest
            let stillReferenced = Set((survivors?.documents ?? []).flatMap { other in
                [survivors?.documentRelativePath(other),
                 survivors?.documentSourceRelativePath(other)].compactMap { $0 }
            })
            for relative in ownedPaths(of: pending.file, in: manifest) {
                guard isContained(relative, in: baseline) else { continue }
                if stillReferenced.contains(relative) {
                    keptSharedFiles.append(relative)
                    continue
                }
                let url = baseline.appendingPathComponent(relative)
                if fm.fileExists(atPath: url.path) {
                    try fm.removeItem(at: url)
                    removedFiles.append(relative)
                }
            }

            // 5. Recognition checkpoints, under the same shared-reference rule: a checkpoint is
            //    keyed by content hash, and two identical files would share one.
            if let hash = removedEntry?.contentHash,
               !VaultDocumentLedger.load(from: overlay).entries.contains(where: { $0.contentHash == hash }) {
                OCRCheckpoint.remove(from: overlay, contentHash: hash)
            }

            // 6. Only now is the target genuinely gone, so only now does it stop being pending.
            try VaultRemovalJournal.clear(file: pending.file, in: overlay)
        } catch {
            throw RemovalError.cleanupFailed(error.localizedDescription)
        }

        let remaining = (VaultImporter.installedManifests().first { $0.id == vaultId }?.documents ?? []).count
        return RemovalResult(vaultId: vaultId, file: pending.file, title: pending.title,
                             documentId: pending.documentId, chunksRemoved: chunksRemoved,
                             remainingDocuments: remaining, removedFiles: removedFiles,
                             keptSharedFiles: keptSharedFiles)
    }

    /// The document id this manual was ingested as, or nil when it genuinely was never indexed —
    /// and a `repairRequired` throw when the difference cannot be established.
    ///
    /// The ledger is the only record that ties a manifest file to a document id. When it is
    /// unreadable, or when the vault's namespace holds documents no entry accounts for, the honest
    /// answer is that ownership is unknown: the alternative is matching the display title against
    /// document names, which would delete the wrong manual the first time two shared a title.
    private static func resolveDocumentId(file: String, vaultId: String, overlay: URL,
                                          documentStore: DocumentStore) throws -> String? {
        let ledger: VaultDocumentLedger?
        do {
            ledger = try VaultDocumentLedger.loadStrict(from: overlay)
        } catch {
            throw RemovalError.repairRequired("the ledger at \(VaultDocumentLedger.filename) cannot be read")
        }
        if let entry = ledger?.entries.first(where: { $0.file == file }) { return entry.documentId }

        // No entry for this file. Before reporting it as never indexed, check that the ledger
        // accounts for everything the store holds under this vault.
        let namespace = DocumentStore.vaultNamespace(vaultId)
        let indexed = Set(documentStore.list(namespace: namespace).map(\.id))
        let accounted = Set(ledger?.entries.map(\.documentId) ?? [])
        let unaccounted = indexed.subtracting(accounted)
        guard unaccounted.isEmpty else {
            throw RemovalError.repairRequired(
                "\(unaccounted.count) indexed document(s) in this vault are not listed in the ledger, "
                    + "so which one this manual is cannot be established. Re-index the vault first")
        }
        return nil
    }

    /// The result for a manual the manifest no longer lists — a retry of a removal that already
    /// finished. Nil when the vault still has an index or journal record for it, which means the
    /// caller asked about a file this vault never had.
    private static func alreadyRemoved(file: String, manifest: VaultManifest,
                                       documentStore: DocumentStore) throws -> RemovalResult? {
        let overlay = VaultImporter.overlayDirectory(for: manifest.id)
        if let pending = VaultRemovalJournal.load(from: overlay).pending.first(where: { $0.file == file }) {
            return try cleanUp(pending: pending, vaultId: manifest.id, documentStore: documentStore)
        }
        // A ledger entry with no manifest row: the manifest was reduced and the index was not, so
        // there is still work to finish rather than nothing to do.
        guard let entry = VaultDocumentLedger.load(from: overlay).entries.first(where: { $0.file == file })
        else { return nil }
        let pending = VaultRemovalJournal.Pending(file: file, title: entry.title,
                                                  documentId: entry.documentId, startedAt: Date())
        do {
            try VaultRemovalJournal.record(pending, in: overlay)
        } catch {
            throw RemovalError.cleanupFailed(error.localizedDescription)
        }
        return try cleanUp(pending: pending, vaultId: manifest.id, documentStore: documentStore)
    }

    // MARK: - Helpers

    /// The manifest with one document taken out, everything else — id, version, core files,
    /// procedures, gating, prompt rules — untouched.
    static func reducedManifest(_ manifest: VaultManifest, removing file: String) -> VaultManifest {
        VaultManifest(id: manifest.id, name: manifest.name, version: manifest.version,
                      files: manifest.files, proceduresDir: manifest.proceduresDir,
                      documentsDir: manifest.documentsDir,
                      documents: manifest.documents.filter { $0.file != file },
                      gating: manifest.gating, promptRules: manifest.promptRules,
                      sourceAttributionFormat: manifest.sourceAttributionFormat,
                      sourceAttributionRequired: manifest.sourceAttributionRequired)
    }

    private static func saveInstalledManifest(_ manifest: VaultManifest) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: VaultImporter.registryDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest)
            .write(to: VaultImporter.registryDirectory.appendingPathComponent("\(manifest.id).json"),
                   options: .atomic)
    }

    /// The baseline paths one manual owns: its own file, and the manufacturer's original beside it.
    private static func ownedPaths(of file: String, in manifest: VaultManifest?) -> [String] {
        guard let manifest, let document = manifest.documents.first(where: { $0.file == file }) else {
            // The manifest has already been reduced (a retry): the document path can still be
            // rebuilt from the documents directory, and an original we can no longer name is left
            // alone rather than guessed at.
            guard let dir = manifest?.documentsDir, !dir.isEmpty else { return [file] }
            return ["\(dir)/\(file)"]
        }
        return [manifest.documentRelativePath(document),
                manifest.documentSourceRelativePath(document)].compactMap { $0 }
    }

    /// Whether a manifest-supplied relative path stays inside the vault. The manifest is a file a
    /// customer wrote, so `../../Documents/conversations.json` is a path it can contain.
    static func isContained(_ relative: String, in root: URL) -> Bool {
        guard !relative.isEmpty, !relative.hasPrefix("/") else { return false }
        let resolved = root.appendingPathComponent(relative).standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return resolved != base && resolved.hasPrefix(base + "/")
    }
}

// MARK: - The journal

/// The record of a manual removal that has started and not finished, written beside the document
/// ledger in the vault's overlay (`_removals.json`) — the same directory, and for the same reason:
/// it has to survive a baseline re-push, which is one of the moments it matters most.
///
/// Small on purpose. It holds what cleanup needs to be re-run and nothing about the manual's
/// contents: the manifest file name, the title already shown in the vault list, the document id
/// the index knows it by, and when the removal started.
struct VaultRemovalJournal: Codable, Equatable {

    struct Pending: Codable, Equatable {
        let file: String
        let title: String
        /// Nil when the manual was never indexed — there is no document to forget.
        let documentId: String?
        let startedAt: Date
    }

    static let filename = "_removals.json"

    var pending: [Pending] = []

    init(pending: [Pending] = []) { self.pending = pending }

    static func load(from directory: URL) -> VaultRemovalJournal {
        let url = directory.appendingPathComponent(filename)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let journal = try? decoder.decode(VaultRemovalJournal.self, from: data) else {
            return VaultRemovalJournal()
        }
        return journal
    }

    func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }

    /// Record a removal as in flight. Replaces any earlier record for the same file, so a retry
    /// does not accumulate entries.
    static func record(_ entry: Pending, in directory: URL) throws {
        var journal = load(from: directory)
        journal.pending.removeAll { $0.file == entry.file }
        journal.pending.append(entry)
        try journal.save(to: directory)
    }

    /// Clear one file's record. The whole file goes when it was the last one, so a vault that has
    /// never had an interrupted removal keeps nothing.
    static func clear(file: String, in directory: URL) throws {
        var journal = load(from: directory)
        journal.pending.removeAll { $0.file == file }
        if journal.pending.isEmpty {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
        } else {
            try journal.save(to: directory)
        }
    }
}

// MARK: - Operation coordination

/// One operation at a time per vault id.
///
/// Import, re-index, individual removal and uninstall all rewrite the same manifest, ledger,
/// baseline and index rows, and every one of them yields — ingest yields between chunks, removal
/// awaits the lock and the store. Two of them interleaving is how a manual comes back after being
/// removed: a sync that read the manifest before the removal would re-ingest a file the removal
/// then deletes, or write a ledger it computed from the old manifest. Disabling a button prevents
/// none of that, because the operations are not all started from buttons.
///
/// Deliberately a fair FIFO rather than a try-lock: the second caller should run once the first is
/// finished, not be refused.
/// Main-actor confined, because every operation it serialises is already main-actor work. That
/// keeps the gate itself free of any cross-actor hop — the thing being protected is a sequence of
/// main-actor steps with suspension points in it, not a data race.
@MainActor
enum VaultOperationLock {

    private static var busy: Set<String> = []
    private static var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    static func withLock<T>(_ id: String, _ body: () async throws -> T) async rethrows -> T {
        await acquire(id)
        defer { release(id) }
        return try await body()
    }

    /// Whether an operation currently holds this vault — for a caller that wants to say "indexing"
    /// rather than queue silently, and for the tests that assert the serialisation.
    static func isBusy(_ id: String) -> Bool { busy.contains(id) }

    private static func acquire(_ id: String) async {
        guard busy.contains(id) else {
            busy.insert(id)
            return
        }
        await withCheckedContinuation { continuation in
            waiting[id, default: []].append(continuation)
        }
        // Resumed by `release`, which hands the lock straight over without clearing `busy`.
    }

    private static func release(_ id: String) {
        guard var queue = waiting[id], !queue.isEmpty else {
            busy.remove(id)
            waiting[id] = nil
            return
        }
        let next = queue.removeFirst()
        waiting[id] = queue.isEmpty ? nil : queue
        next.resume()
    }
}
