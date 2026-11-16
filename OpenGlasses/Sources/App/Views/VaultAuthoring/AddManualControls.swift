import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// Plan LW P1 — *Add manual* on a vault of your own, the three ways My Manuals offers: a file (PDF,
/// Word or Markdown, prepared by `ManualFileUpload` with its per-file caps), a publisher's link or
/// code (the link review sheet, its manuals added to this vault), or photographed pages (the
/// document camera, made into a PDF and read by recognition). No manual count applies.
@MainActor
struct AddManualControls: View {
    let vaultId: String
    /// Called with the vault as it is after the add, for the caller to index.
    let onAdded: (VaultManifest) -> Void
    var disabled = false

    @State private var choosingFile = false
    @State private var photographing = false
    @State private var receiving = false
    @State private var preparing = false
    @State private var pending: PendingManual?
    @State private var errorMessage: String?
    @State private var link: VaultLinkService?

    /// A prepared upload waiting for its title and edition.
    struct PendingManual: Identifiable {
        let prepared: ManualFileUpload.Prepared
        let photographed: Bool
        /// A scan's own folder, removed with the upload.
        let scanFolder: URL?
        var id: UUID { prepared.id }
        func discard() {
            prepared.discard()
            if let scanFolder { try? FileManager.default.removeItem(at: scanFolder) }
        }
    }

    var body: some View {
        // One row: a Group would hand each modifier below to every child.
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                Button("Choose PDF, Word or Markdown") { choosingFile = true }
                Button("Use a publisher link or code") { openLink() }
                Button("Photograph pages") { photographing = true }
            } label: {
                Label("Add manual", systemImage: "doc.badge.plus")
            }
            .disabled(disabled || preparing)
            .accessibilityIdentifier("vaultAuthoring.addManual")
            if preparing { ProgressView("Preparing manual…") }
            if let errorMessage { OGStatusLabel(errorMessage, kind: .error) }
        }
        .fileImporter(isPresented: $choosingFile,
                      allowedContentTypes: ManualFileUpload.extensions.sorted().compactMap { UTType(filenameExtension: $0) },
                      allowsMultipleSelection: false) { result in
            switch result {
            case .failure(let error): errorMessage = error.localizedDescription
            case .success(let urls): if let url = urls.first { prepare(url, photographed: false, scanFolder: nil) }
            }
        }
        .fullScreenCover(isPresented: $photographing) {
            ManualDocumentCamera(onSave: { scan in
                photographing = false
                photographed(scan)
            }, onCancel: { _ in photographing = false })
            .ignoresSafeArea()
        }
        .sheet(item: Binding(get: { pending }, set: { value in
            if value == nil { pending?.discard() }
            pending = value
        })) { manual in
            AddManualDetailsSheet(manual: manual) { title, edition in
                try add(manual, title: title, edition: edition)
            }
        }
        .sheet(isPresented: $receiving) {
            if let link {
                VaultLinkSheet(service: link) {
                    if let manifest = VaultImporter.installedManifest(id: vaultId) { onAdded(manifest) }
                }
            }
        }
    }

    private static var maximumPages: Int {
        FieldAssistEntitlement.shared.manualLimits()?.pagesPerManual ?? 10_000
    }

    private func prepare(_ url: URL, photographed: Bool, scanFolder: URL?) {
        preparing = true
        errorMessage = nil
        let maximumPages = Self.maximumPages
        Task {
            defer { preparing = false }
            do {
                let prepared = try await Task.detached(priority: .utility) {
                    try ManualFileUpload.prepare(url, maximumPages: maximumPages)
                }.value
                pending = PendingManual(prepared: prepared, photographed: photographed, scanFolder: scanFolder)
            } catch {
                if let scanFolder { try? FileManager.default.removeItem(at: scanFolder) }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func photographed(_ scan: VNDocumentCameraScan) {
        preparing = true
        Task {
            do {
                let made = try await ScannedPagesPDF.pdf(from: scan, title: String(localized: "Photographed manual"))
                prepare(made.pdf, photographed: true, scanFolder: made.folder)
            } catch {
                preparing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func add(_ manual: PendingManual, title: String, edition: String) throws {
        let manifest = try VaultAuthoring.addManual(
            .init(manual.prepared, title: title, edition: edition, photographed: manual.photographed), to: vaultId)
        manual.discard()
        pending = nil
        onAdded(manifest)
    }

    private func openLink() {
        let target = vaultId
        link = VaultLinkService(install: { request in
            try await MainActor.run { try AuthoringLinkIntake.add(request, to: target) }
        })
        receiving = true
    }
}

/// The added manual's title and edition, before it is saved into the vault.
@MainActor
struct AddManualDetailsSheet: View {
    let manual: AddManualControls.PendingManual
    let onAdd: (_ title: String, _ edition: String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var edition = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Manual title", text: $title)
                    TextField("Edition or revision (optional)", text: $edition)
                } footer: {
                    Text("The edition is listed with the vault when you export it, so whoever uses it can match their copy of the manual.")
                }
                Section {
                    Text(manual.prepared.converted ? "\(manual.prepared.pages) pages in the reading copy" : "\(manual.prepared.pages) pages")
                    Text(ByteCountFormatter.string(fromByteCount: manual.prepared.bytes, countStyle: .file))
                    if manual.prepared.converted { Text(ManualFileUpload.conversionNotice).font(.footnote) }
                    if manual.photographed {
                        Text("Photographed pages are read on this phone by recognition when the manual is indexed.").font(.footnote)
                    }
                    Text("The manual is saved on this phone, then indexed. It never leaves the phone, and an export of the vault lists it without it.")
                        .font(.footnote)
                }
                if let errorMessage { Section { OGStatusLabel(errorMessage, kind: .error) } }
            }
            .navigationTitle("Add manual")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        do { try onAdd(title, edition) } catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if title.isEmpty {
                    title = manual.photographed ? String(localized: "Photographed manual") : manual.prepared.suggestedTitle
                }
            }
        }
    }
}
