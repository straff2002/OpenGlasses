import Foundation

/// The Field Assist tab's manuals (Plan HB), decided without SwiftUI: which manuals are listed, in
/// what order, what a search finds, and when a manual can be asked a question.
///
/// A manual is a `VaultDocument` on an installed vault. Only unlocked vaults are listed, and a
/// manual whose file is gone or whose removal is in flight is not — opening a manual the vault has
/// let go of is the thing manual removal promised would not happen.
enum FieldAssistManualShelf {

    /// How many manuals the tab shows before "All manuals".
    static let homeLimit = 5

    /// One vault's manuals, as the shelf needs them.
    struct Vault: Equatable {
        let id: String
        let name: String
        let unlocked: Bool
        let documents: [VaultDocument]
        /// Document file names that cannot be opened: missing on disk, or being removed.
        var unavailableFiles: Set<String> = []
    }

    struct Manual: Identifiable, Equatable {
        let vaultId: String
        let vaultName: String
        /// The manifest's file name, which is how a manual is addressed everywhere else.
        let file: String
        let title: String
        let kind: String?
        let isActiveVault: Bool

        var id: String { "\(vaultId)/\(file)" }

        /// "Service manual · Refrigeration" — the row's quieter line.
        var detail: String {
            [Self.kindLabel(kind), vaultName].compactMap { $0 }.joined(separator: " · ")
        }

        /// "service_manual" → "Service manual". The manifest's free-text classification, shown as
        /// a reader would write it.
        static func kindLabel(_ kind: String?) -> String? {
            guard let kind = kind?.trimmingCharacters(in: .whitespacesAndNewlines), !kind.isEmpty else {
                return nil
            }
            let spaced = kind.replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            return spaced.prefix(1).uppercased() + spaced.dropFirst()
        }
    }

    /// Every listed manual matching `query`: the active vault's first, then the rest by vault name,
    /// each vault's manuals by title. An empty query matches everything.
    static func manuals(vaults: [Vault], activeVaultId: String, query: String = "") -> [Manual] {
        let needle = normalized(query)
        let ordered = vaults.filter(\.unlocked).sorted { lhs, rhs in
            if (lhs.id == activeVaultId) != (rhs.id == activeVaultId) { return lhs.id == activeVaultId }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return ordered.flatMap { vault in
            vault.documents
                .filter { !vault.unavailableFiles.contains($0.file) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                .map { Manual(vaultId: vault.id, vaultName: vault.name, file: $0.file, title: $0.title,
                              kind: $0.kind, isActiveVault: vault.id == activeVaultId) }
                .filter { manual in
                    needle.isEmpty || [manual.title, manual.vaultName, Manual.kindLabel(manual.kind) ?? ""]
                        .contains { normalized($0).contains(needle) }
                }
        }
    }

    /// Whether a manual can be asked a question now: only inside a job open on its vault, because
    /// that is the only place `manual_lookup` answers. A button that sent a question the tool would
    /// refuse would be a dead end.
    static func canAsk(_ manual: Manual, openJobVaultId: String?) -> Bool {
        manual.vaultId == openJobVaultId
    }

    /// The typed turn an Ask sends. Names the manual so the lookup is scoped to it, and asks for the
    /// page, which the tool's citations carry.
    static func askPrompt(manual: Manual, question: String) -> String? {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return nil }
        return "Look this up in the \u{201C}\(manual.title)\u{201D} manual and cite the page: \(asked)"
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
