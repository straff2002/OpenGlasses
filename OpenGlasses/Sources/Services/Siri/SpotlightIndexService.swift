import CoreSpotlight
import Foundation

// MARK: - Plan BQ P2 — Spotlight donation (thin edge over IndexPlanner)

/// Gathers the records the user's config currently exposes. `override` is the headless
/// test seam; the live path reads the real stores (documented per-store in
/// `SiriContentAdapters`). All reads are read-only — no store is constructed whose init
/// mutates disk (`TeleprompterScriptStore` drains the share inbox, `PlaybookStore` seeds
/// defaults; both are reached through the app's existing instances instead).
@MainActor
enum SiriContentProvider {
    static var override: (() -> [IndexableRecord])?

    static func currentRecords() -> [IndexableRecord] {
        if let override { return override() }
        guard !Config.hipaaMode else { return [] }
        return live(config: Config.siriContentIndex)
    }

    private static func live(config: SiriContentIndexConfig) -> [IndexableRecord] {
        var records: [IndexableRecord] = []
        let defaults = UserDefaults.standard

        if config.isEnabled(.note) {
            let quick: [StoredQuickNote] = decode(defaults.data(forKey: "nativeTool_savedNotes"))
            records += SiriContentAdapters.notes(
                quick: quick,
                contextual: ContextualNoteStore.shared.all()
            )
        }
        if config.isEnabled(.meetingSummary) {
            let raw = SavedNotesStore.load(defaults: defaults)
            records += SiriContentAdapters.meetingSummaries(rawSavedNotes: raw)
        }
        if config.isEnabled(.savedLocation) {
            let locations: [StoredSavedLocation] = decode(defaults.data(forKey: "saved_locations"))
            records += SiriContentAdapters.savedLocations(locations)
        }
        if config.isEnabled(.teleprompterScript), let appState = AppStateProvider.shared {
            records += SiriContentAdapters.teleprompterScripts(appState.teleprompterStore.scripts)
        }
        if config.isEnabled(.playbook), let appState = AppStateProvider.shared {
            records += SiriContentAdapters.playbooks(appState.playbookStore.playbooks)
        }
        if config.isEnabled(.studyDeck) {
            records += SiriContentAdapters.studyDecks(StudyStore.shared.decks)
        }
        if config.isEnabled(.readingSession) {
            records += SiriContentAdapters.readingSessions(ReadingSessionStore.shared.sessions)
        }
        if config.isEnabled(.conversation), let appState = AppStateProvider.shared,
           !appState.conversationStore.isLocked {
            let summaries = appState.conversationStore.threads.map {
                ConversationSummaryInput(
                    id: $0.id, title: $0.title, summary: $0.summary, updatedAt: $0.updatedAt)
            }
            records += SiriContentAdapters.conversations(summaries)
        }
        if config.isEnabled(.fieldSession) {
            records += SiriContentAdapters.fieldSessions(
                FieldSessionService.shared.history,
                allowedVaults: config.fieldSessionVaults
            )
        }
        return records
    }

    private static func decode<T: Decodable>(_ data: Data?) -> [T] {
        guard let data, let decoded = try? JSONDecoder().decode([T].self, from: data) else {
            return []
        }
        return decoded
    }
}

/// Injectable Spotlight surface so orchestration is testable without CoreSpotlight.
protocol SpotlightIndexing {
    func upsert(_ entities: [GlassesContentEntity]) async throws
    func delete(ids: [String]) async throws
    func deleteAll() async throws
}

struct LiveSpotlightIndexer: SpotlightIndexing {
    func upsert(_ entities: [GlassesContentEntity]) async throws {
        try await CSSearchableIndex.default().indexAppEntities(entities)
    }

    func delete(ids: [String]) async throws {
        try await CSSearchableIndex.default()
            .deleteAppEntities(identifiedBy: ids, ofType: GlassesContentEntity.self)
    }

    func deleteAll() async throws {
        try await CSSearchableIndex.default().deleteAllSearchableItems()
    }
}

/// Dumb executor of `IndexPlanner` plans. Triggers: app-foreground, Siri & Search settings
/// mutations, and HIPAA enable (purge — via `HIPAAComplianceService.setMode`).
@MainActor
final class SpotlightIndexService {
    static let shared = SpotlightIndexService()

    private let indexer: SpotlightIndexing
    private let defaults: UserDefaults
    private let snapshotKey = "siriContentIndexSnapshot"
    private var refreshTask: Task<Void, Never>?

    init(indexer: SpotlightIndexing = LiveSpotlightIndexer(), defaults: UserDefaults = .standard) {
        self.indexer = indexer
        self.defaults = defaults
    }

    /// Diff current records against the last-donated snapshot and apply the delta.
    /// Coalesces: a refresh requested while one runs replaces the pending one.
    func requestRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { await refresh() }
    }

    func refresh() async {
        guard !Config.hipaaMode else {
            await purgeAll()
            return
        }
        let records = SiriContentProvider.currentRecords()
        let plan = IndexPlanner.plan(current: records, previous: loadSnapshot())
        guard !plan.isEmpty else { return }
        do {
            if !plan.deletions.isEmpty {
                try await indexer.delete(ids: plan.deletions)
            }
            if !plan.upserts.isEmpty {
                try await indexer.upsert(plan.upserts.map(GlassesContentEntity.init))
            }
            saveSnapshot(IndexPlanner.snapshot(records))
        } catch {
            // Leave the snapshot untouched — the next refresh retries the same delta. The delta
            // is made of note and conversation titles on their way into the OS index, so the
            // event carries how many moved, never which.
            PrivacyLog.transfer(.spotlightIndex, .donationFailed,
                                count: plan.upserts.count, total: plan.deletions.count,
                                error: SafeErrorSummary(error))
        }
    }

    /// Remove every donated item (HIPAA enable, or all types toggled off).
    func purgeAll() async {
        do {
            try await indexer.deleteAll()
            saveSnapshot([:])
        } catch {
            PrivacyLog.transfer(.spotlightIndex, .purgeFailed, error: SafeErrorSummary(error))
        }
    }

    // MARK: Snapshot persistence

    private func loadSnapshot() -> [String: String] {
        guard let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return snapshot
    }

    private func saveSnapshot(_ snapshot: [String: String]) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: snapshotKey)
        }
    }
}
