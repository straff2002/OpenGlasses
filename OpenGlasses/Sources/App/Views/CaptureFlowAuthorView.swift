import SwiftUI

/// No-code author for a structured Capture-Flow (Plan U follow-up). Compose the flow's
/// steps in a form, validate via the pure `CaptureFlowBuilder`, and export the JSON the
/// library loads — drop it into a vault's `flows/` overlay to use it. Sidesteps the
/// vault-coupling of in-place saving while still giving real no-code authoring.
struct CaptureFlowAuthorView: View {
    @State private var id = ""
    @State private var title = ""
    @State private var steps: [CaptureFlowBuilder.StepDraft] = [CaptureFlowBuilder.StepDraft()]
    @State private var error: String?
    @State private var shareItem: ShareItem?

    var body: some View {
        Form {
            Section("Flow") {
                TextField("Id (e.g. fridge_inspection)", text: $id)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Title", text: $title)
            }

            ForEach($steps) { $step in
                Section {
                    TextField("Field (e.g. suction_psig)", text: $step.field)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Prompt (read aloud)", text: $step.prompt)
                    Picker("Type", selection: $step.type) {
                        Text("Voice").tag(BindingType.voice)
                        Text("Number").tag(BindingType.voiceNumber)
                        Text("Choice").tag(BindingType.enumChoice)
                        Text("Barcode/Voice").tag(BindingType.barcodeOrVoice)
                        Text("Photo").tag(BindingType.photo)
                        Text("OCR text").tag(BindingType.ocrText)
                    }
                    if step.type == .voiceNumber {
                        TextField("Unit (e.g. psig)", text: $step.unit)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    if step.type == .enumChoice {
                        TextField("Options (comma-separated)", text: $step.optionsCSV)
                    }
                    Toggle("Required", isOn: $step.required)
                } header: {
                    Text("Step \((steps.firstIndex(of: step) ?? 0) + 1)")
                }
            }
            .onDelete { steps.remove(atOffsets: $0) }

            Section {
                Button { steps.append(CaptureFlowBuilder.StepDraft()) } label: {
                    Label("Add step", systemImage: "plus")
                }
                Button { export() } label: {
                    Label("Export flow JSON", systemImage: "square.and.arrow.up")
                }
                .disabled(steps.isEmpty)
                if let error {
                    Label(error, systemImage: "xmark.circle").font(.footnote).foregroundStyle(OGTheme.errorLabel)
                }
            } footer: {
                Text("Validates the flow and exports its JSON. Save it into a vault's flows/ folder (via Vault import) to run it with the capture_flow tool.")
            }
        }
        .navigationTitle("Author Capture-Flow")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem) { ShareSheet(items: $0.items) }
    }

    private func export() {
        error = nil
        switch CaptureFlowBuilder.build(id: id, title: title, steps: steps) {
        case .failure(let e):
            error = e.errorDescription
        case .success(let flow):
            guard let data = try? CaptureFlowBuilder.encode(flow) else { error = "Couldn't encode the flow."; return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(flow.id).json")
            do {
                try data.write(to: url)
                shareItem = ShareItem(items: [url])
            } catch let writeError { error = writeError.localizedDescription }
        }
    }
}
