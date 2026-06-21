import Foundation
import Combine

/// One saved teleprompter script (title + raw text). Parsed into a `TeleprompterScript`
/// only when started, so the raw text stays editable.
struct SavedScript: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var text: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String, text: String,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// First non-empty line, trimmed and clipped — used when no title is supplied.
    static func deriveTitle(from text: String) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let clipped = String(firstLine.prefix(40)).trimmingCharacters(in: .whitespaces)
        return clipped.isEmpty ? "Script" : clipped
    }
}

/// Persists saved teleprompter scripts as JSON in the app's Documents directory. The
/// storage directory is injectable so tests run against a temp directory rather than the
/// real Documents folder. Mirrors the simple JSON-file store pattern used elsewhere.
@MainActor
final class TeleprompterScriptStore: ObservableObject {
    @Published private(set) var scripts: [SavedScript] = []

    private let fileURL: URL

    init(directory: URL? = nil) {
        let dir = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = dir.appendingPathComponent("teleprompter_scripts.json")
        load()
        importPendingShares()
    }

    // MARK: - Mutations

    /// Save a new script (newest first) and persist. Returns the stored value.
    @discardableResult
    func add(title: String, text: String) -> SavedScript {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = SavedScript(title: cleanTitle.isEmpty ? SavedScript.deriveTitle(from: text) : cleanTitle,
                                 text: text)
        scripts.insert(script, at: 0)
        save()
        return script
    }

    /// Replace an existing script's content (matched by id) and bump `updatedAt`.
    func update(id: UUID, title: String, text: String) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        scripts[index].text = text
        scripts[index].updatedAt = Date()
        save()
    }

    func delete(id: UUID) {
        scripts.removeAll { $0.id == id }
        save()
    }

    func delete(at offsets: IndexSet) {
        scripts.remove(atOffsets: offsets)
        save()
    }

    /// Drain any scripts shared in via the Share Extension (PR B) and save them (newest
    /// first). Called on init and on app foreground. Returns the number imported.
    @discardableResult
    func importPendingShares() -> Int {
        let pending = SharedTeleprompterInbox.drain()
        guard !pending.isEmpty else { return 0 }
        for item in pending {
            let title = item.title.isEmpty ? SavedScript.deriveTitle(from: item.text) : item.title
            scripts.insert(SavedScript(title: title, text: item.text), at: 0)
        }
        save()
        return pending.count
    }

    // MARK: - Lookup

    func script(withID id: UUID) -> SavedScript? {
        scripts.first { $0.id == id }
    }

    /// Find a saved script by title (case-insensitive, trimmed) — used by the tool/voice path.
    func script(named name: String) -> SavedScript? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return scripts.first { $0.title.lowercased() == needle }
            ?? scripts.first { $0.title.lowercased().contains(needle) }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SavedScript].self, from: data) else { return }
        scripts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(scripts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
