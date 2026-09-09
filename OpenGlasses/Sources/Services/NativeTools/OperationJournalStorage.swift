import Foundation

/// Persistence seam for the operation journal (roadmap W05.5).
///
/// `ProtectedOperationJournal` wrote through `FileManager` directly, so the failures that decide
/// whether a consequential tool call may run — a full disk, protected data still locked, a
/// process killed between records — could not be exercised. Production behaviour is unchanged:
/// ``FileOperationJournalStorage`` is the same protected file, written atomically.
///
/// **Writes are all-or-nothing, per write and therefore per record.** The journal serialises its
/// whole row set and hands it over in one call; the file store commits it with a write-temp-then-
/// rename, so a failure part-way through leaves the previous journal byte-identical and no reader
/// ever observes a half-written row. Recovery from a torn file is still implemented, because the
/// guarantee is ours to make and a device can still lose power inside the rename's own fsync.
protocol OperationJournalStorage: AnyObject {
    /// Previously persisted bytes, or nil when nothing has been stored yet. Throws when storage
    /// cannot answer — a locked device, a directory that cannot be made — which is different from
    /// "there is nothing there".
    func load() throws -> Data?

    /// Replace the stored journal. All-or-nothing: on throw the previous bytes must remain.
    func save(_ data: Data) throws

    /// Move bytes that will not decode aside, under their own name, so recovery does not destroy
    /// the only record of what the dead process had been doing.
    func quarantineDamaged() throws

    /// Where the journal lives, for the protection assertion in tests and for diagnostics.
    var storeURL: URL { get }

    /// Whether the last write applied the protection attribute without error. The simulator
    /// accepts the attribute and then reports none back, so this — not a read-back — is what a
    /// headless test can check.
    var protectionApplied: Bool { get }
}

/// The production store: one protected JSON file in Application Support.
///
/// Protected with `completeUntilFirstUserAuthentication` rather than `complete`: the journal has
/// to be readable at launch, which is when a process that died mid-operation is discovered, and a
/// locked device would otherwise hide exactly the rows that matter.
final class FileOperationJournalStorage: OperationJournalStorage {

    let directory: URL
    let storeURL: URL
    private(set) var protectionApplied = false

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        self.storeURL = self.directory.appendingPathComponent("operations.json")
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("OperationJournal", isDirectory: true)
    }

    func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return nil }
        return try Data(contentsOf: storeURL)
    }

    func save(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: ProtectedOperationJournal.fileProtection])
        try data.write(to: storeURL, options: .atomic)
        // An atomic write replaces the inode, so the attribute is re-applied every time rather
        // than set once at creation.
        try FileManager.default.setAttributes(
            [.protectionKey: ProtectedOperationJournal.fileProtection],
            ofItemAtPath: storeURL.path)
        protectionApplied = true
        var url = storeURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    func quarantineDamaged() throws {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        let stamp = String(Int(Date().timeIntervalSince1970))
        let damaged = directory.appendingPathComponent("operations.damaged-\(stamp).json")
        try FileManager.default.moveItem(at: storeURL, to: damaged)
    }
}

/// Recovery of the complete records from a journal whose tail did not survive.
enum OperationJournalSalvage {

    /// The longest prefix of `data` that is a complete JSON array of complete records, or nil when
    /// nothing whole can be recovered.
    ///
    /// A killed process leaves a file that ends in the middle of a row. Decoding it whole fails,
    /// and treating that as "no history" is how an operation gets run twice — so the rows that did
    /// land are recovered and the incomplete tail is dropped, rather than the file being read as
    /// either complete or empty.
    static func completeRecordPrefix(of data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard let open = bytes.firstIndex(of: UInt8(ascii: "[")) else { return nil }
        guard bytes[..<open].allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D })
        else { return nil }

        var depth = 1
        var inString = false
        var escaped = false
        var lastCompleteRecordEnd: Int?

        for index in (open + 1)..<bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if depth == 1 && byte == UInt8(ascii: "}") { lastCompleteRecordEnd = index }
                if depth == 0 { return nil }  // the array closed: the file was not truncated
            default: break
            }
        }

        guard let end = lastCompleteRecordEnd else { return nil }
        var recovered = Data(bytes[...end])
        recovered.append(UInt8(ascii: "]"))
        return recovered
    }
}
