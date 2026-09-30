import SwiftUI

/// The model editor's **Reasoning** setting (Plan GB P0): a per-model picker plus what the setting
/// will actually do, with and without tools, and why. The readout comes from the same
/// `ReasoningPolicy.resolve` call the request builder makes, so it cannot disagree with the wire.
struct ModelReasoningSection: View {
    let provider: LLMProvider
    let model: String
    @Binding var reasoningEffort: String?

    private var draft: ModelConfig {
        var config = ModelConfig.defaultConfig(for: provider)
        config.model = model
        config.reasoningEffort = reasoningEffort
        return config
    }

    var body: some View {
        let withTools = draft.reasoningResolution(toolsAttached: true)
        let withoutTools = draft.reasoningResolution(toolsAttached: false)
        Section {
            Picker("Reasoning", selection: $reasoningEffort) {
                Text("Automatic").tag(String?.none)
                ForEach(ReasoningEffort.allCases, id: \.self) { level in
                    Text(level.label).tag(Optional(level.rawValue))
                }
            }
            readout(title: "Effective with tools", resolution: withTools)
            readout(title: "Effective without tools", resolution: withoutTools)
        } header: {
            Text("Reasoning")
        } footer: {
            Text("Saved with this model and used on every job. Reasoning tokens are billed as output, so higher settings cost more and answer more slowly.")
        }
    }

    private func readout(title: String, resolution: ReasoningPolicy.Resolution) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(resolution.displayValue)
                    .foregroundStyle(.secondary)
            }
            Text(resolution.reason.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
