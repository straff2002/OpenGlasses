import Foundation

/// Plan CT PR 3b — enrolment's step 3: install the vault pack a profile names, through the path
/// Plan EG shipped rather than a new one.
///
/// `VaultPackCatalogService` verifies the signed catalog against the embedded key, then downloads the
/// pack, checks it against the catalog's checksum, verifies the pack signature over every file, runs
/// the structural checks and hands it to `VaultImporter`. The profile carries only the pack's id — a
/// profile never carries a pack's bytes — so a pack the catalog does not list is a failure with a
/// reason, never an install from anywhere else.
///
/// Plan LR P1: a pack already on the phone is brought up to the catalog's version — the same
/// version comparison the Vault Packs screen makes — keeping the manuals the vault holds and the
/// technician's overlay. `OrgProfileManager` asks only between jobs.
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
        if let installed = VaultImporter.installedPack(for: entry.vaultId), installed.id == packId,
           !VaultPackRowState.isNewer(entry.version, than: installed.version) {
            return .installed(vaultId: entry.vaultId)
        }
        await catalog.install(entry, keeping: VaultDocumentCarry.current(vaultId: entry.vaultId))
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
