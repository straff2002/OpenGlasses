import Foundation

/// Plan MN P3 — reading a vault's procedures for the authoring screen and saving one the author
/// edited. A saved procedure is an edit, so it goes to the overlay over the same file name (as the
/// file editor and *Keep* write), where `ProcedureLibrary` reads it in place of the baseline's and
/// an export carries it. Only a vault the subscriber owns, and only a procedure the validator
/// passes: the importer would refuse anything else on the next import.
@MainActor
enum ProcedureAuthoring {

    enum Failure: LocalizedError, Equatable {
        case notOwned
        case noProcedures
        case badFileName
        case hasIssues(String)

        var errorDescription: String? {
            switch self {
            case .notOwned:
                return String(localized: "Only a vault you made or imported yourself can be changed on this phone.")
            case .noProcedures:
                return String(localized: "This vault has no procedures folder.")
            case .badFileName:
                return String(localized: "This procedure's file can't be written.")
            case .hasIssues(let first):
                return String(localized: "Fix this before saving: \(first)")
            }
        }
    }

    /// The vault's procedures with their files, in id order.
    static func entries(vaultId: String) -> [ProcedureLibrary.Candidate] {
        guard let store = VaultRegistry.shared.store(forId: vaultId) else { return [] }
        return ProcedureLibrary.entries(store: store)
    }

    /// Whether `file` is a plain procedure file name: no folder, no hidden file, `.json`.
    nonisolated static func isProcedureFileName(_ file: String) -> Bool {
        !file.isEmpty && !file.hasPrefix(".") && !file.contains("/") && !file.contains("\\")
            && (file as NSString).lastPathComponent == file && file.lowercased().hasSuffix(".json")
    }

    /// Write the edited procedure over `file` in the vault's overlay. Returns where it went.
    @discardableResult
    static func save(_ editing: ProcedureEditing, file: String, vaultId: String) throws -> URL {
        guard VaultAuthoring.isOwned(vaultId), let store = VaultRegistry.shared.store(forId: vaultId) else {
            throw Failure.notOwned
        }
        guard let dir = store.manifest.proceduresDir else { throw Failure.noProcedures }
        guard isProcedureFileName(file) else { throw Failure.badFileName }
        if let first = editing.messages.issues.first { throw Failure.hasIssues(first) }
        let folder = store.overlayRoot.appendingPathComponent(dir, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(file)
        try editing.encoded().write(to: url, options: .atomic)
        return url
    }
}
