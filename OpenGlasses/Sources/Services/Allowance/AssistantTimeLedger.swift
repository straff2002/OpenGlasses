import Foundation

/// Plan NH §3 — seconds of assistant time used, per local calendar day.
///
/// One small JSON file in Application Support: day keys (`2026-11-25`) and whole seconds, nothing
/// said and nobody named. **On the phone only**: protected at first unlock, excluded from backup and
/// never written to iCloud, so it never leaves the phone. The day turns over at local midnight in
/// whatever time zone the phone is in when a second is counted. Changing the clock or reinstalling
/// can reset it, and that is accepted (decision 10): anything stronger needs an account or a server.
///
/// Registered in `DataStoreRegistry` as `assistantTime`. It is about the wearer's use of the app and
/// names nobody, so a subject erasure has nothing to find in it; `deleteAll()` clears it.
final class AssistantTimeLedger {

    /// First-unlock, not `.complete`: turns are counted while the phone is locked in a pocket (the
    /// app keeps the `audio` background mode), and a `.complete` file refuses those writes.
    static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication

    /// Days kept. Only today decides anything; the days before it are dropped on the next write.
    static let keptDays = 7

    /// The ledger's file name inside its folder.
    static let fileName = "assistant-time.json"

    private struct Contents: Codable, Equatable {
        var version = 1
        var days: [String: Int] = [:]
    }

    private var contents: Contents
    private let fileURL: URL
    private let calendar: () -> Calendar
    /// Seconds added since the last write. A Live session counts once a second; it is written at
    /// most every `writeInterval` and when it stops, not sixty times a minute.
    private var unsavedSeconds = 0
    private var lastWrite = Date.distantPast
    static let writeInterval: TimeInterval = 15

    init(directory: URL? = nil, calendar: @escaping () -> Calendar = { Calendar.autoupdatingCurrent }) {
        let folder = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent(Self.fileName)
        self.calendar = calendar
        contents = Self.read(fileURL) ?? Contents()
        protect()
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Allowance", isDirectory: true)
    }

    // MARK: - Reading

    /// The day `date` falls on, in the phone's calendar and time zone.
    func dayKey(for date: Date) -> String {
        let cal = calendar()
        let parts = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Seconds used on the local day containing `date`.
    func secondsUsed(on date: Date) -> Int {
        contents.days[dayKey(for: date)] ?? 0
    }

    // MARK: - Counting

    /// Count `seconds` against the day containing `date`. `immediately` writes now (a turn);
    /// otherwise the write waits for `writeInterval` (a Live session's tick).
    func add(_ seconds: Int, at date: Date, immediately: Bool = true) {
        guard seconds > 0 else { return }
        let key = dayKey(for: date)
        contents.days[key, default: 0] += seconds
        prune(keeping: key)
        unsavedSeconds += seconds
        if immediately || date.timeIntervalSince(lastWrite) >= Self.writeInterval || date < lastWrite {
            save(at: date)
        }
    }

    /// Write anything still unsaved.
    func flush() {
        guard unsavedSeconds > 0 else { return }
        save(at: Date())
    }

    /// Everything, for a wipe — what the registry's "delete all" column names.
    func deleteAll() {
        contents = Contents()
        unsavedSeconds = 0
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Where the file is, for the attribute-truth test.
    var fileLocation: URL { fileURL }

    // MARK: - Storage

    private func prune(keeping today: String) {
        guard contents.days.count > Self.keptDays else { return }
        let kept = contents.days.keys.sorted().suffix(Self.keptDays)
        let keep = Set(kept).union([today])
        contents.days = contents.days.filter { keep.contains($0.key) }
    }

    private static func read(_ url: URL) -> Contents? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Contents.self, from: data)
    }

    private func save(at date: Date) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(contents) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        unsavedSeconds = 0
        lastWrite = date
        protect()
    }

    /// First-unlock protection and no backup: the count belongs to this phone, and a restored copy
    /// would carry it to another one.
    private func protect() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.setAttributes([.protectionKey: Self.fileProtection], ofItemAtPath: fileURL.path)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
