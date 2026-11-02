import XCTest
@testable import OpenGlasses

/// A tester imported a vault with two large code-book PDFs. Indexing started by itself, but its
/// progress was the Custom Vaults screen's own state: leaving the screen and coming back showed
/// both manuals as "not indexed" in red with "Remove manual…" and "Re-index manuals" greyed out
/// and no reason, and a code question failed on "tool call loop exceeded" because every lookup said
/// the manuals had never been imported. These tests hold the row, the progress and the lookup's
/// sentence to what is actually true.
@MainActor
final class VaultIndexingStateTests: XCTestCase {

    private let service = VaultDocument(file: "service.pdf", title: "Wiring Rules Part 1")
    private let install = VaultDocument(file: "install.pdf", title: "Wiring Rules Part 2")

    private func row(_ document: VaultDocument, indexed: Bool = false, busy: Bool = false,
                     indexing: String? = nil) -> VaultManualRowState {
        let entry = indexed ? VaultDocumentLedger.Entry(file: document.file, title: document.title,
                                                        documentId: "id-\(document.file)", contentHash: "h",
                                                        chunkCount: 40) : nil
        return VaultManualRowState.make(document: document, ledgerEntry: entry, summary: indexed ? "40 sections" : nil,
                                        pendingFiles: [], inFlightFile: nil, eligibility: .allowed,
                                        isVaultBusy: busy, indexingTitle: indexing)
    }

    // MARK: - Rows

    func testAManualBeingIndexedSaysSoAndIsNotAdverse() {
        let current = row(service, busy: true, indexing: service.title)
        XCTAssertEqual(current.status, .indexing)
        XCTAssertEqual(current.statusText, "Indexing…")
        XCTAssertFalse(current.isStatusAdverse)
        XCTAssertEqual(current.accessibilityLabel, "Wiring Rules Part 1, indexing")

        let next = row(install, busy: true, indexing: service.title)
        XCTAssertEqual(next.status, .waitingToIndex)
        XCTAssertEqual(next.statusText, "Waiting to index")
        XCTAssertFalse(next.isStatusAdverse, "never the adverse \"not indexed\" while an index is running")
    }

    func testGreyedControlsCarryTheirReason() {
        let indexingRow = row(service, busy: true, indexing: service.title)
        XCTAssertFalse(indexingRow.isActionEnabled)
        XCTAssertEqual(indexingRow.disabledReason, "Available when indexing finishes")

        let otherTask = row(service, indexed: true, busy: true)
        XCTAssertEqual(otherTask.disabledReason, "Available when the current task on this vault finishes")

        let free = row(service, indexed: true)
        XCTAssertTrue(free.isActionEnabled)
        XCTAssertNil(free.disabledReason)

        XCTAssertEqual(VaultManualRowState.reindexDisabledReason(isIndexing: true, isVaultBusy: true),
                       "Available when indexing finishes")
        XCTAssertEqual(VaultManualRowState.reindexDisabledReason(isIndexing: false, isVaultBusy: true),
                       "Available when the current task on this vault finishes")
        XCTAssertNil(VaultManualRowState.reindexDisabledReason(isIndexing: false, isVaultBusy: false))
        XCTAssertTrue(VaultManualRowState.backgroundNotice.contains("pauses"))
    }

    func testNotIndexedWithNothingRunningStaysAdverse() {
        let idle = row(service)
        XCTAssertEqual(idle.status, .notIndexed)
        XCTAssertTrue(idle.isStatusAdverse)
        XCTAssertNil(idle.disabledReason)
    }

    // MARK: - Progress that outlives the screen

    func testProgressIsTheAppsAndSaysWhichManualOfHowMany() {
        let monitor = VaultIndexingMonitor()
        let manifest = VaultManifest(id: "v", name: "Wiring", version: "1", files: [], proceduresDir: nil,
                                     documentsDir: "documents", documents: [service, install],
                                     gating: .init(iap: "enterprise"), promptRules: [])
        monitor.begin(vaultId: "v", titles: VaultIndexingMonitor.pendingTitles(manifest: manifest,
                                                                              ledger: VaultDocumentLedger()))
        XCTAssertEqual(monitor.run(for: "v")?.headline, "Wiring Rules Part 1 — 1 of 2")
        monitor.progress(vaultId: "v", title: install.title, completed: 12, total: 300)
        let run = monitor.run(for: "v")
        XCTAssertEqual(run?.headline, "Wiring Rules Part 2 — 2 of 2")
        XCTAssertEqual(run?.completed, 12)
        monitor.recognition(vaultId: "v", title: install.title, done: 3, total: 10)
        XCTAssertEqual(monitor.run(for: "v")?.isRecognising, true)
        monitor.end(vaultId: "v")
        XCTAssertNil(monitor.run(for: "v"))
        XCTAssertFalse(monitor.isIndexingAny)
    }

    func testOnlyManualsNotYetIndexedAreCounted() {
        let manifest = VaultManifest(id: "v", name: "Wiring", version: "1", files: [], proceduresDir: nil,
                                     documentsDir: "documents", documents: [service, install],
                                     gating: .init(iap: "enterprise"), promptRules: [])
        let ledger = VaultDocumentLedger(entries: [.init(file: service.file, title: service.title, documentId: "a",
                                                         contentHash: "h", chunkCount: 1)])
        XCTAssertEqual(VaultIndexingMonitor.pendingTitles(manifest: manifest, ledger: ledger), [install.title])
        let all = VaultDocumentLedger(entries: [.init(file: service.file, title: service.title, documentId: "a",
                                                      contentHash: "h", chunkCount: 1),
                                                .init(file: install.file, title: install.title, documentId: "b",
                                                      contentHash: "h", chunkCount: 1)])
        XCTAssertEqual(VaultIndexingMonitor.pendingTitles(manifest: manifest, ledger: all).count, 2,
                       "a re-index of changed manuals counts them all")
    }

    func testABackgroundTaskIsHeldForTheRun() {
        final class Recorder: BackgroundTaskRunning {
            var begun: [String] = []
            var ended: [Int] = []
            func begin(name: String) -> Int { begun.append(name); return 7 }
            func end(_ token: Int) { ended.append(token) }
        }
        let recorder = Recorder()
        let monitor = VaultIndexingMonitor()
        monitor.backgroundTasks = recorder
        let token = monitor.backgroundTasks.begin(name: "Indexing manuals")
        monitor.backgroundTasks.end(token)
        XCTAssertEqual(recorder.begun, ["Indexing manuals"])
        XCTAssertEqual(recorder.ended, [7])
    }

    // MARK: - What a search says

    func testTheLookupSaysWhatIsTrueAndToStop() {
        var run = VaultIndexingMonitor.Run(vaultId: "v", title: "Wiring Rules Part 1", manualNumber: 1,
                                           manualCount: 2, titles: ["Wiring Rules Part 1", "Wiring Rules Part 2"])
        run.completed = 10
        let indexing = ManualIndexAvailability.unsearchableSentence(vaultName: "Electrical", listedDocuments: 2,
                                                                    run: run, lockBusy: true)
        XCTAssertEqual(indexing, "The Electrical manuals are still being indexed (Wiring Rules Part 1 1 of 2). "
                       + "They can't be searched until that finishes; tell the technician, and don't search again this turn.")

        let locked = ManualIndexAvailability.unsearchableSentence(vaultName: "Electrical", listedDocuments: 2,
                                                                  run: nil, lockBusy: true)
        XCTAssertTrue(locked.contains("still being indexed"))
        XCTAssertTrue(locked.contains("don't search again this turn"))

        let notIndexed = ManualIndexAvailability.unsearchableSentence(vaultName: "Electrical", listedDocuments: 2,
                                                                      run: nil, lockBusy: false)
        XCTAssertEqual(notIndexed, "The Electrical manuals are imported but not indexed. The technician can index them in "
                       + "Settings → Connections → Custom Vaults → Re-index manuals. Don't search again this turn.")
        XCTAssertFalse(notIndexed.contains("No manuals have been imported"))

        let none = ManualIndexAvailability.unsearchableSentence(vaultName: "Electrical", listedDocuments: 0,
                                                                run: nil, lockBusy: false)
        XCTAssertEqual(none, "No manuals have been imported for the Electrical vault yet. Import them in Settings → Connections → Custom Vaults.")
    }

    func testTheLiveSentenceReadsTheMonitor() {
        let monitor = VaultIndexingMonitor()
        let manifest = VaultManifest(id: "live-v", name: "Electrical", version: "1", files: [], proceduresDir: nil,
                                     documentsDir: "documents", documents: [service, install],
                                     gating: .init(iap: "enterprise"), promptRules: [])
        XCTAssertTrue(ManualIndexAvailability.unsearchableSentence(for: manifest, monitor: monitor)
            .contains("imported but not indexed"))
        monitor.begin(vaultId: "live-v", titles: [service.title, install.title])
        XCTAssertTrue(ManualIndexAvailability.unsearchableSentence(for: manifest, monitor: monitor)
            .contains("(Wiring Rules Part 1 1 of 2)"))
    }

    // MARK: - Resume only when paused

    func testTheOpenJobIsResumedOnlyWhenPaused() {
        XCTAssertEqual(OpenJobWording.goToTitle(jobLabel: "Job EL101", isPaused: false), "Open Job EL101")
        XCTAssertEqual(OpenJobWording.goToTitle(jobLabel: "Job EL101", isPaused: true), "Resume Job EL101")
        XCTAssertEqual(OpenJobWording.goToTitle(jobLabel: nil, isPaused: false), "Open the current job")
        XCTAssertEqual(OpenJobWording.goToTitle(jobLabel: nil, isPaused: true), "Resume the open job")
        XCTAssertEqual(OpenJobPrompt(jobLabel: "Job 1005", isPaused: true).resumeTitle, "Resume Job 1005")
        XCTAssertEqual(OpenJobPrompt(jobLabel: "Job 1005").resumeTitle, "Open Job 1005")
        guard case .jobOpen(let prompt) = JobListAdd.decide(openJobLabel: "Job 7", openJobPaused: true) else {
            return XCTFail()
        }
        XCTAssertEqual(prompt.resumeTitle, "Resume Job 7")
        let facts = JobListRouting.Facts(openSessionId: "s", openJobLabel: "Job 7", openJobPaused: false)
        XCTAssertEqual(JobListRouting.resolve(.newJob, facts).prompt?.resumeTitle, "Open Job 7")
    }
}
