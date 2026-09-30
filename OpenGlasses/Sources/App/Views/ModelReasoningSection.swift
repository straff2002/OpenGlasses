import SwiftUI

/// The model editor's **Reasoning** setting (Plan GB P0): a per-model picker plus what the setting
/// will actually do, with and without tools, and why. Plan GC: the readout names the endpoint too,
/// and comes from the same `OpenAIRouteSelector` selection the request builder makes (base URL
/// included, since a custom host opts into Responses through it), so it cannot disagree with the
/// wire. The wording lives in `ModelReasoningReadout`.
struct ModelReasoningSection: View {
    let provider: LLMProvider
    let model: String
    let baseURL: String
    @Binding var reasoningEffort: String?

    private var draft: ModelConfig {
        var config = ModelConfig.defaultConfig(for: provider)
        config.model = model
        config.baseURL = baseURL
        config.reasoningEffort = reasoningEffort
        return config
    }

    var body: some View {
        let withTools = ModelReasoningReadout.lines(for: draft.routeSelection(toolsAttached: true))
        let withoutTools = ModelReasoningReadout.lines(for: draft.routeSelection(toolsAttached: false))
        Section {
            Picker("Reasoning", selection: $reasoningEffort) {
                Text("Automatic").tag(String?.none)
                ForEach(ReasoningEffort.allCases, id: \.self) { level in
                    Text(level.label).tag(Optional(level.rawValue))
                }
            }
            readout(title: "Effective with tools", lines: withTools)
            readout(title: "Effective without tools", lines: withoutTools)
        } header: {
            Text("Reasoning")
        } footer: {
            Text("Saved with this model and used on every job. Reasoning tokens are billed as output, so higher settings cost more and answer more slowly.")
        }
    }

    private func readout(title: String, lines: ModelReasoningReadout.Lines) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(lines.value)
                    .foregroundStyle(.secondary)
            }
            Text(lines.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
