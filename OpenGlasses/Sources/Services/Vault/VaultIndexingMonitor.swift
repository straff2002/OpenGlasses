import Foundation
import UIKit

/// Which vault's manuals are being indexed right now, how far it has got, and who is asking.
///
/// A tester imported a vault with two large code-book PDFs. Indexing started by itself after the
/// import, but its progress lived in the Custom Vaults screen's own state, so leaving the screen
/// and coming back lost the "Indexing…" bar while the per-vault operation lock still held the
/// vault: the rows said "not indexed" in red and "Remove manual…" and "Re-index manuals" were
/// greyed out with no reason given. Progress belongs to the app, not to one copy of a screen, so
/// every copy of it — and `manual_lookup`, which used to tell the model the manuals had never been
/// imported — reads the same run.
@MainActor
final class VaultIndexingMonitor: ObservableObject {

    static let shared = VaultIndexingMonitor()

    /// One vault's index as it runs.
    struct Run: Equatable {
        let vaultId: String
        /// The manual being read or indexed now.
        var title: String
        /// Its place among the manuals this run has to index: "n of m".
        var manualNumber: Int
        var manualCount: Int
        /// Sections stored of the manual's total.
        var completed: Int = 0
        var total: Int = 0
        /// Scanned pages read by recognition, when the manual has any; recognition runs before
        /// chunking and is the slow part.
        var recognitionDone: Int?
        var recognitionTotal: Int?
        /// Titles in the order this run indexes them.
        let titles: [String]

        var isRecognising: Bool {
            guard let done = recognitionDone, let total = recognitionTotal else { return false }
            return done < total
        }

        /// "SLP99UHVK Service Manual — 1 of 2". The count is said only when there is more than one.
        var headline: String {
            manualCount > 1 ? String(localized: "\(title) — \(manualNumber) of \(manualCount)") : title
        }
    }

    @Published private(set) var runs: [String: Run] = [:]

    /// Seam for the tests: what keeps a run going briefly once the app leaves the foreground.
    var backgroundTasks: BackgroundTaskRunning = SystemBackgroundTasks()

    func run(for vaultId: String) -> Run? { runs[vaultId] }

    var isIndexingAny: Bool { !runs.isEmpty }

    // MARK: - Driving a run

    /// Index a vault's manuals through `VaultImporter.syncDocuments`, publishing its progress for
    /// as long as it runs — whichever screen started it and whether or not that screen is still
    /// up. iOS is asked for a little background time so a technician who locks the phone straight
    /// after importing does not come back to a run frozen half-way; when that time runs out the
    /// run simply waits, suspended with the app, and carries on when the app returns.
    @discardableResult
    func sync(_ manifest: VaultManifest, into store: DocumentStore,
              renderPolicy: ScanRenderPolicy = ScanRenderPolicy()) async throws -> VaultDocumentLedger {
        begin(vaultId: manifest.id, titles: Self.pendingTitles(manifest: manifest,
                                                               ledger: VaultImporter.documentLedger(for: manifest.id)))
        // When the time runs out the run is not cancelled: it is suspended with the app and resumes
        // with it, which is what the screen tells the reader.
        let background = backgroundTasks.begin(name: "Indexing manuals")
        defer {
            backgroundTasks.end(background)
            end(vaultId: manifest.id)
        }
        return try await VaultImporter.syncDocuments(
            manifest: manifest, into: store, renderPolicy: renderPolicy,
            progress: { [weak self] title, completed, total in
                self?.progress(vaultId: manifest.id, title: title, completed: completed, total: total)
            },
            recognitionProgress: { [weak self] title, done, total in
                self?.recognition(vaultId: manifest.id, title: title, done: done, total: total)
            })
    }

    // MARK: - State changes (pure over `runs`; the tests drive these directly)

    func begin(vaultId: String, titles: [String]) {
        let ordered = titles.isEmpty ? ["manuals"] : titles
        runs[vaultId] = Run(vaultId: vaultId, title: ordered[0], manualNumber: 1, manualCount: ordered.count,
                            titles: ordered)
    }

    func progress(vaultId: String, title: String, completed: Int, total: Int) {
        guard var run = runs[vaultId] else { return }
        place(title, in: &run)
        run.completed = completed
        run.total = total
        run.recognitionDone = nil
        run.recognitionTotal = nil
        runs[vaultId] = run
    }

    func recognition(vaultId: String, title: String, done: Int, total: Int) {
        guard var run = runs[vaultId] else { return }
        place(title, in: &run)
        run.recognitionDone = done
        run.recognitionTotal = total
        runs[vaultId] = run
    }

    func end(vaultId: String) {
        runs[vaultId] = nil
    }

    private func place(_ title: String, in run: inout Run) {
        run.title = title
        if let index = run.titles.firstIndex(of: title) {
            run.manualNumber = index + 1
        } else {
            run.manualNumber = min(run.manualNumber + 1, max(run.manualCount, run.manualNumber + 1))
            run.manualCount = max(run.manualCount, run.manualNumber)
        }
    }

    /// The manuals a sync will index: those the ledger does not hold yet, in manifest order. A
    /// re-index of manuals that are all indexed (a changed file) counts every manual.
    static func pendingTitles(manifest: VaultManifest, ledger: VaultDocumentLedger) -> [String] {
        let indexed = Set(ledger.entries.map(\.file))
        let pending = manifest.documents.filter { !indexed.contains($0.file) }.map(\.title)
        return pending.isEmpty ? manifest.documents.map(\.title) : pending
    }
}

// MARK: - Background time

/// Asks iOS to keep the app running briefly after it leaves the foreground.
protocol BackgroundTaskRunning {
    func begin(name: String) -> Int
    func end(_ token: Int)
}

/// `UIApplication.beginBackgroundTask`. The expiry handler ends the task itself, as iOS requires —
/// a task left open at expiry gets the app killed rather than suspended.
struct SystemBackgroundTasks: BackgroundTaskRunning {
    func begin(name: String) -> Int {
        // Boxed: the expiry handler needs the identifier `beginBackgroundTask` is about to return.
        final class Box: @unchecked Sendable { var identifier = UIBackgroundTaskIdentifier.invalid }
        let box = Box()
        box.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            UIApplication.shared.endBackgroundTask(box.identifier)
            box.identifier = .invalid
        }
        return box.identifier.rawValue
    }

    func end(_ token: Int) {
        let identifier = UIBackgroundTaskIdentifier(rawValue: token)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

// MARK: - What a search says when the manuals cannot be searched

/// The sentence `manual_lookup` and `manual_figure` return when a vault lists manuals and nothing
/// of them is indexed yet.
///
/// A tester's code question failed with "tool call loop exceeded": every lookup said the manuals
/// had never been imported — they had been, and indexing had not finished — and gave the model
/// nothing to stop on, so it rephrased five times. Each case now says what is true and that
/// searching again this turn will not help. Pure.
enum ManualIndexAvailability {

    static func unsearchableSentence(vaultName: String, listedDocuments: Int,
                                     run: VaultIndexingMonitor.Run?, lockBusy: Bool) -> String {
        guard listedDocuments > 0 else {
            return "No manuals have been imported for the \(vaultName) vault yet. Import them in Settings → Connections → Custom Vaults."
        }
        if let run {
            return "The \(vaultName) manuals are still being indexed (\(run.title) \(run.manualNumber) of \(run.manualCount)). "
                + "They can't be searched until that finishes; tell the technician, and don't search again this turn."
        }
        if lockBusy {
            return "The \(vaultName) manuals are still being indexed. "
                + "They can't be searched until that finishes; tell the technician, and don't search again this turn."
        }
        return "The \(vaultName) manuals are imported but not indexed. The technician can index them in "
            + "Settings → Connections → Custom Vaults → Re-index manuals. Don't search again this turn."
    }

    /// The same, read off the app's live state for one vault.
    @MainActor
    static func unsearchableSentence(for manifest: VaultManifest,
                                     monitor: VaultIndexingMonitor? = nil) -> String {
        unsearchableSentence(vaultName: manifest.name, listedDocuments: manifest.documents.count,
                             run: (monitor ?? .shared).run(for: manifest.id),
                             lockBusy: VaultOperationLock.isBusy(manifest.id))
    }
}
