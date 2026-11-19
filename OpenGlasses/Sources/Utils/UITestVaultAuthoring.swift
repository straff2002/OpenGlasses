#if DEBUG
import SwiftUI

/// Plan LW P1 — the draft review screen over a vault made for the UI-test run only.
///
/// **This whole file is behind `#if DEBUG`, so a Release binary contains none of it.** The vault is
/// made by the shipping *New Vault* path (`VaultAuthoring.createVault`) and the manual added by the
/// shipping *Add manual* path (`VaultAuthoring.addManual`), so *Keep* writes into a real vault's
/// file. The manual's page text is handed to the shipping review screen as the live source would
/// read it (`LiveDraftPageText.assemble`), without waiting on indexing. Shown in place of the app's
/// own screens, so nothing the app raises at launch sits over it. Every name, code and model is
/// invented.
struct UITestVaultAuthoring: View {

    static let vaultName = "Fixture Rooftop Units"

    static let pages: [(page: Int, text: String)] = [
        (1, "Installation manual\nRooftop unit QX-100\nThis manual covers the QX-100 and the QX-100A."),
        (2, "Fault codes\nE9 Low suction pressure. Look for a restriction in the suction line, then confirm the charge.\nF17 Outdoor fan motor overload. Let the motor cool, then check the fan turns freely."),
        (3, "Troubleshooting\nProblem: Unit runs but the room stays warm\nCause: Dirty outdoor coil\nCheck: Clean the outdoor coil and measure the airflow.")
    ]

    /// A reply as an author's own AI might give it: a line of prose, a row on its page, and a row
    /// cited on a page it is not printed on. Handed to the paste field as a paste puts it there, so
    /// the test does not depend on the simulator's keyboard.
    static let reply = "Here are the codes I found:\nE9 | Low suction pressure | 2\nF17 | Fan motor overload | 5"

    @State private var prepared: LiveDraftPageText.Manual?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let prepared {
                    DraftReviewView(vaultId: prepared.vaultId, file: prepared.document.file, title: prepared.title,
                                    fixture: prepared, fixturePaste: Self.reply)
                } else if let failure {
                    Text(verbatim: failure)
                } else {
                    ProgressView()
                }
            }
        }
        .background(OGTheme.canvas.ignoresSafeArea())
        .task { if prepared == nil && failure == nil { await prepare() } }
    }

    private func prepare() async {
        do {
            for manifest in VaultImporter.installedManifests() where manifest.name == Self.vaultName {
                VaultImporter.uninstall(id: manifest.id)
            }
            VaultRegistry.shared.reloadUserManifests()
            let vault = try VaultAuthoring.createVault(name: Self.vaultName, template: .hvacR, models: [.init("QX-100")])
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("UITestVaultAuthoring-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("installation-manual.txt")
            try Self.pages.map(\.text).joined(separator: VaultDocumentExtractor.pageSeparator)
                .write(to: file, atomically: true, encoding: .utf8)
            let manifest = try await VaultAuthoring.addManual(.init(original: file, readingPDF: file, converted: false,
                                                              title: "Installation manual", edition: "Rev A"),
                                                        to: vault.id)
            guard let document = manifest.documents.first else { failure = "No manual"; return }
            prepared = LiveDraftPageText.Manual(
                vaultId: vault.id, document: document, key: VaultAuthoring.key(for: document, in: manifest),
                pageText: LiveDraftPageText.assemble(pages: Self.pages, labels: PageLabelMap([]), recognised: false),
                tables: [])
        } catch {
            failure = error.localizedDescription
        }
    }
}
#endif
