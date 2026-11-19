import Foundation

/// Where the van's stock lives (Plan IH §4).
///
/// One JSON file in Application Support beside the delivery queue, loaded at construction and
/// written on every change. Registered in `DataStoreRegistry` as `vanStock`: part numbers,
/// quantities and job references, and nothing about a person — movements carry no free text. It is
/// protected, and **left in the device backup** on purpose: it is the technician's own working
/// record, and a new phone should still know what is on the truck.
///
/// A file that is there and cannot be read is refused, not half-read and not overwritten: the
/// store stays empty and unwritable until it is reset, so one bad write can never silently replace
/// a truck's worth of counts with nothing.
@MainActor
final class VanStockStore: ObservableObject {

    static let shared = VanStockStore()

    /// The protection class this store's files are written with and re-stamped to. First-unlock,
    /// not `.complete`: the store is written from voice turns that run with the phone locked in a
    /// pocket (the app keeps the `audio` background mode), and a `.complete` file refuses those
    /// writes — and its read, so a store first opened while locked would be marked unreadable.
    nonisolated static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication

    /// How long a movement is kept before it is folded into its line's opening figure. Levels are
    /// exact either way; only the history gets shorter.
    nonisolated static let historyDays = 400

    /// What is on disk: the log and which van it is, under a format number so a later shape can
    /// be told apart.
    private struct File: Codable {
        var version: Int
        var log: VanStockLog
        /// Which vehicle this is (Plan IH P5). Absent in a file written before vans had names.
        var van: VanIdentity?
    }

    /// A format 1 file: the same, with its figures in whole units (Plan ML §2).
    private struct Format1File: Decodable {
        var log: VanStockLogMigration.Format1Log
        var van: VanIdentity?
    }

    /// Just the format number, read before anything else.
    private struct Header: Decodable {
        var version: Int
    }

    /// Format 2 keeps every figure in thousandths of the line's unit (Plan ML §2). A format 1
    /// file is migrated when it is read and written back as format 2 straight away. Any other
    /// number is a shape this build does not know, and is refused rather than guessed at: an
    /// older build refuses format 2 the same way, so it can never read 4,250 mL as 4,250 litres.
    nonisolated static let formatVersion = 2

    @Published private(set) var log: VanStockLog
    /// Which vehicle the list belongs to. Nil until it has been named or taken over.
    @Published private(set) var van: VanIdentity?
    /// The file exists and could not be read. Nothing is written while this is true.
    @Published private(set) var isUnreadable: Bool

    private let fileURL: URL
    /// The list as it was before the last takeover: one generation, kept so taking over the wrong
    /// van is not the end of the right one's list.
    private let archiveURL: URL

    init(directory: URL? = nil, now: Date = Date()) {
        let folder = directory ?? DeliveryQueueStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("van-stock.json")

        archiveURL = folder.appendingPathComponent("van-stock-previous.json")
        switch Self.read(fileURL) {
        case .absent:
            log = VanStockLog()
            van = nil
            isUnreadable = false
        case .unreadable:
            log = VanStockLog()
            van = nil
            isUnreadable = true
        case .loaded(let stored, let identity, let migrated):
            isUnreadable = false
            van = identity
            let cutoff = now.addingTimeInterval(-Double(Self.historyDays) * 86_400)
            let folded = stored.compacted(before: cutoff)
            log = folded
            // A migrated file is written back in format 2 at once, so it is read the new way from
            // now on and an older build refuses it.
            if folded != stored || migrated { save() }
        }
        protectFile()
    }

    // MARK: - Changing

    /// Change the log and keep the result. Nil — and nothing changed — while the file on disk is
    /// unreadable.
    @discardableResult
    func update<Result>(_ change: (inout VanStockLog) -> Result) -> Result? {
        guard !isUnreadable else { return nil }
        var working = log
        let result = change(&working)
        if working != log {
            log = working
            save()
        }
        return result
    }

    /// Name the van, or rename it. The identifier is made once and kept, so a renamed truck is
    /// still the same truck to the next phone that takes it over.
    func nameVan(_ name: String, makeID: () -> String = { UUID().uuidString }) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isUnreadable, !cleaned.isEmpty, cleaned != van?.name else { return }
        var identity = van ?? VanIdentity(id: makeID(), name: "")
        identity.name = cleaned
        van = identity
        save()
    }

    /// Choose where the list is kept, or clear the choice back to van with nil (Plan MK §2). A
    /// list nobody has named yet is given its identifier here, with no name, so the place has a
    /// list to belong to. The profile's place is never written here: it is resolved over this.
    func setPlace(_ place: StockPlace.Kind?, makeID: () -> String = { UUID().uuidString }) {
        guard !isUnreadable, place != van?.place else { return }
        var identity = van ?? VanIdentity(id: makeID(), name: "")
        identity.place = place
        van = identity
        save()
    }

    /// Name the installed vault this list checks part numbers against, or none with nil (Plan MK
    /// §4). Kept on this phone only.
    func checkNumbers(against vaultID: String?, makeID: () -> String = { UUID().uuidString }) {
        let cleaned = vaultID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = cleaned?.isEmpty == false ? cleaned : nil
        guard !isUnreadable, value != van?.checkVaultID else { return }
        var identity = van ?? VanIdentity(id: makeID(), name: "")
        identity.checkVaultID = value
        van = identity
        save()
    }

    /// Take a van over: the list a handover describes replaces the phone's own. The list that was
    /// here is kept beside it, one generation deep, and never merged in. The workbook's van and
    /// place come across; this phone's own choice of vault to check numbers against stays (Plan MK
    /// §4).
    func replace(with log: VanStockLog, van incoming: VanIdentity?) {
        guard !isUnreadable else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.copyItem(at: fileURL, to: archiveURL)
            protect(archiveURL)
        }
        self.log = log
        self.van = VanIdentity.takenOver(incoming, keeping: van)
        save()
    }

    /// Whether there is a list from before the last takeover to go back to.
    var hasPrevious: Bool { FileManager.default.fileExists(atPath: archiveURL.path) }

    /// Go back to the list from before the last takeover. False when there is none to read. An
    /// archive kept in format 1 is migrated as it is read, and saved as the list in format 2.
    @discardableResult
    func restorePrevious() -> Bool {
        guard case .loaded(let stored, let identity, _) = Self.read(archiveURL) else { return false }
        try? FileManager.default.removeItem(at: archiveURL)
        log = stored
        van = identity
        isUnreadable = false
        save()
        return true
    }

    /// Everything, for a wipe or to start again after an unreadable file — what the registry's
    /// "delete all" column names.
    func removeAll() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: archiveURL)
        log = VanStockLog()
        van = nil
        isUnreadable = false
    }

    // MARK: - Storage

    private enum Stored {
        case absent
        case unreadable
        /// `migrated` when the file was format 1 and is held in memory as format 2.
        case loaded(VanStockLog, VanIdentity?, migrated: Bool)
    }

    private static func read(_ url: URL) -> Stored {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(Header.self, from: data) else { return .unreadable }
        switch header.version {
        case formatVersion:
            guard let file = try? decoder.decode(File.self, from: data) else { return .unreadable }
            return .loaded(file.log, file.van, migrated: false)
        case 1:
            guard let file = try? decoder.decode(Format1File.self, from: data) else { return .unreadable }
            return .loaded(VanStockLogMigration.fromFormat1(file.log), file.van, migrated: true)
        default:
            return .unreadable
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(File(version: Self.formatVersion, log: log, van: van)) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        protectFile()
    }

    /// First-unlock protection. Not excluded from backup: see the type's note.
    private func protectFile() { protect(fileURL) }

    private func protect(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: Self.fileProtection], ofItemAtPath: url.path)
    }
}
