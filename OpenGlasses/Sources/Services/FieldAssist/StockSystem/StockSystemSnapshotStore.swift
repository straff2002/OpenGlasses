import Foundation

/// The last good snapshot from each connected stock system (Plan MM §2, P2).
///
/// One JSON file per connector in `Application Support/FieldAssist/stock-system/`, outside vault
/// content, written with the first-unlock protection class and **excluded from backup**: it is the
/// business's figures, and a restored phone should pull fresh ones rather than trust old ones. A new
/// snapshot is written beside the current one and checked before it takes its place, and the one it
/// replaces is kept as `<connector>-previous.json`, so a failed or interrupted write never leaves
/// the phone with nothing. Prices are dropped on read unless enabled (Decision 9). Registered in
/// `DataStoreRegistry` as `stockSystemSnapshot`. Vendor-neutral: connector ids only.
@MainActor
final class StockSystemSnapshotStore: ObservableObject {

    /// First-unlock, like the other Field Assist stores: a pull may finish as the phone locks.
    nonisolated static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication
    nonisolated static let folderName = "stock-system"

    @Published private(set) var snapshots: [String: StockSystemSnapshot] = [:]

    let folder: URL
    private let connectorIDs: [String]

    init(directory: URL? = nil, connectorIDs: [String] = StockSystemAdapterRegistry.connectorIDs) {
        folder = (directory ?? DeliveryQueueStore.defaultDirectory()).appendingPathComponent(Self.folderName, isDirectory: true)
        self.connectorIDs = connectorIDs
        prepareFolder()
        for id in connectorIDs where StockSystemRequest.isPlainIdentifier(id) {
            // A current file that cannot be read falls back to the one it replaced.
            if let snapshot = Self.read(currentURL(id)) ?? Self.read(previousURL(id)), snapshot.source.connectorID == id {
                snapshots[id] = snapshot
            }
        }
    }

    func snapshot(for connectorID: String) -> StockSystemSnapshot? {
        snapshots[connectorID]
    }

    // MARK: - Replacing

    /// Keep `snapshot` as its connector's last good one. The new file is written and read back
    /// before it replaces the current one; the current one becomes the previous one. False, and
    /// nothing changed, when it could not be written.
    @discardableResult
    func replace(_ snapshot: StockSystemSnapshot) -> Bool {
        let id = snapshot.source.connectorID
        guard StockSystemRequest.isPlainIdentifier(id) else { return false }
        prepareFolder()
        let current = currentURL(id), previous = previousURL(id), incoming = incomingURL(id)
        let manager = FileManager.default
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            guard Self.decode(data) != nil else { return false }
            try data.write(to: incoming, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            Self.excludeFromBackup(incoming)
            if manager.fileExists(atPath: current.path) {
                try? manager.removeItem(at: previous)
                try manager.moveItem(at: current, to: previous)
            }
            do {
                try manager.moveItem(at: incoming, to: current)
            } catch {
                // Put the one that was there back, so the phone keeps its last good figures.
                if !manager.fileExists(atPath: current.path), manager.fileExists(atPath: previous.path) {
                    try? manager.moveItem(at: previous, to: current)
                }
                throw error
            }
            for url in [current, previous] where manager.fileExists(atPath: url.path) {
                try? manager.setAttributes([.protectionKey: Self.fileProtection], ofItemAtPath: url.path)
                Self.excludeFromBackup(url)
            }
        } catch {
            try? manager.removeItem(at: incoming)
            return false
        }
        snapshots[id] = snapshot
        return true
    }

    /// A `check`'s fresh lines merged into the connector's snapshot (Plan MM P3): only those lines'
    /// figures and their as-of time; the snapshot's own `asOf` stays the pull's. Written the same
    /// way as a pull. False when there is no snapshot to merge into, nothing changed, or it could
    /// not be written.
    @discardableResult
    func merge(_ fresh: StockSystemFreshLines, into connectorID: String, readAt: Date) -> Bool {
        guard let current = snapshots[connectorID], let merged = current.merging(fresh, readAt: readAt) else { return false }
        return replace(merged)
    }

    // MARK: - Retiring

    /// Remove a connector's snapshots, current and previous: Remove connection, a new key, the
    /// office route.
    func retire(_ connectorID: String) {
        snapshots[connectorID] = nil
        guard StockSystemRequest.isPlainIdentifier(connectorID) else { return }
        for url in [currentURL(connectorID), previousURL(connectorID), incomingURL(connectorID)] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Remove every connector's snapshots and the folder.
    func retireAll() {
        snapshots = [:]
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Files

    func currentURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).json") }
    func previousURL(_ id: String) -> URL { folder.appendingPathComponent("\(id)-previous.json") }
    private func incomingURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).incoming.json") }

    private func prepareFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: Self.fileProtection])
        Self.excludeFromBackup(folder)
    }

    nonisolated private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }

    nonisolated private static func read(_ url: URL) -> StockSystemSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// A stored snapshot, with prices dropped unless the policy enables them.
    nonisolated static func decode(_ data: Data) -> StockSystemSnapshot? {
        let decoder = JSONDecoder()
        decoder.userInfo[.stockSystemPricesEnabled] = StockSystemPolicy.pricesEnabledByDefault
        return try? decoder.decode(StockSystemSnapshot.self, from: data)
    }
}
