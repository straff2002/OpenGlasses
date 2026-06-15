import Foundation
import Intents

/// Caches the user's Siri-added shortcuts and formats them into a compact prompt block
/// (Plan Z). iOS exposes no API to enumerate *all* Shortcuts — only the ones the user
/// "Added to Siri" via `INVoiceShortcutCenter` — so this surfaces that subset to the
/// agent (for `run_shortcut`) and says so plainly in the block itself.
@MainActor
final class ShortcutsCatalog: ObservableObject {
    static let shared = ShortcutsCatalog()

    struct Entry: Codable, Equatable, Sendable {
        let phrase: String
        let title: String
    }

    @Published private(set) var entries: [Entry] = []

    /// `nonisolated` so it can be used as a default argument and from off-actor helpers
    /// without a main-actor-isolation warning (immutable Sendable constant).
    nonisolated static let maxEntries = 25

    private let storageKey = "shortcutsCatalog"

    init() { load() }

    /// Re-query Siri shortcuts and update the cache. Cheap; safe to call on foreground.
    func refresh() async {
        let normalized = Self.normalize(await Self.fetchVoiceShortcuts(), max: Self.maxEntries)
        guard normalized != entries else { return }
        entries = normalized
        save()
    }

    /// Compact prompt block for the current cache, or nil when empty.
    func promptBlock() -> String? { Self.promptBlock(for: entries) }

    // MARK: - Pure helpers (testable without a device)

    /// Dedup by phrase (case-insensitive), sort alphabetically, cap to `max`.
    nonisolated static func normalize(_ raw: [Entry], max: Int) -> [Entry] {
        var seen = Set<String>()
        let deduped = raw
            .sorted { $0.phrase.localizedCaseInsensitiveCompare($1.phrase) == .orderedAscending }
            .filter { seen.insert($0.phrase.lowercased()).inserted }
        return Array(deduped.prefix(max))
    }

    nonisolated static func promptBlock(for entries: [Entry], max: Int = maxEntries) -> String? {
        guard !entries.isEmpty else { return nil }
        let lines = entries.prefix(max).map { "- \"\($0.phrase)\" → \($0.title)" }
        return """
        Available Siri Shortcuts (the user added these to Siri — call run_shortcut with the exact name):
        \(lines.joined(separator: "\n"))
        (There may be more Shortcuts the user created that iOS does not expose here.)
        """
    }

    // MARK: - INVoiceShortcutCenter

    nonisolated private static func fetchVoiceShortcuts() async -> [Entry] {
        await withCheckedContinuation { (cont: CheckedContinuation<[Entry], Never>) in
            INVoiceShortcutCenter.shared.getAllVoiceShortcuts { shortcuts, _ in
                let entries: [Entry] = (shortcuts ?? []).compactMap { vs in
                    let phrase = vs.invocationPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !phrase.isEmpty else { return nil }
                    let title = vs.shortcut.intent?.description
                        ?? vs.shortcut.userActivity?.title
                        ?? phrase
                    return Entry(phrase: phrase, title: title)
                }
                cont.resume(returning: entries)
            }
        }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = decoded
    }
}
