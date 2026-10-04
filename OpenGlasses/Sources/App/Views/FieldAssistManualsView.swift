import QuickLook
import SwiftUI

/// Every installed manual, searchable (Plan HB) — what the Field Assist tab's "All manuals" opens.
struct FieldAssistManualsView: View {
    @ObservedObject var appState: AppState
    let shelf: [FieldAssistManualShelf.Vault]
    let activeVaultId: String
    /// The vault of the open job, when there is one — the only place a manual can be asked.
    let openJobVaultId: String?

    @State private var query = ""
    @State private var previewURL: URL?
    @State private var askingManual: FieldAssistManualShelf.Manual?
    @State private var problem: String?

    var body: some View {
        let manuals = FieldAssistManualShelf.manuals(vaults: shelf, activeVaultId: activeVaultId, query: query)
        List {
            if manuals.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ForEach(manuals) { manual in
                    ManualShelfRow(manual: manual,
                                   canAsk: FieldAssistManualShelf.canAsk(manual, openJobVaultId: openJobVaultId),
                                   onOpen: { open(manual) },
                                   onAsk: { askingManual = manual })
                }
            }
        }
        .navigationTitle("Manuals")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search manuals")
        .ogFormStyle()
        .quickLookPreview($previewURL)
        .sheet(item: $askingManual) { manual in
            ManualAskSheet(manual: manual) { question in
                askingManual = nil
                guard let prompt = FieldAssistManualShelf.askPrompt(manual: manual, question: question) else { return }
                appState.requestedTab = .voice
                Task { await appState.sendTextMessage(prompt) }
            }
        }
        .alert("Can't open that manual",
               isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    private func open(_ manual: FieldAssistManualShelf.Manual) {
        guard let manifest = VaultRegistry.shared.manifest(id: manual.vaultId),
              let document = manifest.documents.first(where: { $0.file == manual.file }),
              let url = FieldAssistManualFiles.url(manifest: manifest, document: document) else {
            problem = "\(manual.title) is no longer on this phone."
            return
        }
        previewURL = url
    }
}

/// One manual: tap to open it; Ask, while a job is open on its vault.
struct ManualShelfRow: View {
    @Environment(\.appAccent) private var accent
    let manual: FieldAssistManualShelf.Manual
    let canAsk: Bool
    let onOpen: () -> Void
    let onAsk: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: "book.closed.fill")
                        .font(.title3)
                        .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                        .frame(width: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(manual.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color(.label))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(manual.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: OGMetrics.minTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(manual.title), \(manual.detail)")
            .accessibilityHint("Opens the manual.")
            .accessibilityAddTraits(.isButton)

            if canAsk {
                Button("Ask", action: onAsk)
                    .buttonStyle(.bordered)
                    .frame(minHeight: OGMetrics.minTouchTarget)
                    .accessibilityLabel("Ask \(manual.title)")
                    .accessibilityHint("Looks something up in this manual for the open job.")
            }
        }
    }
}

/// The question for one manual. The answer arrives on the home tab, spoken and cited, like any turn.
struct ManualAskSheet: View {
    let manual: FieldAssistManualShelf.Manual
    let onAsk: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What do you want to know?", text: $question, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit(send)
                } header: {
                    Text(manual.title)
                } footer: {
                    Text("Answered from this manual with the page cited, on the Avenkin tab.")
                }
            }
            .navigationTitle("Ask the manual")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ask", action: send)
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onAsk(question)
        dismiss()
    }
}

/// Where a manual's file is on this phone, and the shelf as the disk has it. The only part of the
/// manuals shelf that touches the file system; the decisions are `FieldAssistManualShelf`'s.
@MainActor
enum FieldAssistManualFiles {

    /// The manufacturer's original when one is bundled beside the extracted text, otherwise the
    /// imported file itself — in the imported vault's baseline, or the app bundle for a built-in.
    static func url(manifest: VaultManifest, document: VaultDocument) -> URL? {
        let candidates = [manifest.documentSourceRelativePath(document),
                          manifest.documentRelativePath(document)].compactMap { $0 }
        let roots = [VaultImporter.baselineDirectory(for: manifest.id),
                     Bundle.main.url(forResource: "Vaults/\(manifest.id)", withExtension: nil)]
            .compactMap { $0 }
        for relative in candidates {
            for root in roots {
                let url = root.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Every vault, with the manuals that cannot be opened marked: missing on disk, or mid-removal.
    static func shelf() -> [FieldAssistManualShelf.Vault] {
        VaultRegistry.shared.allManifests.map { manifest in
            let pending = VaultManualRemoval.pendingFiles(for: manifest.id)
            let missing = manifest.documents.filter { url(manifest: manifest, document: $0) == nil }.map(\.file)
            return FieldAssistManualShelf.Vault(
                id: manifest.id, name: manifest.name,
                unlocked: VaultRegistry.shared.isUnlocked(manifest),
                documents: manifest.documents,
                unavailableFiles: pending.union(missing))
        }
    }
}
