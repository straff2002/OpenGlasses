import Foundation

/// Plan FS §2 — the publisher list, as the app holds it at runtime.
///
/// It lives in memory for the life of the process and nowhere else: it is a *cache of a signed
/// document the vendor publishes*, not the reader's data, and keeping it off disk means there is
/// no new store to register, no stale copy to revoke against, and no way for a revoked key to
/// survive on a phone that has been online since. A link import that cannot reach the catalog
/// refuses to treat any archive as signed — the safe direction, because the consequence is the
/// unverified-source warning and a second acknowledgement, never a silent trust.
@MainActor
final class VaultPublisherDirectory {

    static let shared = VaultPublisherDirectory()

    private var cached: [VaultPublisher]?
    private let fetch: (URL) async throws -> Data
    private let catalogURL: () -> URL?
    private let publicKeyBase64: String

    init(catalogURL: @escaping () -> URL? = { URL(string: Config.vaultPackCatalogURL) },
         fetch: @escaping (URL) async throws -> Data = VaultPublisherDirectory.fetchCatalog,
         publicKeyBase64: String = SkillPackSignature.productionPublicKeyBase64) {
        self.catalogURL = catalogURL
        self.fetch = fetch
        self.publicKeyBase64 = publicKeyBase64
    }

    /// What the pack catalog's last successful parse said. Set by `VaultPackCatalogService` when
    /// the Packs list loads, so a reader who has just opened Custom Vaults has it already.
    func update(publishers: [VaultPublisher]) {
        cached = publishers
    }

    /// The current list, fetching the signed catalog once if nothing has loaded it yet. An
    /// unreachable or unverifiable catalog yields an empty list, which makes every archive
    /// unverified rather than trusted.
    func current() async -> [VaultPublisher] {
        if let cached { return cached }
        guard let url = catalogURL(), let data = try? await fetch(url),
              case .success(let index) = VaultPackCatalog.parseIndex(envelopeData: data,
                                                                     publicKeyBase64: publicKeyBase64) else {
            return []
        }
        cached = index.publishers
        return index.publishers
    }

    /// What is already known, without going to the network — for a row that has to render now.
    var loaded: [VaultPublisher] { cached ?? [] }

    private static func fetchCatalog(_ url: URL) async throws -> Data {
        let url = try EndpointPolicy.requireOpenable(url: url, for: .vaultPackCatalog)
        let (data, response) = try await BoundedHTTPClient().fetchData(url, profile: .signedCatalog)
        guard (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }
}
