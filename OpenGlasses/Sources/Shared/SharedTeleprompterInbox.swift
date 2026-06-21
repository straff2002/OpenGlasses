import Foundation

/// App-group hand-off for teleprompter scripts shared into OpenGlasses from the iOS share
/// sheet. The Share Extension runs in a separate process and can't touch the app's
/// Documents, so it appends pending scripts to a JSON file in the shared app-group
/// container; the main app drains them into `TeleprompterScriptStore` on launch/foreground.
///
/// Compiled into BOTH the app and the extension target. The pure, side-effect-free helpers
/// plus the `testContainerURL` seam make it unit-testable without the real container.
enum SharedTeleprompterInbox {
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

    /// Append a shared script to the inbox (called from the Share Extension).
    static func append(title: String, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let url = fileURL else { return }
        var pending = load()
        pending.append(PendingScript(title: title.trimmingCharacters(in: .whitespacesAndNewlines), text: clean))
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Return and clear all pending scripts (called from the main app).
    static func drain() -> [PendingScript] {
        let pending = load()
        guard !pending.isEmpty, let url = fileURL else { return [] }
        try? FileManager.default.removeItem(at: url)
        return pending
    }

    private static func load() -> [PendingScript] {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([PendingScript].self, from: data) else { return [] }
        return decoded
    }
}
