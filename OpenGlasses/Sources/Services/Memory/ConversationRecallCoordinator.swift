import Foundation
import Combine

enum ConversationRecallState: Equatable, Sendable {
    case locked
    case rebuilding(completed: Int, total: Int)
    case ready(version: UInt64)
    case unavailable
}

enum ConversationRecallSearchResult: Equatable, Sendable {
    case locked
    case rebuilding
    case ready(hits: [RecallHit], version: UInt64)
    case unavailable
}

enum ConversationRecallProjectionEvent: Equatable, Sendable {
    case messageUpsert(IndexedTurn)
    case messageDelete(ids: [String])
    case threadDelete(id: String)
    case storeReplaced
}

/// Owns the disposable decrypted recall projection. There is no file-backed production fallback:
/// lock destroys the SQLite connection, and unlock rebuilds a fresh in-memory FTS index from the
/// authoritative `ConversationStore` snapshot.
@MainActor
final class ConversationRecallCoordinator: ObservableObject {
    @Published private(set) var state: ConversationRecallState = .locked

    private var index: ConversationIndex?
    private var rebuildTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var projectionVersion: UInt64 = 0
    private var legacyDirectory: URL?
    private let migrateLegacyArtifacts: (URL) -> Bool

    init(migrateLegacyArtifacts: @escaping (URL) -> Bool = {
        RecallIndexMigration(directory: $0).removeLegacyArtifacts()
    }) {
        self.migrateLegacyArtifacts = migrateLegacyArtifacts
    }

    deinit { rebuildTask?.cancel() }

    func start(threads: [ConversationThread], isLocked: Bool, legacyDirectory: URL) {
        rebuildTask?.cancel()
        index = nil
        self.legacyDirectory = legacyDirectory

        guard migrateLegacyArtifacts(legacyDirectory) else {
            state = .unavailable
            return
        }
        guard !isLocked else {
            state = .locked
            return
        }
        rebuild(from: threads)
    }

    func storeDidUnlock(threads: [ConversationThread]) {
        // A busy legacy WAL/SHM can make the launch cleanup fail. Unlock is the next safe retry;
        // never rebuild while a durable plaintext artifact is still present.
        guard let legacyDirectory, migrateLegacyArtifacts(legacyDirectory) else {
            rebuildTask?.cancel()
            index = nil
            state = .unavailable
            return
        }
        rebuild(from: threads)
    }

    func storeDidLock() {
        generation &+= 1
        rebuildTask?.cancel()
        rebuildTask = nil
        index = nil
        state = .locked
    }

    func apply(_ event: ConversationRecallProjectionEvent,
               persistedSnapshot: [ConversationThread]) {
        guard case .ready = state, let index else {
            // A mutation persisted while an unlock rebuild was in flight. Rebuild from the exact
            // persisted snapshot instead of applying a delta to a partial projection.
            if case .rebuilding = state { rebuild(from: persistedSnapshot) }
            return
        }

        switch event {
        case .messageUpsert(let turn):
            index.index(turn)
        case .messageDelete(let ids):
            index.delete(messageIDs: ids)
        case .threadDelete(let id):
            index.delete(threadID: id)
        case .storeReplaced:
            rebuild(from: persistedSnapshot)
            return
        }
        projectionVersion &+= 1
        state = .ready(version: projectionVersion)
    }

    func search(_ phrase: String, now: Date = Date(), limit: Int = 12) -> ConversationRecallSearchResult {
        switch state {
        case .locked:
            return .locked
        case .rebuilding:
            return .rebuilding
        case .unavailable:
            return .unavailable
        case .ready(let version):
            return .ready(hits: index?.search(phrase: phrase, now: now, limit: limit) ?? [],
                          version: version)
        }
    }

    private func rebuild(from threads: [ConversationThread]) {
        generation &+= 1
        let requestedGeneration = generation
        rebuildTask?.cancel()
        index = nil

        let turns = Self.indexedTurns(from: threads)
        state = .rebuilding(completed: 0, total: turns.count)
        rebuildTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                let candidate = ConversationIndex.inMemory()
                let completed = candidate.indexAll(turns, shouldCancel: {
                    withUnsafeCurrentTask { $0?.isCancelled ?? false }
                })
                return completed ? candidate : nil
            }
            let built = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                // Detached work does not inherit cancellation from the main-actor lifecycle task.
                // Explicitly cancel it so locking does not retain or finish indexing decrypted turns.
                worker.cancel()
            }

            guard let self, !Task.isCancelled,
                  requestedGeneration == self.generation,
                  let built else { return }
            self.index = built
            self.projectionVersion &+= 1
            self.state = .ready(version: self.projectionVersion)
            self.rebuildTask = nil
        }
    }

    private static func indexedTurns(from threads: [ConversationThread]) -> [IndexedTurn] {
        threads.flatMap { thread in
            thread.messages.compactMap { message in
                guard message.role == "user" || message.role == "assistant" else { return nil }
                guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return IndexedTurn(id: message.id, threadID: thread.id, role: message.role,
                                   text: message.content, timestamp: message.timestamp)
            }
        }
    }
}

/// Versioned, idempotent removal of the former durable plaintext recall projection. Absence is the
/// completion marker: every launch retries any artifact that survived a partial or failed removal.
struct RecallIndexMigration {
    static let version = 1
    static let legacyNames = [
        "conversation_index.sqlite",
        "conversation_index.sqlite-wal",
        "conversation_index.sqlite-shm",
    ]

    let directory: URL
    var fileManager: FileManager = .default

    func removeLegacyArtifacts() -> Bool {
        for name in Self.legacyNames {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                NSLog("[ConversationRecall] Legacy recall index removal failed")
                return false
            }
        }
        return Self.legacyNames.allSatisfy {
            !fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }
}
