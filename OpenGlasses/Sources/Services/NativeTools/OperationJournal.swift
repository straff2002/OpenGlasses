import Foundation
import CryptoKit

// MARK: - Idempotency key

/// The stable identity of one operation, derived rather than invented.
///
/// Two deliveries of the same tool call must land on the same key or at-most-once execution is
/// impossible, so the key is built from what a redelivery repeats: the root invocation id the
/// provider gave the call, the path from that root down to the resolved target, and a digest of the
/// final arguments. A *different* call — different target, different arguments, or a fresh root —
/// gets a different key and runs normally.
///
/// The caller supplying a stable root id is what makes this work. `ToolDispatcher` passes the
/// provider's `tool_use`/`tool_call` id and the live-session router passes the function-call id;
/// where no such id exists the root is a fresh UUID, the key is unique, and nothing is de-duplicated
/// — the guarantee holds exactly where the delivery is identifiable, and never pretends otherwise.
enum OperationIdempotencyKey {
    static func derive(_ call: ResolvedToolCall) -> String {
        let path = (call.context.ancestry + [call.name]).joined(separator: "/")
        let material = [
            call.context.rootInvocationID,
            path,
            ToolCallBreaker.argsKey(call.arguments.rawValues),
        ].joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// The idempotency key of the operation currently executing, for adapters that can carry one on the
/// wire. A task-local rather than a parameter on `NativeTool.execute(args:)`, which is the
/// registry-wide signature that all 36+ tools share and only a handful of them could use.
enum OperationScope {
    @TaskLocal static var idempotencyKey: String?
}

// MARK: - Journal

/// What admitting a call to the journal decided.
enum OperationAdmission: Equatable {
    /// No live record for this key: the operation is journaled as `started` and may dispatch.
    case proceed(OperationRecord)
    /// This exact call already ran, or is running. The existing record governs; do not dispatch.
    case duplicate(OperationRecord)
    /// The pre-dispatch record could not be made durable. The operation must not dispatch because
    /// its outcome could not be recovered or de-duplicated after a crash.
    case storageUnavailable
}

/// What recording a terminal outcome amounted to.
enum OperationResolution: Equatable {
    case recorded(OperationRecord)
    /// The authoritative answer arrived after the caller had been told the outcome was unknown.
    /// The conversation has moved on, so this is an operation-status update and never a second
    /// spoken success.
    case late(OperationRecord)
    /// No such operation — the call was never journaled (a read, or an intrinsically repeatable
    /// tool), so there is nothing to update.
    case unknownOperation
}

/// A durable record of operations that cannot safely be repeated.
///
/// Deliberately narrow: it is asked whether a call may run, and told how it ended. Everything else
/// — retention, recovery, protection at rest — belongs to the implementation.
@MainActor
protocol OperationJournal: AnyObject {
    /// Whether this call may dispatch, journaling it as `started` when it may.
    func admit(call: ResolvedToolCall, semantics: ToolExecutionSemantics, key: String,
               at now: Date) -> OperationAdmission
    /// Record how an operation ended.
    @discardableResult
    func resolve(operationID: String, outcome: ToolExecutionOutcome, at now: Date) -> OperationResolution
    /// The outcome a repeat delivery is answered with, from what the record knows.
    func replayOutcome(for record: OperationRecord) -> ToolExecutionOutcome
    /// Newest first.
    var records: [OperationRecord] { get }
    func record(forKey key: String) -> OperationRecord?
}

extension OperationJournal {
    /// Operations left unresolved by a process that died mid-flight.
    var recoveredOperations: [OperationRecord] {
        records.filter { $0.recoveredFromRestart && $0.isUnresolved }
    }

    /// Every operation whose fate is still open, whether this process started it or inherited it
    /// from one that died.
    ///
    /// This is the query a recovery surface reads: "these things may or may not have happened".
    /// No UI presents it yet — the affordance is owed — but the state it would show is here and
    /// under test, rather than being reconstructed later from a log.
    var unresolvedOperations: [OperationRecord] {
        records.filter(\.isUnresolved)
    }

    /// Settle an operation from an answer obtained after the fact — a tool that grew a status
    /// endpoint, or a person who checked and can say.
    ///
    /// Distinct from ``resolve(operationID:outcome:at:)`` on purpose: reconciliation applies only
    /// to a row that is still open. An operation that already settled is not re-decided by
    /// someone looking at it later.
    @discardableResult
    func reconcile(operationID: String, outcome: ToolExecutionOutcome,
                   at now: Date = Date()) -> OperationResolution {
        guard let record = records.first(where: { $0.operationID == operationID }),
              record.isUnresolved else { return .unknownOperation }
        return resolve(operationID: operationID, outcome: outcome, at: now)
    }
}

// MARK: - Retention

/// How much content-free history the journal keeps.
///
/// Small on purpose. The journal exists to stop an action happening twice and to be able to say
/// afterwards that something's fate is unknown; neither needs a long tail, and a security store
/// that grows without bound is its own liability.
struct OperationJournalRetention: Sendable, Equatable {
    /// Hard ceiling on rows, whatever their age.
    let maxRecords: Int
    /// How long a settled operation is kept.
    let settledMaxAge: TimeInterval
    /// How long an unresolved one is kept — longer, because it is the row someone may need to
    /// explain a duplicate charge or a message nobody can account for.
    let unresolvedMaxAge: TimeInterval

    static let `default` = OperationJournalRetention(
        maxRecords: 200, settledMaxAge: 7 * 24 * 3600, unresolvedMaxAge: 30 * 24 * 3600)
}

// MARK: - Reconciliation

/// A tool that can be asked, after the fact, whether an operation it started actually landed.
///
/// Nothing conforms today — none of the current adapters (MCP `tools/call`, the gateway bridge, a
/// user-authored URL scheme) exposes a status endpoint to ask. The seam is here so that a tool which
/// gains one can settle its own unresolved rows instead of leaving them unknown forever.
@MainActor
protocol OperationReconciling {
    /// The authoritative outcome, or nil when the tool cannot tell either.
    func reconcile(operationID: String, idempotencyKey: String) async -> ToolExecutionOutcome?
}

// MARK: - Retry advice

/// Whether an interrupted operation may be tried again, and on whose say-so.
enum OperationRetryAdvice: Equatable {
    /// Nothing landed, or landing twice converges — a retry is safe without asking anyone.
    case safeToRetry
    /// The effect may already exist. A person may retry only after checking what actually happened.
    case reconcileFirst(String)
    /// It already succeeded; repeating it would duplicate the effect for no reason.
    case doNotRetry(String)

    /// The only question the tool loop asks. Automatic retry is the exception, not the default.
    var allowsAutomaticRetry: Bool { self == .safeToRetry }
}

enum OperationRetryPolicy {
    static func advice(for record: OperationRecord,
                       semantics: ToolExecutionSemantics) -> OperationRetryAdvice {
        switch record.state {
        case .failed:
            return .safeToRetry
        case .completed:
            return .doNotRetry(
                "'\(record.toolName)' already completed for this request; use that result.")
        case .started, .unknown:
            guard !semantics.isSafeToRepeat else { return .safeToRetry }
            return .reconcileFirst(
                "Whether '\(record.toolName)' took effect is unknown. Check what actually happened "
                    + "before running it again.")
        }
    }
}

// MARK: - Serialization by logical resource

/// A fair, first-come queue per logical resource.
///
/// The idempotency key stops the *same* operation running twice, but nothing stops two different
/// operations reaching the same place at once — and the adapters that would otherwise sort that out
/// (a server-side key, a transaction) don't exist here. Holding one operation per resource at a time
/// is the part that can be done on this side of the wire.
///
/// The resource defaults to the tool name, which is as fine-grained as anything here can honestly
/// claim to know. Re-entering the same resource from inside a held operation cannot happen: the
/// authorization policy already refuses a call that re-enters a tool on its own ancestry.
@MainActor
final class OperationResourceSerializer {
    private var busy: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Run `body` with exclusive hold on `resource`. Released when `body` returns — including when
    /// it returns because the router stopped waiting, which is what bounds the hold.
    func withResource<T>(_ resource: String, _ body: () async -> T) async -> T {
        await acquire(resource)
        defer { release(resource) }
        return await body()
    }

    private func acquire(_ resource: String) async {
        guard busy.contains(resource) else {
            busy.insert(resource)
            return
        }
        await withCheckedContinuation { continuation in
            waiting[resource, default: []].append(continuation)
        }
        // Resumed by `release`, which hands the hold over rather than clearing it.
    }

    private func release(_ resource: String) {
        guard var queue = waiting[resource], !queue.isEmpty else {
            waiting[resource] = nil
            busy.remove(resource)
            return
        }
        let next = queue.removeFirst()
        waiting[resource] = queue.isEmpty ? nil : queue
        next.resume()
    }
}

// MARK: - Protected on-device journal

/// The operation journal, kept as one small protected JSON file.
///
/// Protected at rest with `NSFileProtectionCompleteUntilFirstUserAuthentication` rather than
/// `...Complete`: the journal has to be readable at launch — that is when a process that died
/// mid-operation is discovered — and a locked device would otherwise hide exactly the rows that
/// matter. Nothing in it is sensitive on its own; the protection is there because a record of what
/// this device did, and when, is worth keeping off a lifted disk regardless.
@MainActor
final class ProtectedOperationJournal: OperationJournal {
    static let shared = ProtectedOperationJournal()

    nonisolated static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication

    private let storage: OperationJournalStorage
    private let retention: OperationJournalRetention
    private var rows: [OperationRecord] = []
    /// Fail closed after an unreadable/corrupt store or a failed write. Reconstructing the service
    /// after protected data becomes available retries loading without overwriting the original.
    private(set) var storageAvailable = true
    /// Successful tool output, kept only for the life of this process so a redelivery inside the
    /// same session can be answered with the real result. Never encoded, never written to disk.
    private var completedValues: [String: String] = [:]
    private static let memoLimit = 32
    /// Whether the last load had to drop an incomplete tail. The rows before it were recovered;
    /// the damaged bytes were moved aside rather than overwritten.
    private(set) var quarantinedDamagedTail = false

    var records: [OperationRecord] { rows }

    convenience init(directory: URL? = nil, retention: OperationJournalRetention = .default,
                     now: Date = Date()) {
        self.init(storage: FileOperationJournalStorage(directory: directory),
                  retention: retention, now: now)
    }

    /// The storage seam exists so the failures that decide whether a consequential call may run —
    /// a full disk, protected data still locked, a process killed mid-write — can be exercised.
    init(storage: OperationJournalStorage, retention: OperationJournalRetention = .default,
         now: Date = Date()) {
        self.storage = storage
        self.retention = retention
        storageAvailable = load()
        guard storageAvailable else { return }
        recoverInterruptedOperations(at: now)
        prune(at: now)
        storageAvailable = persist()
    }

    // MARK: Journal

    func admit(call: ResolvedToolCall, semantics: ToolExecutionSemantics, key: String,
               at now: Date) -> OperationAdmission {
        guard storageAvailable else { return .storageUnavailable }
        if let existing = record(forKey: key) {
            // A settled failure means nothing happened, so the same call may legitimately be made
            // again; the old row is replaced rather than blocking the retry it authorises.
            if existing.state.isUnresolved || existing.state == .completed {
                return .duplicate(existing)
            }
            rows.removeAll { $0.idempotencyKey == key }
        }

        let context = call.context
        let record = OperationRecord(
            operationID: context.invocationID,
            idempotencyKey: key,
            toolName: call.name,
            effect: semantics.effect,
            origin: context.origin,
            depth: context.depth,
            rootFingerprint: ToolAuthorizationEventLog.fingerprint(context.rootInvocationID),
            parentFingerprint: context.parent.map {
                ToolAuthorizationEventLog.fingerprint($0.invocationID)
            },
            composerFingerprint: context.parent?.composerID.map(
                ToolAuthorizationEventLog.fingerprint),
            startedAt: now,
            updatedAt: now,
            state: .started)
        let previousRows = rows
        rows.insert(record, at: 0)
        prune(at: now)
        guard persist() else {
            // The external effect has not started. Restore the in-memory view and refuse dispatch;
            // a caller may retry after storage is repaired or a fresh journal is constructed.
            rows = previousRows
            storageAvailable = false
            return .storageUnavailable
        }
        return .proceed(record)
    }

    @discardableResult
    func resolve(operationID: String, outcome: ToolExecutionOutcome,
                 at now: Date) -> OperationResolution {
        guard let index = rows.firstIndex(where: { $0.operationID == operationID }) else {
            return .unknownOperation
        }
        // The late-completion case: the caller was already told the outcome was unknown, and this
        // is the answer arriving afterwards. Updating the row is the whole point — the conversation
        // is over, but the record of what happened should still be true.
        let wasUnknown = rows[index].state == .unknown
        rows[index].state = OperationState(outcome)
        rows[index].updatedAt = now
        rows[index].resolvedLate = wasUnknown && rows[index].state.isTerminal
        if case .completed(let value) = outcome { memoize(value, for: operationID) }
        let updated = rows[index]
        prune(at: now)
        if !persist() {
            // The effect may already have happened, so its in-memory outcome remains the honest
            // answer for this process. Refuse subsequent unsafe admissions until a fresh journal
            // can load durable state rather than compounding an unrecorded external effect.
            storageAvailable = false
        }
        return updated.resolvedLate ? .late(updated) : .recorded(updated)
    }

    func record(forKey key: String) -> OperationRecord? {
        rows.first { $0.idempotencyKey == key }
    }

    func replayOutcome(for record: OperationRecord) -> ToolExecutionOutcome {
        switch record.state {
        case .completed:
            return .completed(completedValues[record.operationID]
                ?? Self.alreadyCompleted(record.toolName))
        case .started:
            return .outcomeUnknown(operationID: record.operationID,
                                   message: Self.alreadyInFlight(record.toolName))
        case .unknown:
            return .outcomeUnknown(operationID: record.operationID,
                                   message: Self.stillUnresolved(record.toolName))
        case .failed:
            // Not reachable through `admit`, which lets a settled failure be retried.
            return .failedBeforeExecution(reason: Self.alreadyFailed(record.toolName))
        }
    }

    // MARK: Copy (model-facing: it must not invite the retry the journal just prevented)

    static func alreadyCompleted(_ tool: String) -> String {
        "'\(tool)' was already run for this request and completed, so it was not run a second time. "
            + "Use the earlier result and do not call it again."
    }

    static func alreadyInFlight(_ tool: String) -> String {
        "'\(tool)' is already running for this request and was not started a second time. Do NOT "
            + "call it again; tell the user you're waiting on the first attempt."
    }

    static func stillUnresolved(_ tool: String) -> String {
        "'\(tool)' was already attempted for this request and whether it took effect is still "
            + "unknown, so it was not run again. Do NOT retry it; tell the user you're checking "
            + "whether the first attempt went through."
    }

    static func alreadyFailed(_ tool: String) -> String {
        "'\(tool)' already failed for this request without taking effect."
    }

    // MARK: Recovery

    /// Rows left `started` by a process that died mid-operation become `unknown`, never `failed`.
    /// The app cannot know whether the message went out before it was killed, and guessing "no" is
    /// how the message gets sent twice.
    private func recoverInterruptedOperations(at now: Date) {
        for index in rows.indices where rows[index].state == .started {
            rows[index].state = .unknown
            rows[index].updatedAt = now
            rows[index].recoveredFromRestart = true
            // The tool name is the app's own fixed vocabulary; the operation's arguments — who
            // a message was going to and what it said — are not in the row and stay out of logs.
            PrivacyLog.store(.operationJournal, .recovered,
                             detail: PrivacyToken(rows[index].toolName))
        }
    }

    // MARK: Retention

    private func prune(at now: Date) {
        rows.removeAll { row in
            let age = now.timeIntervalSince(row.updatedAt)
            guard row.state != .started else { return false }  // in flight in this process
            return age > (row.isUnresolved ? retention.unresolvedMaxAge : retention.settledMaxAge)
        }
        if rows.count > retention.maxRecords {
            // Settled rows go first: an unresolved one is the row someone may actually need.
            let overflow = rows.count - retention.maxRecords
            let droppable = rows.indices.filter { rows[$0].state.isTerminal }.suffix(overflow)
            for index in droppable.sorted(by: >) { rows.remove(at: index) }
        }
        if rows.count > retention.maxRecords {
            rows.removeLast(rows.count - retention.maxRecords)
        }
        let live = Set(rows.map(\.operationID))
        completedValues = completedValues.filter { live.contains($0.key) }
    }

    private func memoize(_ value: String, for operationID: String) {
        completedValues[operationID] = value
        guard completedValues.count > Self.memoLimit else { return }
        let keep = Set(rows.prefix(Self.memoLimit).map(\.operationID))
        completedValues = completedValues.filter { keep.contains($0.key) }
    }

    // MARK: Storage

    private func load() -> Bool {
        let data: Data?
        do {
            data = try storage.load()
        } catch {
            // Storage could not answer at all — protected data still locked, most often. That is
            // not an empty history, and it must never be written over as though it were.
            PrivacyLog.store(.operationJournal, .loadFailed, error: SafeErrorSummary(error))
            return false
        }
        guard let data else { return true }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([OperationRecord].self, from: data) {
            rows = decoded
            return true
        }

        // A process killed between records leaves a file that ends inside a row. The rows that
        // landed are recovered — losing them is how an operation gets run a second time — and the
        // damaged bytes are moved aside under their own name before anything replaces them.
        if let prefix = OperationJournalSalvage.completeRecordPrefix(of: data),
           let salvaged = try? decoder.decode([OperationRecord].self, from: prefix) {
            do {
                try storage.quarantineDamaged()
            } catch {
                PrivacyLog.store(.operationJournal, .loadFailed, error: SafeErrorSummary(error))
                return false
            }
            rows = salvaged
            quarantinedDamagedTail = true
            PrivacyLog.store(.operationJournal, .salvaged, count: salvaged.count)
            return true
        }

        // Nothing whole to recover. Do not turn an unreadable or corrupt history into an empty one
        // and overwrite its bytes: a consequential operation is safer refused until recovery is
        // explicit.
        PrivacyLog.store(.operationJournal, .loadFailed,
                         error: SafeErrorSummary(OperationJournalFault.undecodable))
        return false
    }

    @discardableResult
    private func persist() -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try storage.save(try encoder.encode(rows))
            return true
        } catch {
            PrivacyLog.store(.operationJournal, .saveFailed, error: SafeErrorSummary(error))
            return false
        }
    }

    /// The store's location, for the protection assertion in tests and for diagnostics.
    var storeURL: URL { storage.storeURL }

    /// Whether the last write applied the protection attribute without error.
    var protectionApplied: Bool { storage.protectionApplied }
}

/// Why a journal could not be read back.
enum OperationJournalFault: Error {
    /// The stored bytes are neither decodable nor salvageable. Kept, not replaced.
    case undecodable
}
