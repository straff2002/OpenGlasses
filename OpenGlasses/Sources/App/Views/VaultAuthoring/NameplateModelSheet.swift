import PhotosUI
import SwiftUI
import VisionKit

/// Plan LW §4 — *Add this model*: photograph the nameplate with the phone (or pick a photo), read
/// the model on the phone, pick it, then say which of the vault's manuals covers it. Written into
/// `models.md` as its section (`IndexRowWriter.modelSection`), citing the manual.
@MainActor
struct NameplateModelSheet: View {
    let vaultId: String
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var photographing = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var reading = false
    @State private var tokens: [String] = []
    @State private var readOnce = false
    @State private var model = ""
    @State private var manualFile: String?
    @State private var page = ""
    @State private var errorMessage: String?

    private var manifest: VaultManifest? { VaultImporter.installedManifest(id: vaultId) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if VNDocumentCameraViewController.isSupported {
                        Button { photographing = true } label: { Label("Photograph the nameplate", systemImage: "camera") }
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Choose a photo", systemImage: "photo")
                    }
                    if reading { ProgressView("Reading the nameplate…") }
                } footer: {
                    Text("The photo is read on this phone and not kept.")
                }
                if readOnce {
                    Section("Read from the nameplate") {
                        if tokens.isEmpty {
                            Text("No model number could be read. Type it below, or try a closer photo.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(tokens, id: \.self) { token in
                            Button {
                                model = token
                            } label: {
                                HStack {
                                    Text(verbatim: token)
                                    Spacer()
                                    if model == token { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
                Section {
                    TextField("Model", text: $model)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("Model")
                }
                Section {
                    Picker("Manual", selection: $manualFile) {
                        Text("Choose a manual").tag(String?.none)
                        ForEach(manifest?.documents ?? [], id: \.file) { document in
                            Text(verbatim: document.title).tag(String?.some(document.file))
                        }
                    }
                    TextField("Page that lists the model (optional)", text: $page)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Which manual covers it?")
                } footer: {
                    if (manifest?.documents ?? []).isEmpty {
                        Text("Add a manual to the vault first.")
                    }
                }
                if let errorMessage { Section { OGStatusLabel(errorMessage, kind: .error) } }
            }
            .navigationTitle("Add this model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(model.trimmingCharacters(in: .whitespaces).isEmpty || manualFile == nil)
                }
            }
            .fullScreenCover(isPresented: $photographing) {
                ManualDocumentCamera(onSave: { scan in
                    photographing = false
                    guard scan.pageCount > 0 else { return }
                    read(scan.imageOfPage(at: 0))
                }, onCancel: { _ in photographing = false })
                .ignoresSafeArea()
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        read(image)
                    } else {
                        errorMessage = String(localized: "That photo could not be opened.")
                    }
                }
            }
        }
    }

    private func read(_ image: UIImage) {
        reading = true
        errorMessage = nil
        Task {
            let text = await NameplateModelRead.read(image)
            let template = manifest.map(VaultAuthoring.template(for:)) ?? .general
            tokens = Array(NameplateModelRead.tokens(fromOCRText: text, template: template).prefix(8))
            if model.isEmpty, let first = tokens.first { model = first }
            readOnce = true
            reading = false
        }
    }

    private func add() {
        guard let manifest, let file = manualFile,
              let document = manifest.documents.first(where: { $0.file == file }) else { return }
        let name = model.trimmingCharacters(in: .whitespaces)
        let physical = Int(page.trimmingCharacters(in: .whitespaces))
        do {
            // A model is checked against the manual on the draft screen; here the author has the
            // nameplate in front of them and names the manual themselves.
            let key = VaultAuthoring.key(for: document, in: manifest)
            let store = VaultRegistry.shared.store(for: manifest)
            guard let target = DraftKeeper.file(for: .modelMap, among: manifest.files) else {
                throw VaultAuthoring.Failure.noFileForLayer(VaultStarter.modelsFile)
            }
            let citation = physical.map { IndexRowWriter.citation(key: key, page: $0) } ?? key
            let result = DraftKeeper.keeping(.model(ModelRow(model: name)), citation: citation, in: store.read(target) ?? "")
            try store.write(target, contents: result.text)
            onAdded()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
