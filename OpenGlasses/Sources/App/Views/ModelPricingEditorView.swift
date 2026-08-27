import SwiftUI

/// Editor for the LLM cost table (Plan AU). Lets the user correct or add per-model
/// prices (USD per 1M tokens) when the bundled defaults drift, overriding
/// `ModelPricing` without a rebuild. Local-only; feeds the Insights cost section.
struct ModelPricingEditorView: View {
    /// Rows: every bundled family (sorted) so prices are visible and editable.
    @State private var rows: [Row] = []
    @State private var saved = false

    private struct Row: Identifiable {
        let model: String
        var input: String
        var output: String
        var id: String { model }
    }

    var body: some View {
        Form {
            Section {
                ForEach($rows) { $row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.model).font(.subheadline)
                        HStack {
                            rateField("In / 1M", text: $row.input)
                            rateField("Out / 1M", text: $row.output)
                        }
                    }
                }
            } header: {
                Text("USD per 1M tokens")
            } footer: {
                Text("Override the bundled prices when they drift. Blank a field to fall back to the default. Estimates are local-only and never leave your device.")
            }

            Section {
                Button {
                    save()
                } label: {
                    Label(saved ? "Saved" : "Save prices", systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                }
                Button(role: .destructive) {
                    Config.setModelPricingOverrides([:])
                    load()
                    saved = false
                } label: {
                    Label("Reset to defaults", systemImage: "arrow.uturn.backward")
                }
            }
        }
        .navigationTitle("Model Pricing")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .onAppear(perform: load)
    }

    private func rateField(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text("$")
            TextField(title, text: text)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func load() {
        let overrides = Config.modelPricingOverrides
        rows = ModelPricing.defaults
            .merging(overrides) { _, o in o }
            .sorted { $0.key < $1.key }
            .map { Row(model: $0.key,
                      input: trimmed($0.value.inputPer1M),
                      output: trimmed($0.value.outputPer1M)) }
    }

    private func save() {
        var overrides: [String: ModelPricing.Rate] = [:]
        for row in rows {
            guard let input = Double(row.input), let output = Double(row.output) else { continue }
            let base = ModelPricing.defaults[row.model]
            // Only store rows that differ from the bundled default.
            if base?.inputPer1M != input || base?.outputPer1M != output {
                overrides[row.model] = ModelPricing.Rate(input, output)
            }
        }
        Config.setModelPricingOverrides(overrides)
        saved = true
    }

    /// Compact number string (drops a trailing ".0").
    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
