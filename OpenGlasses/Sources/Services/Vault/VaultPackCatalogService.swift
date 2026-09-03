import Foundation

/// Plan EG — fetch the vault-pack catalog and run one pack through download → checksum →
/// signature → validation → install. Network is injected so the whole pipeline, including failure
/// ordering, runs headless against fixture bytes.
@MainActor
final class VaultPackCatalogService: ObservableObject {

    enum CatalogState: Equatable {
        case idle
        case loading
        case loaded([VaultPackCatalogEntry])
        case failed(String)
    }

    enum InstallState: Equatable {
        case downloading
        case installing
        case installed(warnings: [String])
        case failed(String)
    }

    @Published private(set) var catalogState: CatalogState = .idle
    @Published private(set) var installStates: [String: InstallState] = [:]

    private let fetch: (URL) async throws -> Data
    private let catalogURL: () -> URL?
    private let publicKeyBase64: String
    private let currentBuild: Int
    private let onInstalled: () -> Void

    init(catalogURL: @escaping () -> URL? = { URL(string: Config.vaultPackCatalogURL) },
         fetch: @escaping (URL) async throws -> Data = { url in
             let (data, response) = try await URLSession.shared.data(from: url)
             if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                 throw URLError(.badServerResponse)
             }
             return data
         },
         publicKeyBase64: String = SkillPackSignature.productionPublicKeyBase64,
         currentBuild: Int = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0,
         onInstalled: @escaping () -> Void = {}) {
        self.catalogURL = catalogURL
        self.fetch = fetch
        self.publicKeyBase64 = publicKeyBase64
        self.currentBuild = currentBuild
        self.onInstalled = onInstalled
    }

    var entries: [VaultPackCatalogEntry] {
        if case .loaded(let e) = catalogState { return e }
        return []
    }

    func loadCatalog() async {
        guard let url = catalogURL() else {
            catalogState = .failed("No catalog URL configured")
            return
        }
        catalogState = .loading
        do {
            let envelope = try await fetch(url)
            switch VaultPackCatalog.parse(envelopeData: envelope, publicKeyBase64: publicKeyBase64) {
            case .success(let entries):
                catalogState = .loaded(entries)
                await StoreKitService.shared.loadPackProducts(ids: Set(entries.map(\.id)))
            case .failure(let error):
                catalogState = .failed(Self.describe(error))
            }
        } catch {
            catalogState = .failed("Couldn't reach the catalog: \(error.localizedDescription)")
        }
    }

    /// What the row for `entry` should offer right now.
    func rowState(for entry: VaultPackCatalogEntry) -> VaultPackRowState {
        let installed = VaultImporter.installedPack(for: entry.vaultId)
        let licensePack = installed?.effectiveLicensePack ?? entry.vaultId
        let decision = FieldAssistEntitlement.shared.decision()
        let unlocked = VaultPackAccess.isUnlocked(
            productId: entry.id, licensePack: licensePack,
            purchasedProducts: VerifiedStorePurchaseRecorder.shared.packProductIds,
            licensedPacks: FieldAssistEntitlement.shared.grantedPacks(),
            tier: decision.tier)
        return VaultPackRowState.resolve(entry: entry, installedVersion: installed?.version,
                                         unlocked: unlocked, fieldAssistGranted: decision.isGranted,
                                         currentBuild: currentBuild)
    }

    /// Download → checksum → extract → signature → structural checks → validator → install.
    /// Every failure lands in `installStates` with a reason; nothing partial reaches the registry.
    func install(_ entry: VaultPackCatalogEntry) async {
        guard let url = URL(string: entry.downloadURL) else {
            installStates[entry.id] = .failed("bad download URL")
            return
        }
        installStates[entry.id] = .downloading
        let zipData: Data
        do {
            zipData = try await fetch(url)
        } catch {
            installStates[entry.id] = .failed("download failed: \(error.localizedDescription)")
            return
        }
        guard VaultPackArchive.sha256Hex(zipData) == entry.sha256.lowercased() else {
            installStates[entry.id] = .failed("download doesn't match the catalog's checksum")
            return
        }
        installStates[entry.id] = .installing
        switch installPack(zipData: zipData, signatureBase64: entry.packSignature, expectedId: entry.id) {
        case .success(let warnings):
            installStates[entry.id] = .installed(warnings: warnings)
            onInstalled()
        case .failure(let failure):
            installStates[entry.id] = .failed(failure.reason)
        }
    }

    struct InstallFailure: Error, Equatable {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// The offline half of `install`, usable by a sideload path: verified bytes → installed vault.
    func installPack(zipData: Data, signatureBase64: String, expectedId: String?) -> Result<[String], InstallFailure> {
        let packData: Data
        let files: [String: Data]
        switch VaultPackArchive.extract(zipData: zipData) {
        case .failure(.notAZip): return .failure(InstallFailure("not a readable pack archive"))
        case .failure(.missingPackManifest): return .failure(InstallFailure("pack has no pack.json"))
        case .failure(.missingVaultManifest): return .failure(InstallFailure("pack has no manifest.json"))
        case .success(let (p, f)): packData = p; files = f
        }
        guard VaultPackSignature.verify(signatureBase64: signatureBase64, packManifestData: packData,
                                        files: files, publicKeyBase64: publicKeyBase64) else {
            return .failure(InstallFailure("pack signature invalid — refusing to install"))
        }
        guard let pack = try? JSONDecoder().decode(VaultPackManifest.self, from: packData) else {
            return .failure(InstallFailure("pack.json unreadable"))
        }
        if let expectedId, pack.id != expectedId { return .failure(InstallFailure("pack id does not match the catalog entry")) }
        guard VaultPackManifest.isPackProductId(pack.id) else { return .failure(InstallFailure("pack id is not a vault product id")) }
        if let min = pack.minAppBuild, min > currentBuild { return .failure(InstallFailure("this pack needs app build \(min) or newer")) }
        guard let manifestData = files["manifest.json"],
              let manifest = try? JSONDecoder().decode(VaultManifest.self, from: manifestData) else {
            return .failure(InstallFailure("vault manifest unreadable"))
        }
        guard manifest.id == pack.vaultId else { return .failure(InstallFailure("pack.json vaultId does not match manifest.json id")) }
        guard manifest.gating.iap == pack.id else { return .failure(InstallFailure("vault gating must name the pack id")) }
        guard manifest.documents.isEmpty else { return .failure(InstallFailure("a pack must not ship documents; customers load their own manuals")) }

        // Lay the files out as a folder and hand it to the same importer a customer folder uses.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultPack-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            for (path, data) in files {
                let url = staging.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            let report = try VaultImporter.installReporting(from: staging)
            try VaultImporter.recordPack(pack, for: report.manifest.id)
            VaultRegistry.shared.reloadUserManifests()
            VaultRegistry.shared.resetCache()
            return .success(report.warnings)
        } catch {
            return .failure(InstallFailure(error.localizedDescription))
        }
    }

    private static func describe(_ error: VaultPackCatalog.CatalogError) -> String {
        switch error {
        case .notAnEnvelope: return "catalog format not recognized"
        case .badSignature: return "catalog signature invalid — refusing the index"
        case .unreadableIndex: return "catalog index unreadable"
        case .unsupportedVersion(let v): return "catalog version \(v) needs a newer app build"
        }
    }
}
