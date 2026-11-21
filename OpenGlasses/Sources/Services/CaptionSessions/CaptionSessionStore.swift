import Foundation
import Combine

/// Where kept caption sessions live (Plan KP §7, P5): one JSON file per session in
/// Application Support/CaptionSessions, named by when the session began.
///
/// **Only when the wearer asked.** `keep(_:)` writes nothing unless **Keep caption sessions** is on
/// (off by default) and never in Medical Compliance mode, whatever the switch says. Each session
/// stays seven days from when it began: `pruneExpired()` runs when the store opens (at launch), on
/// every write and when the list is shown, and works from the file names, so it removes an old
/// session even while the phone is locked and its words cannot be read. **Delete all** clears the
/// folder.
///
/// **Other people's speech, held apart.** Registered in `DataStoreRegistry` as `captionSessions`:
/// third-party data, protected first-unlock (captions can stop with the phone locked), excluded
/// from backup, and walked by the subject erasure (a session that mentions the subject goes
/// whole). Nothing feeds a session to a model, to memory, to `BrainStore`, to search or to
/// Spotlight; `CaptionSessionIsolationTests` scrapes the sources to hold that. It leaves the
/// phone only through the share sheet, when the wearer presses Share.
///
/// **A checkpoint while one runs.** Under the same switch and the same Medical Compliance refusal,
/// the session in progress is written every 30 seconds and when the app goes to the background,
/// to one `caption-checkpoint.json` beside the kept sessions, replacing the last, with the same
/// protection and backup exclusion. A session that ends is kept the ordinary way and its
/// checkpoint goes. A checkpoint still there when the store opens is a session the app did not
/// live to finish (killed or crashed): it is kept as a session ending at its last line, or
/// deleted if the switch is now off, Medical Compliance mode is on, or it began seven days ago.
/// Nothing reads it but this store; it is under the same folder, the same Delete all and the
/// same subject erasure.
@MainActor
final class CaptionSessionStore: ObservableObject {

    static let shared = CaptionSessionStore()

    /// Seven days, counted from when the session began (decision 7).
    nonisolated static let retentionDays = 7

    nonisolated static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication

    /// Newest first.
    @Published private(set) var sessions: [CaptionSession] = []

    private let directory: URL
    private let now: () -> Date
    private let isEnabled: () -> Bool
    private let hipaaMode: () -> Bool

    nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CaptionSessions", isDirectory: true)
    }

    init(directory: URL? = nil,
         now: @escaping () -> Date = Date.init,
         isEnabled: @escaping () -> Bool = { Config.keepCaptionSessions },
         hipaaMode: @escaping () -> Bool = { Config.hipaaMode }) {
        self.directory = directory ?? Self.defaultDirectory()
        self.now = now
        self.isEnabled = isEnabled
        self.hipaaMode = hipaaMode
        pruneExpired()
        recoverCheckpoint()
        reload()
    }

    // MARK: - Keeping

    enum KeepOutcome: Equatable {
        case kept
        /// **Keep caption sessions** is off.
        case settingOff
        /// Medical Compliance mode is on.
        case complianceMode
        /// Nothing was said.
        case empty
        case couldNotSave
    }

    /// Write a session that has just stopped, if the wearer asked for sessions to be kept. Its
    /// checkpoint goes either way, except when the write failed: then the checkpoint is what is
    /// left, and the next launch keeps it.
    @discardableResult
    func keep(_ session: CaptionSession) -> KeepOutcome {
        let outcome = write(session)
        if outcome != .couldNotSave { removeCheckpoint() }
        return outcome
    }

    private func write(_ session: CaptionSession) -> KeepOutcome {
        guard !hipaaMode() else { return .complianceMode }
        guard isEnabled() else { return .settingOff }
        guard !session.turns.isEmpty else { return .empty }
        pruneExpired()
        let url = freshURL(for: session.startedAt)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            protect(directory)
            let data = try Self.encoder().encode(session)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            protect(url)
        } catch {
            PrivacyLog.store(.captionSessions, .saveFailed, error: SafeErrorSummary(error))
            return .couldNotSave
        }
        reload()
        PrivacyLog.store(.captionSessions, .recordWritten, count: session.turns.count)
        return .kept
    }

    // MARK: - Checkpoint

    nonisolated static let checkpointFileName = "caption-checkpoint.json"

    private var checkpointURL: URL { directory.appendingPathComponent(Self.checkpointFileName) }

    /// Whether a checkpoint is on disk now. For tests and the attribute-truth check.
    var hasCheckpoint: Bool { FileManager.default.fileExists(atPath: checkpointURL.path) }

    /// The session in progress, written over the last checkpoint, under the switch and never in
    /// Medical Compliance mode. Nil, the switch off or the mode on: any checkpoint goes, and
    /// nothing is written.
    @discardableResult
    func checkpoint(_ session: CaptionSession?) -> KeepOutcome {
        guard !hipaaMode() else { removeCheckpoint(); return .complianceMode }
        guard isEnabled() else { removeCheckpoint(); return .settingOff }
        guard let session, !session.turns.isEmpty else { removeCheckpoint(); return .empty }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            protect(directory)
            let data = try Self.encoder().encode(session)
            try data.write(to: checkpointURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            protect(checkpointURL)
        } catch {
            PrivacyLog.store(.captionSessions, .saveFailed, detail: PrivacyToken("checkpoint"),
                             error: SafeErrorSummary(error))
            return .couldNotSave
        }
        return .kept
    }

    /// A checkpoint left by a session the app did not live to finish, kept as a session ending at
    /// its last line (once, however many times the store opens). Deleted instead when the switch
    /// is off, Medical Compliance mode is on, it began seven days ago, or it cannot be decoded.
    /// Left alone only when it cannot be read yet (the phone has not been unlocked since it
    /// started), for the next open.
    @discardableResult
    func recoverCheckpoint() -> KeepOutcome? {
        guard hasCheckpoint else { return nil }
        guard !hipaaMode() else { removeCheckpoint(); return .complianceMode }
        guard isEnabled() else { removeCheckpoint(); return .settingOff }
        guard let data = try? Data(contentsOf: checkpointURL) else { return nil }
        guard let saved = try? Self.decoder().decode(CaptionSession.self, from: data),
              let last = saved.turns.last else {
            removeCheckpoint()
            return .empty
        }
        let cutoff = now().addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        // Already kept (the app stopped between writing the session and removing its checkpoint),
        // or too old to keep: the checkpoint simply goes.
        if saved.startedAt <= cutoff || files().contains(where: { read($0)?.id == saved.id }) {
            removeCheckpoint()
            return .empty
        }
        let finished = CaptionSession(id: saved.id, startedAt: saved.startedAt,
                                      endedAt: max(saved.startedAt, last.at), turns: saved.turns)
        let outcome = keep(finished)
        if outcome == .kept {
            PrivacyLog.store(.captionSessions, .recovered, count: finished.turns.count)
        }
        return outcome
    }

    private func removeCheckpoint() {
        guard hasCheckpoint else { return }
        try? FileManager.default.removeItem(at: checkpointURL)
    }

    // MARK: - Removing

    /// Every session that began seven days ago or more. Returns how many went.
    @discardableResult
    func pruneExpired() -> Int {
        let cutoff = now().addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        var removed = 0
        for url in files() {
            guard let began = Self.startDate(fromFileName: url.lastPathComponent) ?? read(url)?.startedAt,
                  began <= cutoff else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        if removed > 0 {
            sessions.removeAll { $0.startedAt <= cutoff }
            PrivacyLog.store(.captionSessions, .evicted, count: removed)
        }
        return removed
    }

    /// The wearer's delete of one session.
    func delete(id: UUID) {
        for url in files() where read(url)?.id == id {
            try? FileManager.default.removeItem(at: url)
        }
        sessions.removeAll { $0.id == id }
    }

    /// **Delete all**, and what the registry's "delete all" column names.
    func deleteAll() {
        let count = files().count
        try? FileManager.default.removeItem(at: directory)
        sessions = []
        if count > 0 { PrivacyLog.store(.captionSessions, .cleared, count: count) }
    }

    /// The subject erasure's call: every session whose words or speaker names mention `token` goes
    /// whole. A transcript with one person's lines cut out of it reads as a different conversation.
    @discardableResult
    func deleteMatching(_ token: String) -> Int {
        var removed = 0
        for url in files() + (hasCheckpoint ? [checkpointURL] : []) {
            guard let session = read(url), session.mentions(token) else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        if removed > 0 { reload() }
        return removed
    }

    // MARK: - Reading

    func session(id: UUID) -> CaptionSession? { sessions.first { $0.id == id } }

    /// Read the folder again, newest first. A file that cannot be read (the phone has not been
    /// unlocked since it started) is left where it is and not listed.
    func reload() {
        sessions = files().compactMap(read).sorted { $0.startedAt > $1.startedAt }
    }

    /// Where a kept session is filed, for the attribute-truth test.
    func fileURL(for session: CaptionSession) -> URL? {
        files().first { read($0)?.id == session.id }
    }

    // MARK: - Files

    nonisolated private static let fileNamePrefix = "caption-session-"

    /// `caption-session-20261107T083000.123Z.json`: when the session began, in UTC.
    nonisolated static func fileName(startedAt: Date, suffix: Int = 0) -> String {
        let stamp = stampFormatter().string(from: startedAt)
        return fileNamePrefix + stamp + (suffix > 0 ? "-\(suffix)" : "") + ".json"
    }

    nonisolated static func startDate(fromFileName name: String) -> Date? {
        guard name.hasPrefix(fileNamePrefix), name.hasSuffix(".json") else { return nil }
        let stamp = name.dropFirst(fileNamePrefix.count).prefix(20)
        return stampFormatter().date(from: String(stamp))
    }

    nonisolated private static func stampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter
    }

    private func freshURL(for startedAt: Date) -> URL {
        var suffix = 0
        while true {
            let url = directory.appendingPathComponent(Self.fileName(startedAt: startedAt, suffix: suffix))
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            suffix += 1
        }
    }

    private func files() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(Self.fileNamePrefix) && $0.hasSuffix(".json") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    private func read(_ url: URL) -> CaptionSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try Self.decoder().decode(CaptionSession.self, from: data)
        } catch {
            PrivacyLog.store(.captionSessions, .loadFailed, error: SafeErrorSummary(error))
            return nil
        }
    }

    private static func encoder() -> JSONEncoder {
        // Dates as the default number: exact to the millisecond, so a session reads back as it was.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// First-unlock protection and no backup, on the folder and on each file: a backup is a copy
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
