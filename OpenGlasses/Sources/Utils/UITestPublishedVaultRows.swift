#if DEBUG
import SwiftUI

/// Plan LV — a published vault's row under *Managed by ⟨org⟩*, for the UI-test run only.
///
/// **This whole file is behind `#if DEBUG`, so a Release binary contains none of it.** An
/// organisation profile is signed by a key no build of the app holds the private half of, so the
/// managed section cannot be reached in a UI test without faking an enrolment, and nothing here
/// does. Instead the shipping `CompanyVaultRow.rows` makes the rows from a fixture state — one
/// published vault, version 5 of an invented partner's, holding one manual it expects, another at
/// a different revision and missing a third, plus the company's own layer — and the shipping
/// `CompanyVaultRowList` draws them, as the managed section does. Every name is invented.
struct UITestPublishedVaultRows: View {

    static let vaultId = "fixture-split-systems"
    static let layerId = "fixture-split-systems-company"

    static var rows: [CompanyVaultRow] {
        let installRevision = String(repeating: "a", count: 64)
        let serviceRevision = String(repeating: "b", count: 64)
        let base = CompanyVaultCatalog.Vault(
            id: "com.openglasses.vault." + vaultId, vaultId: vaultId, version: "7", name: "Fixture Split Systems",
            summary: nil, author: nil, minAppBuild: nil, sizeBytes: 1_140,
            downloadURL: "https://licence.example.test/v/fixture.sealed", sha256: String(repeating: "c", count: 64),
            packSignature: "fixture", publisher: .init(id: "p-fixture", name: "Fixture Partner", version: 5),
            sealedCore: true,
            expects: [.init(key: "install-manual", title: "Installation manual", edition: "Rev C", revision: installRevision),
                      .init(key: "service-manual", title: "Service manual", edition: "Rev B",
                            revision: String(repeating: "d", count: 64)),
                      .init(key: "wiring-diagram", title: "Wiring diagram", edition: "2024")])
        let layer = CompanyVaultCatalog.Vault(
            id: "com.openglasses.vault." + layerId, vaultId: layerId, version: "2", name: "Fixture Company Notes",
            summary: nil, author: nil, minAppBuild: nil, sizeBytes: 933,
            downloadURL: "https://licence.example.test/v/layer.zip", sha256: String(repeating: "e", count: 64),
            packSignature: "fixture", extends: vaultId)
        let catalog = CompanyVaultCatalog.Verified(
            profileId: "fixture-company", generation: 12, issued: Date(timeIntervalSince1970: 1_800_000_000),
            manualsOnAnyNetwork: false, vaults: [base, layer], manuals: [], problems: [:])
        var state = CompanyVaultState()
        let updated = Date(timeIntervalSince1970: 1_800_000_000)
        state.vaults[vaultId] = .init(packId: base.id, name: base.name, version: "7", updatedAt: updated,
                                      publisherName: "Fixture Partner", publisherVersion: 5)
        state.vaults[layerId] = .init(packId: layer.id, name: layer.name, version: "2", updatedAt: updated, extends: vaultId)
        let documents = [
            VaultDocument(file: "Installation manual.md", title: "Installation manual", kind: "company_manual",
                          revision: installRevision, origin: .company),
            VaultDocument(file: "Service manual.md", title: "Service manual", kind: "company_manual",
                          revision: serviceRevision, origin: .company),
        ]
        return CompanyVaultRow.rows(state: state, catalog: catalog, documents: { $0 == vaultId ? documents : [] })
    }

    var body: some View {
        NavigationStack {
            OGScrollPage {
                // Verbatim: fixture words never reach the string catalog.
                Text(verbatim: "MANAGED BY FIXTURE MECHANICAL")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                OGCard {
                    CompanyVaultRowList(rows: Self.rows)
                }
            }
            .navigationTitle(Text(verbatim: "Fixture Mechanical"))
            .navigationBarTitleDisplayMode(.inline)
        }
        // Drawn over the app rather than presented: a sheet raised while the first scene comes up
        // was dropped on a UI test run.
        .background(OGTheme.canvas.ignoresSafeArea())
    }
}
#endif
