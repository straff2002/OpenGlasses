import Foundation

/// Where the activity trail lives (Plan IW P1).
///
/// One JSON file, `Application Support/Activity/activity.json`, loaded at construction and written
/// on every change. First-unlock protection — entries are written from voice turns that run with
/// the phone locked in a pocket — and excluded from backup, because the subject-erasure walk
/// reaches it and a copy in a backup is a copy an erasure cannot. Registered in `DataStoreRegistry`
/// as `activityTrail`.
///
/// Every append prunes through `ActivityRetention`: 14 days and 1000 entries, or a shorter HIPAA
/// retention while compliance mode is on. In compliance mode an entry keeps its title only — the
/// detail is dropped before it is written, never after.
@MainActor
final class ActivityStore: ObservableObject {

    static let shared = ActivityStore()

    /// First-unlock, not `.complete`: a `.complete` file refuses a locked-phone write.
    nonisolated static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication

    /// What is on disk, under a format number so a later shape can be told apart.
    private struct File: Codable {
        var version: Int
        var entries: [LossyEntry]
    }

    /// One entry that decodes, or a hole where one did not — so one bad row costs that row only.
    private struct LossyEntry: Codable {
        let entry: ActivityEntry?
        init(_ entry: ActivityEntry) { self.entry = entry }
        init(from decoder: Decoder) throws { entry = try? ActivityEntry(from: decoder) }
        func encode(to encoder: Encoder) throws { try entry?.encode(to: encoder) }
    }

    private static let formatVersion = 1

    /// Oldest first.
    @Published private(set) var entries: [ActivityEntry]

    private let fileURL: URL
    private let clock: () -> Date
    private let hipaaMode: () -> Bool
    private let hipaaRetentionDays: () -> Int?
    /// The file is there and could not be opened — protected data before the first unlock. Nothing
    /// is written over it until a later read succeeds; what is appended meanwhile is merged in then.
    private var fileUnopened = false

    init(directory: URL? = nil,
         clock: @escaping () -> Date = Date.init,
         hipaaMode: @escaping () -> Bool = { Config.hipaaMode },
         hipaaRetentionDays: @escaping () -> Int? = { Config.hipaaMode ? Config.hipaaRetentionDays : nil }) {
        let folder = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("activity.json")
        self.clock = clock
        self.hipaaMode = hipaaMode
        self.hipaaRetentionDays = hipaaRetentionDays
        switch Self.read(fileURL) {
        case .loaded(let stored):
            entries = stored
        case .absent:
            entries = []
        case .unopened:
            entries = []
            fileUnopened = true
        }
        let pruned = prune(entries)
        if pruned != entries {
            entries = pruned
            save()
        }
    }

    nonisolated static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Activity", isDirectory: true)
    }

    // MARK: - Writing

    /// Add one entry. An entry for an operation already on the trail (a redelivered call answered
    /// from the journal) settles the existing row instead of adding a second.
    func append(_ entry: ActivityEntry) {
        let stored = hipaaMode() ? Self.titleOnly(entry) : entry
        var working = entries
        if let operation = stored.refs.first(where: \.isOperation),
           let index = working.lastIndex(where: { $0.refs.contains(operation) }) {
            working[index].outcome = stored.outcome
        } else {
            working.append(stored)
        }
        entries = prune(working)
        save()
    }

    /// The journal settled an operation: the entry that refers to it takes the new outcome. Nothing
    /// happens when no entry does — a read, or an answer that arrived before its entry was written
    /// (that entry is written with the final outcome already).
    func settle(operationID: String, outcome: ActivityOutcome) {
        let ref = ActivityRef.operation(operationID)
        guard let index = entries.lastIndex(where: { $0.refs.contains(ref) }),
              entries[index].outcome != outcome else { return }
        entries[index].outcome = outcome
        save()
    }

    /// A held call came back to the wearer and was answered (Plan LE §3): every held entry still
    /// waiting under `key`, inside its lifetime, takes the answer — the same call held twice (a
    /// scheduled task retrying) is one question, answered once. Returns how many did. An answer
    /// that matches no waiting entry changes nothing.
    @discardableResult
    func resolveHold(key: String, resolution: ActivityResolution, at date: Date) -> Int {
        var answered = 0
        for index in entries.indices
        where entries[index].kind == .held && entries[index].holdKey == key
            && entries[index].isAwaitingWearer(at: date) {
            entries[index] = entries[index].resolved(resolution, at: date)
            answered += 1
        }
        if answered > 0 { save() }
        return answered
    }

    /// The wearer answered one held entry by itself — "Decline" on the check-in's row. Only a held
    /// entry still waiting can be answered.
    @discardableResult
    func resolve(entryID: UUID, as resolution: ActivityResolution, at date: Date) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entryID }),
              entries[index].kind == .held, entries[index].isAwaitingWearer else { return false }
        entries[index] = entries[index].resolved(resolution, at: date)
        save()
        return true
    }

    /// The file is there and could not be opened yet (protected data before the first unlock):
    /// what the store holds is not the whole trail, so a reader must not take it for one.
    var isUnreadable: Bool { fileUnopened }

    /// Everything — the trail's Clear button and the registry's "delete all".
    func deleteAll() {
        entries = []
        fileUnopened = false
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Remove every entry whose title or detail names `token` (a subject erasure). Returns how many
    /// went.
    @discardableResult
    func forget(matching token: String) -> Int {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return 0 }
        let kept = entries.filter { entry in
            !(entry.title.localizedCaseInsensitiveContains(needle)
              || (entry.detail?.localizedCaseInsensitiveContains(needle) ?? false))
        }
        let removed = entries.count - kept.count
        guard removed > 0 else { return 0 }
        entries = kept
        save()
        return removed
    }

    // MARK: - Reading

    /// Entries at or after `start`, oldest first.
    func entries(since start: Date) -> [ActivityEntry] {
        entries.filter { $0.at >= start }
    }

    // MARK: - Retention

    private func prune(_ list: [ActivityEntry]) -> [ActivityEntry] {
        ActivityRetention.prune(list, now: clock(),
                                horizonDays: ActivityRetention.effectiveHorizonDays(
                                    hipaaRetentionDays: hipaaRetentionDays()))
    }

    /// The entry with its detail dropped — what compliance mode keeps.
    static func titleOnly(_ entry: ActivityEntry) -> ActivityEntry {
        guard entry.detail != nil else { return entry }
        return ActivityEntry(id: entry.id, at: entry.at, kind: entry.kind, title: entry.title,
                             detail: nil, tool: entry.tool, goalID: entry.goalID,
                             stepID: entry.stepID, authorisation: entry.authorisation,
                             origin: entry.origin, outcome: entry.outcome, refs: entry.refs,
                             resolvedAt: entry.resolvedAt, resolution: entry.resolution,
                             holdKey: entry.holdKey)
    }

    // MARK: - Storage

    private enum Stored {
        case absent
        /// There, and not readable yet (protected data while locked).
        case unopened
        case loaded([ActivityEntry])
    }

    /// A file that opens but does not decode is treated as empty: the trail is a record of recent
    /// actions, and refusing every later write over one damaged file would lose more than it keeps.
    private static func read(_ url: URL) -> Stored {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url) else { return .unopened }
        guard let file = try? RecordJSONCodec.decoder().decode(File.self, from: data),
              file.version == formatVersion else { return .loaded([]) }
        return .loaded(file.entries.compactMap(\.entry))
    }

    private func save() {
        if fileUnopened {
            guard case .loaded(let stored) = Self.read(fileURL) else { return }
            fileUnopened = false
            let known = Set(entries.map(\.id))
            entries = prune(stored.filter { !known.contains($0.id) } + entries)
        }
        let file = File(version: Self.formatVersion, entries: entries.map(LossyEntry.init))
        guard let data = try? RecordJSONCodec.encoder().encode(file) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        StoreProtection.apply(Self.fileProtection, backupExcluded: true, to: fileURL)
    }
}

extension ActivityRef {
    var isOperation: Bool {
        if case .operation = self { return true }
        return false
    }
}
