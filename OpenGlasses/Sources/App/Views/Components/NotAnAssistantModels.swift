import SwiftUI

/// The models a provider's list offers that can't be the assistant — speech, transcription, live
/// voice, image, embedding and the rest, and chat models their provider has retired — shown under
/// the chat models in their own section: dimmed, not selectable, each labelled with what it is for
/// and, where the app has that job, whether it can reach it. Labelled rather than hidden, so a
/// wearer who knows a model by name can see where it went and why it isn't offered.
struct NotAnAssistantModelsSection: View {
    let models: [ModelFetcher.RemoteModel]
    let provider: LLMProvider

    var body: some View {
        if !models.isEmpty {
            Section {
                ForEach(models) { model in
                    NotAnAssistantModelRow(model: model, provider: provider)
                }
            } header: {
                Text("Can't be your assistant")
            } footer: {
                Text("These models do other jobs, such as speech, transcription or images, or their provider has retired them, so they can't answer as your assistant.")
            }
        }
    }
}

/// One model that can't be chosen as the assistant: its name, its id when that differs, and what
/// it is for. Not a button, so it can't be selected.
struct NotAnAssistantModelRow: View {
    let model: ModelFetcher.RemoteModel
    let provider: LLMProvider

    var body: some View {
        let label = model.unavailableLabel(provider: provider)
        UnavailableModelRow(title: model.name, detail: model.name == model.id ? nil : model.id, label: label,
                            spokenText: String(localized: "\(model.name), \(label), can't be your assistant"))
    }
}

/// A dimmed row for a model that can't be chosen, with the reason at its trailing edge.
struct UnavailableModelRow: View {
    let title: String
    let detail: String?
    let label: String
    let spokenText: String

    @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = 44

    var body: some View {
        HStack(spacing: OGMetrics.rowSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: minHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenText)
    }
}
