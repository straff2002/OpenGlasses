import Foundation

/// One meeting whose notes the model still owes (Plan MX P6): the transcript it needs, and the
/// saved note the notes will complete.
struct OwedMeetingNotes: Codable, Equatable, Identifiable, Sendable {

    enum State: String, Codable, Sendable {
        /// Being written now. Found at launch, it is a write the app did not live to finish.
        case writing
        /// Waiting for the model to be able to run.
        case owed
    }

    struct Line: Codable, Equatable, Sendable {
        /// What was said, a speaker's name before it on a diarized line.
        let text: String
        let at: Date
    }

    /// The saved note's meeting id.
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let lines: [Line]
    /// Lines the caption session no longer held when the summary was made.
    var droppedLines: Int
    var state: State
    var reason: MeetingNotesOweReason
    var attempts: Int

    init(id: UUID, startedAt: Date, endedAt: Date, lines: [Line], droppedLines: Int = 0,
         state: State, reason: MeetingNotesOweReason, attempts: Int = 0) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lines = lines
        self.droppedLines = droppedLines
        self.state = state
        self.reason = reason
        self.attempts = attempts
    }

    /// Whether any line names `token` (the subject erasure's match: case- and diacritic-blind).
    func mentions(_ token: String) -> Bool {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return lines.contains { $0.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// Where owed meeting notes wait (Plan MX P6): one JSON file in Application Support/MeetingNotes,
/// holding at most three meetings.
///
/// **Only where a kept session may be written.** `hold` writes nothing unless Keep caption
/// sessions is on and Medical Compliance mode is off (`MeetingNotesOwedPolicy`), and the caller
/// asks only for a summary saved as a note. Every open of the file (`pending`, `prune`) applies
/// the same rule again: with the switch off or the mode on, everything goes. A record goes seven
/// days after its meeting began, and after three failed attempts.
///
/// **Other people's speech.** Registered in `DataStoreRegistry` as `owedMeetingNotes`: third-party
/// data, protected until first unlock (a meeting can end with the phone locked), out of backup,
/// walked by the subject erasure (a meeting that mentions the subject goes whole). Nothing reads
/// it but `MeetingNotesService`, which hands it to the notes call and settles it.
@MainActor
final class MeetingNotesOwedStore {

    static let shared = MeetingNotesOwedStore()

    nonisolated static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication
    nonisolated static let fileName = "owed-meeting-notes.json"

    private let directory: URL
    private let now: () -> Date
    private let isEnabled: () -> Bool
    private let hipaaMode: () -> Bool

    nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MeetingNotes", isDirectory: true)
    }

    /// A store over `directory`. Opening it turns a record left `writing` by the last run into
    /// one owed for the next foreground, since no write of this process can be in flight yet.
    init(directory: URL? = nil,
         now: @escaping () -> Date = Date.init,
         isEnabled: @escaping () -> Bool = { Config.keepCaptionSessions },
         hipaaMode: @escaping () -> Bool = { Config.hipaaMode }) {
        self.directory = directory ?? Self.defaultDirectory()
        self.now = now
        self.isEnabled = isEnabled
        self.hipaaMode = hipaaMode
        recoverInterrupted()
    }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    // MARK: - Reading

    /// The records still owed or being written, oldest meeting first, after the rule is applied.
    var pending: [OwedMeetingNotes] {
        prune()
        return read() ?? []
    }

    func record(id: UUID) -> OwedMeetingNotes? { pending.first { $0.id == id } }

    // MARK: - Writing

    /// Hold `record`, replacing one with its id. False when the rule refuses or the write fails.
    @discardableResult
    func hold(_ record: OwedMeetingNotes) -> Bool {
        guard MeetingNotesOwedPolicy.mayHold(saving: true, keepCaptionSessions: isEnabled(),
                                             medicalCompliance: hipaaMode()) else {
            prune()
            return false
        }
        var records = (read() ?? []).filter { $0.id != record.id }
        records.append(record)
        records.sort { $0.startedAt < $1.startedAt }
        if records.count > MeetingNotesOwedPolicy.capacity {
            records.removeFirst(records.count - MeetingNotesOwedPolicy.capacity)
        }
        return write(records)
    }

    /// The record with `id`, changed by `change`. Nothing when there is none.
    func update(id: UUID, _ change: (inout OwedMeetingNotes) -> Void) {
        guard var records = read(), let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        write(records)
    }

    /// The notes were written (or will not be): the record goes.
    func settle(id: UUID) {
        guard let records = read(), records.contains(where: { $0.id == id }) else { return }
        write(records.filter { $0.id != id })
    }

    // MARK: - Removing

    /// Apply the rule: everything goes with the switch off or the mode on, a record seven days
    /// after its meeting began or after three failed attempts. Returns how many went.
    @discardableResult
    func prune() -> Int {
        guard let records = read() else { return 0 }
        let kept = records.filter {
            MeetingNotesOwedPolicy.disposition(startedAt: $0.startedAt, attempts: $0.attempts, now: now(),
                                               keepCaptionSessions: isEnabled(),
                                               medicalCompliance: hipaaMode()) == .keep
        }
        let removed = records.count - kept.count
        guard removed > 0 else { return 0 }
        write(kept)
        PrivacyLog.store(.meetingNotes, .evicted, count: removed)
        return removed
    }

    /// What the registry's "delete all" names.
    func deleteAll() {
        let count = read()?.count ?? 0
        try? FileManager.default.removeItem(at: directory)
        if count > 0 { PrivacyLog.store(.meetingNotes, .cleared, count: count) }
    }

    /// The subject erasure's call: every owed meeting whose words mention `token` goes whole.
    @discardableResult
    func deleteMatching(_ token: String) -> Int {
        guard let records = read() else { return 0 }
        let kept = records.filter { !$0.mentions(token) }
        let removed = records.count - kept.count
        if removed > 0 { write(kept) }
        return removed
    }

    /// A record left `writing` by an earlier run is owed now.
    func recoverInterrupted() {
        guard let records = read(), records.contains(where: { $0.state == .writing }) else { return }
        let recovered = records.map { record -> OwedMeetingNotes in
            guard record.state == .writing else { return record }
            var owed = record
            owed.state = .owed
            owed.reason = .interrupted
            return owed
        }
        if write(recovered) {
            PrivacyLog.store(.meetingNotes, .recovered,
                             count: records.filter { $0.state == .writing }.count)
        }
    }

    // MARK: - File

    /// Nil when there is no file, or it cannot be read yet (the phone has not been unlocked since
    /// it started) — left where it is for the next open. An unreadable file is removed.
    private func read() -> [OwedMeetingNotes]? {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode([OwedMeetingNotes].self, from: data)
        } catch {
            PrivacyLog.store(.meetingNotes, .loadFailed, error: SafeErrorSummary(error))
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }

    @discardableResult
    private func write(_ records: [OwedMeetingNotes]) -> Bool {
        guard !records.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return true
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            protect(directory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            protect(fileURL)
            return true
        } catch {
            PrivacyLog.store(.meetingNotes, .saveFailed, error: SafeErrorSummary(error))
            return false
        }
    }

    /// First-unlock protection and no backup, on the folder and the file: a backup is a copy
    /// neither the seven days nor an erasure can reach.
    private func protect(_ url: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        try? manager.setAttributes([.protectionKey: Self.fileProtection], ofItemAtPath: url.path)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
}
