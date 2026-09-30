import Foundation

/// App-group hand-off for teleprompter scripts shared into OpenGlasses from the iOS share
/// sheet. The Share Extension runs in a separate process and can't touch the app's
/// Documents, so it appends pending scripts to a JSON file in the shared app-group
/// container; the main app drains them into `TeleprompterScriptStore` on launch/foreground.
///
/// Compiled into BOTH the app and the extension target. The pure, side-effect-free helpers
/// plus the `testContainerURL` seam make it unit-testable without the real container.
enum SharedTeleprompterInbox {
    /// **Storage key, not a product name.** The shared App Group. A literal rather than
    /// `SharedAppState.appGroup` because the Share Extension does not compile that file.
    /// **Never change this value** (including in a rename): scripts shared from other apps would be
    /// written where the app never looks. Pinned by `StorageIdentifierGuardTests`.
    static let appGroupID = "group.com.openglasses.app"
    private static let fileName = "teleprompter_inbox.json"

    /// Test seam: when set, used instead of the app-group container.
    static var testContainerURL: URL?

    struct PendingScript: Codable, Equatable {
        var title: String
        var text: String
        var receivedAt: Date

        init(title: String, text: String, receivedAt: Date = Date()) {
            self.title = title
            self.text = text
            self.receivedAt = receivedAt
        }
    }

    private static var fileURL: URL? {
        let container = testContainerURL
            ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        return container?.appendingPathComponent(fileName)
    }

    /// Append a shared script to the inbox (called from the Share Extension). The read-modify-write
    /// is file-coordinated: the extension and the main app run in separate processes, and an
    /// uncoordinated append racing the app's drain used to be silently lost.
    static func append(title: String, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let url = fileURL else { return }
        coordinateWrite(at: url) { url in
            var pending = load(at: url)
            pending.append(PendingScript(title: title.trimmingCharacters(in: .whitespacesAndNewlines), text: clean))
            guard let data = try? JSONEncoder().encode(pending) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Read all pending scripts without consuming them (called from the main app). Pair with
    /// `remove(_:)` after the app has durably saved them — deleting the inbox before the save
    /// commits used to lose shares from both places.
    static func peek() -> [PendingScript] {
        guard let url = fileURL else { return [] }
        var result: [PendingScript] = []
        coordinateRead(at: url) { url in
            result = load(at: url)
        }
        return result
    }

    /// Remove exactly the given scripts from the inbox (coordinated), leaving anything appended
    /// since the corresponding `peek()` in place.
    static func remove(_ items: [PendingScript]) {
        guard !items.isEmpty, let url = fileURL else { return }
        coordinateWrite(at: url) { url in
            var pending = load(at: url)
            for item in items {
                if let idx = pending.firstIndex(of: item) { pending.remove(at: idx) }
            }
            if pending.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else if let data = try? JSONEncoder().encode(pending) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Return and clear all pending scripts. Prefer `peek()` + `remove(_:)` when the caller
    /// persists the result — this variant consumes unconditionally.
    static func drain() -> [PendingScript] {
        let pending = peek()
        remove(pending)
        return pending
    }

    private static func load(at url: URL) -> [PendingScript] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([PendingScript].self, from: data) else { return [] }
        return decoded
    }

    private static func coordinateRead(at url: URL, _ body: (URL) -> Void) {
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(readingItemAt: url, options: [], error: &coordinationError) { body($0) }
        if coordinationError != nil { body(url) }  // fall back to direct access rather than dropping data
    }

    private static func coordinateWrite(at url: URL, _ body: (URL) -> Void) {
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(writingItemAt: url, options: [], error: &coordinationError) { body($0) }
        if coordinationError != nil { body(url) }
    }
}
