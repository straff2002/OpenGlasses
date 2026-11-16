import Foundation

/// Plan LW §8 — a My Manuals subscriber who moves up to Field Assist moves their manuals into a vault
/// of their own (decision 5: move, so there are not two copies of every manual).
///
/// Safe by order: the new vault is made and the manuals copied into it, every copied file is checked
/// against its source byte for byte (by SHA-256), and only then is the personal library emptied. A
/// failure at any step before that takes the new vault away again and leaves the personal library
/// exactly as it was.
@MainActor
enum MyManualsMove {

    nonisolated static let personalVaultId = "my-manuals"
    /// Set once the card has been answered (moved, or not now), so it is offered once.
    static let answeredKey = "vaultAuthoring.myManualsMoveAnswered"

    enum Failure: LocalizedError, Equatable {
        case nothingToMove
        case copyDiffers(String)

        var errorDescription: String? {
            switch self {
            case .nothingToMove: return String(localized: "There are no manuals in My Manuals to move.")
            case .copyDiffers(let title):
                return String(localized: "\(title) did not copy into the new vault intact. Your manuals are still in My Manuals.")
            }
        }
    }

    /// Whether to show the card: vaults of your own are here, My Manuals holds manuals, and the card
    /// has not been answered.
    nonisolated static func shouldOffer(hasOwnVaults: Bool, personalManuals: Int, answered: Bool) -> Bool {
        hasOwnVaults && personalManuals > 0 && !answered
    }

    static var personalManualCount: Int {
        VaultImporter.installedManifest(id: personalVaultId)?.documents.filter { $0.capturedManual == nil }.count ?? 0
    }

    static var isAnswered: Bool {
        get { UserDefaults.standard.bool(forKey: answeredKey) }
        set { UserDefaults.standard.set(newValue, forKey: answeredKey) }
    }

    /// The manuals of `sourceId`, renamed by their titles (so the keys their index rows cite read as
    /// the manual) and marked as the technician's own, or a capture, with their revision.
    static func carried(from sourceId: String) throws -> [VaultDocumentCarry.Kept] {
        var taken = Set<String>()
        return try VaultDocumentCarry.current(vaultId: sourceId).filter { $0.document.capturedManual == nil }.map { kept in
            let old = kept.document
            let ext = (old.file as NSString).pathExtension.lowercased()
            let file = VaultAuthoring.manualFileName(title: old.title, extension: ext, taken: taken)
            taken.insert(file)
            let source = old.source.map { _ in (file as NSString).deletingPathExtension + ".reading.pdf" }
            if let source { taken.insert(source) }
            guard let original = kept.files[old.file] else { throw VaultDocumentCarry.CarryError.missingFile(old.file) }
            let revision = try old.revision ?? VaultDocumentLedger.hash(of: Data(contentsOf: original, options: .mappedIfSafe))
            let document = VaultDocument(file: file, title: old.title, kind: old.kind, source: source,
                                         sourceUrl: old.sourceUrl, edition: old.edition,
                                         personalCapture: old.personalCapture, personalReadingCopy: old.personalReadingCopy,
                                         revision: revision, origin: old.personalCapture == true ? .capture : .technician)
            var files = [file: original]
            if let source, let oldSource = old.source, let url = kept.files[oldSource] { files[source] = url }
            return VaultDocumentCarry.Kept(document: document, files: files)
        }
    }

    /// Whether every carried file is in the vault's baseline with the same bytes as its source.
    nonisolated static func verify(_ carried: [VaultDocumentCarry.Kept], in vaultId: String) throws {
        guard let manifest = VaultImporter.installedManifest(id: vaultId) else { throw VaultDocumentCarry.CarryError.notInstalled(vaultId) }
        let baseline = VaultImporter.baselineDirectory(for: vaultId)
        for kept in carried {
            guard let installed = manifest.documents.first(where: { $0.file == kept.document.file }) else {
                throw Failure.copyDiffers(kept.document.title)
            }
            let paths = [manifest.documentRelativePath(installed), manifest.documentSourceRelativePath(installed)].compactMap { $0 }
            for (name, source) in kept.files {
                guard let path = paths.first(where: { ($0 as NSString).lastPathComponent == name }),
                      let copy = try? Data(contentsOf: baseline.appendingPathComponent(path), options: .mappedIfSafe),
                      let original = try? Data(contentsOf: source, options: .mappedIfSafe),
                      VaultDocumentLedger.hash(of: copy) == VaultDocumentLedger.hash(of: original) else {
                    throw Failure.copyDiffers(kept.document.title)
                }
            }
        }
    }

    /// Make the vault, move the manuals into it, then empty the personal library. `verify` is the
    /// check between the copy and the removal (a seam for the test of a failure there).
    @discardableResult
    static func move(name: String, template: TradeTemplate, models: [VaultStarter.Model] = [],
                     from sourceId: String = personalVaultId,
                     documentStore: DocumentStore, taken: Set<String>? = nil,
                     verify: ([VaultDocumentCarry.Kept], String) throws -> Void = { try MyManualsMove.verify($0, in: $1) }) async throws -> VaultManifest {
        let carried = try carried(from: sourceId)
        guard !carried.isEmpty else { throw Failure.nothingToMove }
        let vault = try VaultAuthoring.createVault(name: name, template: template, models: models, taken: taken)
        let moved: VaultManifest
        do {
            moved = try VaultDocumentCarry.relay(vaultId: vault.id, removing: [], adding: carried)
            try verify(carried, vault.id)
        } catch {
            // Nothing of the personal library has been touched: take the half-made vault away.
            VaultImporter.uninstall(id: vault.id)
            VaultRegistry.shared.reloadUserManifests()
            VaultRegistry.shared.resetCache()
            throw error
        }
        await VaultImporter.uninstall(id: sourceId, documentStore: documentStore)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        isAnswered = true
        return moved
    }
}
