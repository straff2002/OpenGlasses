import Foundation

/// Plan CT PR 3b — enrolment's step 3: install the vault pack a profile names, through the path
/// Plan EG shipped rather than a new one.
///
/// `VaultPackCatalogService` verifies the signed catalog against the embedded key, then downloads the
/// pack, checks it against the catalog's checksum, verifies the pack signature over every file, runs
/// the structural checks and hands it to `VaultImporter`. The profile carries only the pack's id — a
/// profile never carries a pack's bytes — so a pack the catalog does not list is a failure with a
/// reason, never an install from anywhere else.
enum OrgPackInstaller {

    enum Outcome: Equatable, Sendable {
        /// Installed now, or already installed: the vault id the pack provides.
        case installed(vaultId: String)
        case failed(String)
    }

    @MainActor
    static func install(packId: String) async -> Outcome {
        let catalog = VaultPackCatalogService()
        await catalog.loadCatalog()
        switch catalog.catalogState {
        case .loaded:
            break
        case .failed(let reason):
            return .failed(reason)
        case .idle, .loading:
            return .failed("The vault pack catalog could not be read.")
        }
        guard let entry = catalog.entries.first(where: { $0.id == packId }) else {
            return .failed("The vault pack \(packId) is not in the catalog.")
        }
        if VaultImporter.installedPack(for: entry.vaultId)?.id == packId {
            return .installed(vaultId: entry.vaultId)
        }
        await catalog.install(entry)
        switch catalog.installStates[entry.id] {
        case .installed?:
            return .installed(vaultId: entry.vaultId)
        case .failed(let reason)?:
            return .failed(reason)
        default:
            return .failed("The vault pack did not finish installing.")
        }
    }
}
