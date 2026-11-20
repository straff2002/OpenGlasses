import Foundation

/// One part noted as used where a business's own system holds the count (Plan MM §6), as it waits
/// on the phone for a person to confirm it.
struct StagedStockUseEntry: Codable, Equatable, Identifiable, Sendable {

    /// What the line waits on: the open job, or, at premises with no job open, the day's list.
    enum Scope: Hashable, Sendable, Codable {
        /// The job's session id.
        case job(String)
        /// The day, `yyyy-MM-dd` in the phone's calendar (`StagedStockUseStore.dayKey`).
        case day(String)

        /// "job:<id>" or "day:2026-11-20", as stored.
        var key: String {
            switch self {
            case .job(let id): return "job:\(id)"
            case .day(let day): return "day:\(day)"
            }
        }

        init?(key: String) {
            if key.hasPrefix("job:"), key.count > 4 { self = .job(String(key.dropFirst(4))); return }
            if key.hasPrefix("day:"), key.count > 4 { self = .day(String(key.dropFirst(4))); return }
            return nil
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let scope = Scope(key: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown scope"))
            }
            self = scope
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(key)
        }
    }

    let scope: Scope
    /// The number people use for the job, when it has one.
    let jobReference: String?
    /// The system the line is for.
    let connectorID: String
    /// The system's location it came from.
    let locationID: String
    let use: StagedStockUse
    /// Why it left stock, when it was not used on the job: written off for a reason the system
    /// keeps. Nil for a part used.
    let reason: StockAdjustmentReason?
    let stagedAt: Date
    /// The call that noted it, so one undo takes back everything one call noted.
    let call: String

    var id: String { use.id }
}

/// The parts noted on the phone for a business's own stock system and not yet confirmed (Plan MM
/// P3): per job, and per day for premises with no job open. P4 reads them per job and per day to
/// confirm and send them; until then nothing here leaves the phone.
///
/// One JSON file beside the delivery queue, outside the snapshot's folder so retiring a snapshot
/// never takes a staged line with it. First-unlock protection (a use is said with the phone in a
/// pocket), and excluded from backup: these are writes waiting to go to the business's system, and
/// a restored copy could send them twice. A file that is there and cannot be read is never
/// overwritten: nothing is staged until it is cleared. Registered in `DataStoreRegistry` as
/// `stagedStockUse`. Vendor-neutral: connector ids only.
@MainActor
final class StagedStockUseStore: ObservableObject {

    nonisolated static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication
    nonisolated static let fileName = "stock-system-staged.json"
    nonisolated static let formatVersion = 1

    private struct File: Codable {
        var version: Int
        var entries: [StagedStockUseEntry]
    }

    private struct Header: Decodable {
        var version: Int
    }

    @Published private(set) var entries: [StagedStockUseEntry] = []
    /// The file exists and could not be read. Nothing is staged while this is true.
    @Published private(set) var isUnreadable = false

    let fileURL: URL

    init(directory: URL? = nil) {
        let folder = directory ?? DeliveryQueueStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent(Self.fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let header = try? decoder.decode(Header.self, from: data), header.version == Self.formatVersion,
              let file = try? decoder.decode(File.self, from: data) else {
            isUnreadable = true
            return
        }
        entries = file.entries
    }

    // MARK: - Reading

    /// The lines noted on a job, oldest first.
    func entries(forJob sessionID: String) -> [StagedStockUseEntry] {
        entries.filter { $0.scope == .job(sessionID) }
    }

    /// The lines noted on a day's list, oldest first.
    func entries(forDay day: String) -> [StagedStockUseEntry] {
        entries.filter { $0.scope == .day(day) }
    }

    func entries(in scope: StagedStockUseEntry.Scope) -> [StagedStockUseEntry] {
        entries.filter { $0.scope == scope }
    }

    /// The day a premises list is kept under: `yyyy-MM-dd` in `calendar`.
    nonisolated static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Changing

    /// Note `added`. False, and nothing noted, when the file cannot be read or written.
    @discardableResult
    func stage(_ added: [StagedStockUseEntry]) -> Bool {
        guard !isUnreadable, !added.isEmpty else { return false }
        let known = Set(entries.map(\.id))
        let fresh = added.filter { !known.contains($0.id) }
        guard save(entries + fresh) else { return false }
        entries += fresh
        return true
    }

    /// Take back what the most recent call in `scope` noted. Nil when there is nothing there.
    @discardableResult
    func undoLastCall(in scope: StagedStockUseEntry.Scope) -> [StagedStockUseEntry]? {
        guard !isUnreadable, let last = entries.last(where: { $0.scope == scope }) else { return nil }
        let taken = entries.filter { $0.scope == scope && $0.call == last.call }
        let kept = entries.filter { !($0.scope == scope && $0.call == last.call) }
        guard save(kept) else { return nil }
        entries = kept
        return taken
    }

    /// Take back the lines with these ids.
    @discardableResult
    func remove(ids: Set<String>) -> Bool {
        guard !isUnreadable else { return false }
        let kept = entries.filter { !ids.contains($0.id) }
        guard kept.count != entries.count else { return true }
        guard save(kept) else { return false }
        entries = kept
        return true
    }

    /// Everything, for a wipe and for leaving the organisation; also clears a file that could not
    /// be read.
    func removeAll() {
        try? FileManager.default.removeItem(at: fileURL)
        entries = []
        isUnreadable = false
    }

    // MARK: - Storage

    private func save(_ next: [StagedStockUseEntry]) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(File(version: Self.formatVersion, entries: next))
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try? FileManager.default.setAttributes([.protectionKey: Self.fileProtection], ofItemAtPath: fileURL.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = fileURL
            try? target.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }
}
