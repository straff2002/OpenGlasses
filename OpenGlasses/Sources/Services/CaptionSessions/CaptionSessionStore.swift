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

    /// Write a session that has just stopped, if the wearer asked for sessions to be kept.
    @discardableResult
    func keep(_ session: CaptionSession) -> KeepOutcome {
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
        for url in files() {
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
